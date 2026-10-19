---
sidebar_position: 18
---

# Stored records

This page is for people writing tools that read Geode's data straight from DataStores, or edit it there while no Geode code is running: Studio tools, DataStore editors, one-off repair scripts. Games using Geode never need any of it.

## Profile records

Each profile is one DataStore key holding a table with two fields: `data`, the player's data, and `meta`, the bookkeeping that keeps it safe.

```json
{
	"data": { "coins": 120, "inventory": ["sword"] },
	"meta": {
		"format": 1,
		"schemaVersion": 3,
		"revision": 42,
		"lease": {
			"jobId": "2f6c...",
			"placeId": 1234567,
			"session": "8C1E...",
			"acquiredAt": 1760600000.5,
			"renewedAt": 1760600300.2
		},
		"receipts": ["5c4a..."],
		"mailboxCursor": 0,
		"createdAt": 1760000000.1,
		"updatedAt": 1760600300.2,
		"lastSession": { "session": "8C1E...", "revision": 42 }
	}
}
```

| Field                | What it holds                                                                                                                                          |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `data`               | The player's data in stored form. Values with a codec in the schema, like a `Vector3`, are stored as plain tables, and the schema decodes them on load |
| `meta.format`        | The record layout, see below. Missing on records written by Geode 0.4.0 to 0.5.0                                                                       |
| `meta.schemaVersion` | The schema version the data was saved with. A load runs the migrations from there                                                                      |
| `meta.revision`      | Goes up with every change to the data and never moves backwards                                                                                        |
| `meta.lease`         | The session lease of the server that has the profile loaded. Missing when nobody has it                                                                |
| `meta.receipts`      | Ids of developer product purchases already granted, newest last                                                                                        |
| `meta.mailboxCursor` | How far the profile has read its mailbox                                                                                                               |
| `meta.createdAt`     | When the record was first written                                                                                                                      |
| `meta.updatedAt`     | When the record was last written                                                                                                                       |
| `meta.erasedAt`      | When the player's data was erased. The record then holds no `data`                                                                                     |
| `meta.lastSession`   | The session behind the last write and the revision it left                                                                                             |

Times are Unix seconds and usually carry a fraction. A lease counts as stale once `renewedAt` is older than the store's `leaseTimeout`, 300 seconds unless the game sets its own.

## Shared store records

Shared store keys have the same two fields with a shorter `meta`: `format`, `schemaVersion`, `revision` and `updatedAt`. There is no lease, since any server may write any key.

## meta.format

`meta.format` tells tools which layout a record has. Geode 0.6.0 writes `1` into every profile and shared record it writes. A record without it was written by Geode 0.4.0 to 0.5.0, whose layout is the same apart from the missing field, and it loads as before. The next write from 0.6.0 or later adds it.

The number goes up only when the stored shape changes in a way a tool reading records has to know about. `Geode.Raw.recordFormat` holds the format the running Geode writes.

While servers of an older version are still running, they keep `meta.format` on the profile records they save, but write shared records without it.

## Editing a record outside Geode

A tool that changes a record directly in its DataStore key makes an **external write**. Every external write follows the same rule:

1. Read and write in a single UpdateAsync, so a server writing in between isn't lost.
2. Only edit a profile whose `meta.lease` is missing. A server that still holds the lease saves over the edit on its next save, even when the lease looks stale. To edit a profile a server has loaded, go through that server.
3. Put the new data in `data`, in stored form, matching the record's `meta.schemaVersion`.
4. Raise `meta.revision` by one.
5. Set `meta.lastSession` to `{ session = "external:" .. id, revision = <the new revision> }`, with an `id` that is fresh for every write, such as a new GUID.
6. Set `meta.updatedAt` to the current Unix time in seconds.
7. Leave everything else in `meta` alone, `lease` and `format` included.
8. Return the key's user IDs and metadata along with the new value. UpdateAsync drops metadata the transform doesn't return, and the user IDs Geode attached to the key say whose data it holds.

`Geode.Raw.externalWrite(stored, data, { now, id })` applies steps 3 to 7 and returns a new record, so a tool that runs Luau doesn't have to repeat them:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

-- Changes one profile or shared record. `edit` gets the stored data and returns the new data
local function editStored(dataStore: DataStore, key: string, edit: (data: any) -> any)
	return dataStore:UpdateAsync(key, function(stored, keyInfo: DataStoreKeyInfo?)
		if stored == nil or keyInfo == nil or stored.meta.lease ~= nil then
			-- missing, or a server has it loaded and would save over the edit
			return nil
		end
		local written = Geode.Raw.externalWrite(stored, edit(stored.data), {
			now = DateTime.now().UnixTimestampMillis / 1000,
			id = game:GetService("HttpService"):GenerateGUID(false),
		})
		return written, keyInfo:GetUserIds(), keyInfo:GetMetadata()
	end)
end

local stored = { data = { coins = 5 }, meta = { format = 1, schemaVersion = 1, revision = 7 } }
local written =
	Geode.Raw.externalWrite(stored, { coins = 50 }, { now = 1760000000, id = "edit-1" })
print(written.meta.revision, written.meta.lastSession.session) -- 8 external:edit-1
```

### Why the rule looks like this

The session and the revision protect the edit from a server that just let the profile go. When a release reports failure, a server can't tell whether it landed. So on its next save, if the lease is gone but `meta.lastSession` still names its own session and the current revision, it knows its release landed and nobody wrote since, and it takes the lease back. An external write that left `lastSession` alone would look like that server's own write, and the server would save over it. With an `external:` session and a new revision, the server sees that someone else wrote after its release and stops with its session lost, reason `the profile was edited outside Geode after this server let it go`. Geode's own sessions are GUIDs, so they never start with `external:`.

The revision also matters for shared stores. Servers serve shared values from a cache, `cacheTtl` seconds long (30 by default), and only replace a cached value with one at the same or a newer revision. After that time every server reads the edit. To make them read it sooner, a tool can publish `{ key = key, from = "tool", revision = <the new revision> }` on the MessagingService topic `geode_invalidate_<store name>`. Servers drop their cached value of that key when the message names a newer revision than theirs. Nobody has confirmed whether messages sent from Studio reach live servers, so the cache lifetime is the only promise.

The next write from Geode builds on the edit like on any other write. Profile records keep the external `lastSession` until the next load or save replaces it, and shared stores rewrite `meta` on their next write.
