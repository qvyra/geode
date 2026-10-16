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

`Geode.erase(userId)` erases a player's data from every profile store, and `store:erase(key)` erases one key. The record keeps only an erased marker, the mailbox goes, and so does the audit log. A server still holding the profile loses its session on its next save instead of writing the data back. If the player joins again, they start over from the template.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local PlayerData = Geode.players({ name = "PlayerData", template = { coins = 0 } })

local report = Geode.erase(1001)
print(report.erased, "stores erased")
```

Erasure is immediate for every live read. Roblox still keeps older hourly versions readable through the versioning API for 30 days and offers no supported way to remove them early, so history and rollback refuse every version from before the erasure.
