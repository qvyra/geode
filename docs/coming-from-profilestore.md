---
sidebar_position: 12
---

# Coming from ProfileStore

If your game uses ProfileStore, most of its ideas carry over: session locked profiles, a template, reconciling and safe server hops. This page maps one to the other and shows how to move existing data.

## The same ideas, side by side

| ProfileStore                       | Geode                                                                                                                    |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `ProfileStore.New(name, template)` | `Geode.Profile.store({ name = name, template = template })`, or `Geode.players` to have joins and leaves handled for you |
| `store:StartSessionAsync(key)`     | `store:load(key, { userId = userId })`                                                                                   |
| `profile.Data.coins += 10`         | `profile:increment("coins", 10)`                                                                                         |
| `profile:Reconcile()`              | Automatic on every load                                                                                                  |
| `profile:EndSession()`             | `profile:release()`                                                                                                      |
| `profile.OnSessionEnd`             | `profile.released` and `profile.sessionLost`                                                                             |
| `profile:AddUserId(userId)`        | The `userId` load option                                                                                                 |
| `store:MessageAsync(key, message)` | `store:mail(key, op, ...)`, applied as a transaction on the next load                                                    |
| `store:GetAsync(key)` and versions | `store:history(key)` and `store:version(key, id)`                                                                        |

The biggest change is that data is no longer a mutable table. Writes go through ops and transactions, and reads return frozen values. That one path is what lets guards, reactions, replication and history see every change.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local PlayerData = Geode.players({
	name = "PlayerData",
	template = { coins = 0, inventory = {} },
})

PlayerData:onLoaded(function(player, profile)
	profile:transact(function(tx)
		tx:increment("coins", 10)
		tx:append("inventory", "starter sword")
	end, { note = "first join reward" })
end)
```

## Moving existing data

ProfileStore keeps each profile in its own record format, so Geode can't read those keys directly. Keep the old store for reading and copy each player's data across the first time they join, inside a migration so it happens exactly once.

1. Give the Geode store a new DataStore name, so old and new keys never collide
2. On a player's first Geode load, read their old ProfileStore key with ProfileStore itself, the way your game does today
3. Write the old data into the new profile in one transaction with a note, and keep a flag such as `migrated = true` in the template so it never runs twice

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

-- Stands in for reading the player's old ProfileStore data
local function readOldData(userId: number): { coins: number }?
	return { coins = 250 }
end

local PlayerData = Geode.players({
	name = "PlayerDataV2",
	template = { coins = 0, migrated = false },
})

PlayerData:onLoaded(function(player, profile)
	if profile:get("migrated") then
		return
	end
	local old = readOldData(player.UserId)
	profile:transact(function(tx)
		if old then
			tx:set("coins", old.coins)
		end
		tx:set("migrated", true)
	end, { note = "moved from ProfileStore" })
end)
```

Once every active player has been moved, the old store can stay readable for support cases and be dropped later.
