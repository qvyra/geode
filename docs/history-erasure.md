---
sidebar_position: 15
---

# History, rollback and erasure

## History

Roblox keeps one version of each DataStore key per UTC hour, holding the last write of that hour, for 30 days after it's overwritten. `store:history` lists those versions and `store:version` reads what one held, migrated and decoded the way a load would.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local PlayerData = Geode.players({ name = "PlayerData", template = { coins = 0 } })
local store = PlayerData.store
local key = store:keyForUser(1001)

local versions = store:history(key, { ascending = false, limit = 10 })
if versions.ok and versions.value[1] then
	local data = store:version(key, versions.value[1].version)
	if data.ok then
		print(data.value)
	end
end
```

## Rollback

`store:rollback(key, versionId, note)` puts a profile back to a stored version, and never writes behind the back of the server holding it:

- A profile open on this server is changed and saved directly
- A profile held by another server gets the rollback sent there, and the call waits for that server's answer. A holder that doesn't answer in time is reported as a failure
- A profile nobody holds is loaded through the normal lease, changed and released

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local PlayerData = Geode.players({ name = "PlayerData", template = { coins = 0 } })
local store = PlayerData.store
local key = store:keyForUser(1001)

local versions = store:history(key)
if versions.ok and versions.value[1] then
	local result = store:rollback(key, versions.value[1].version, "undo the duplication bug")
	print(result.ok, result.via, result.message)
end
```

## Audit log

A store made with `audit = true` writes one audit batch per save holding each commit's source, note, ops and changed paths. `store:auditLog(key)` reads it back, newest first.

## Erasure

`Geode.erase(userId)` erases a player's data from every store made on this server that keeps data by user id: profile stores, boards, and shared stores given `keyForUser`. `store:erase(key)` erases one profile. The record keeps only an erased marker, the mailbox goes, and so does the audit log. A server still holding the profile loses its session on its next save instead of writing the data back. If the player joins again, they start over from the template.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local PlayerData = Geode.players({ name = "PlayerData", template = { coins = 0 } })

local Homes = Geode.Shared.store({
	name = "Homes",
	template = { rooms = 1 },
	keyForUser = function(userId)
		return `home_{userId}`
	end,
})

local Wins = Geode.Ranked.allTime("Wins")

local report = Geode.erase(1001)
for _, entry in report.stores do
	print(entry.kind, entry.store, entry.ok, entry.message)
end
```

- **Profile stores** erase the player's profile as `store:erase` does.
- **Boards** take the player off with `board:remove(userId)`: RemoveAsync on their key in an all-time board, and a removal from the current window and every earlier one still kept in a windowed board.
- **Shared stores** only take part when given `keyForUser`, since Geode can't tell which keys belong to a player. It returns the key that holds the player's data, or nil when the store has none for them, and Geode deletes that key with `store:delete(key)`. A shared store whose keys hold many players' data, like a guild, should leave `keyForUser` out and edit the player out itself.

The report has one entry in `stores` per store that held something, with its name, its kind (`profile`, `shared` or `board`), whether it worked and why not. `erased` counts the stores that worked and `failures` lists the others. A store that fails doesn't stop the rest.

Erasure is immediate for every live read. Roblox's documentation says versioned backups expire 30 days after a newer write replaces them, and marks RemoveVersionAsync deprecated without naming anything in its place, so older versions can't be removed sooner. History and rollback refuse every version from before the erasure.
