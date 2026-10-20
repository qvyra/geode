---
sidebar_position: 17
---

# Coming from ProfileStore, ProfileService or Lapis

Geode is an independent project and shares no code with ProfileStore, ProfileService or Lapis. It covers a lot of the same ground, though: session-locked profiles, a template, filling in missing fields, safe server hops and developer products. This page maps what you know to Geode and shows how to move existing data.

The biggest difference is that data is no longer a table you edit in place. Writes go through ops and transactions, and reads return frozen values. That one write path is what lets guards, reactions, replication and history see every change.

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

## From ProfileStore

| ProfileStore                           | Geode                                                                   | Notes                                                                                                                   |
| -------------------------------------- | ----------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `ProfileStore.New(name, template)`     | `Geode.Profile.store({ name = name, template = template })`             | Or `Geode.players`, which also loads on join and releases on leave                                                      |
| `store:StartSessionAsync(key)`         | `store:load(key, { userId = userId })`                                  | Returns a result: `result.ok`, then `result.profile` or `result.error`                                                  |
| `Steal = true`                         | `stealPolicy = "steal"` with `stealAfter = 0`                           | Set on the store, not per call. By default Geode already takes over after 15 s if the holder doesn't let go             |
| `Cancel` callback                      | `stealPolicy = "fail"`, `loadTimeout`                                   | There's no polled cancel function                                                                                       |
| `profile.Data.coins += 10`             | `profile:increment("coins", 10)`                                        | Read with `profile:get("coins")`                                                                                        |
| `profile:Reconcile()`                  | Automatic on every load                                                 | Lists aren't merged, and keys the template doesn't know are kept                                                        |
| `profile:EndSession()`                 | `profile:release()`                                                     | Saves once more, then gives up the lease                                                                                |
| `profile:IsActive()`                   | `profile:isActive()`                                                    |                                                                                                                         |
| `profile:Save()`                       | `profile:save()`                                                        |                                                                                                                         |
| `profile.OnSessionEnd`                 | `profile.released` and `profile.sessionLost`                            | Split in two: a normal release, and a session another server took                                                       |
| `profile.OnAfterSave`                  | `profile.saved`                                                         | Fires after a save succeeds. To react to each change, use `profile:observe` or `profile:onCommit`                       |
| `profile:AddUserId(userId)`            | `userId` or `userIds` load option                                       | Given when the profile loads                                                                                            |
| `store:MessageAsync(key, message)`     | `store:mail(key, op, ...)`                                              | Queues an op that applies exactly once, the next time the profile loads. It doesn't reach a profile that's already open |
| `profile:MessageHandler(fn)`           | Not needed                                                              | Mail runs as a transaction on load, in a store made with `mailbox = true`                                               |
| `store:VersionQuery(key)`              | `store:history(key)`, then `store:version(key, id)`                     |                                                                                                                         |
| `store:GetAsync(key)`                  | No direct equivalent                                                    | `store:version` reads a stored version. `store:get(key)` only returns profiles open on this server                      |
| `profile:SetAsync()` on an old version | `store:rollback(key, versionId, note)`                                  | Goes through the server holding the profile instead of ending its session                                               |
| `store:RemoveAsync(key)`               | `store:erase(key)`, or `Geode.erase(userId)` for every store            | Leaves an erased marker. A server still holding the profile loses its session instead of writing it back                |
| `ProfileStore.Mock`                    | Studio mode `"mock"`, the default in Studio, or `Geode.Testing` in Lune |                                                                                                                         |
| Developer products                     | The `products` option of `Geode.players`, or `Geode.receipts`           | Purchase ids are tracked for you. See [Developer products](developer-products)                                          |

## From ProfileService

Most ProfileStore rows apply here too. These are the ones that differ:

| ProfileService                                   | Geode                                                       | Notes                                                                                                               |
| ------------------------------------------------ | ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `ProfileService.GetProfileStore(name, template)` | `Geode.Profile.store({ name = name, template = template })` |                                                                                                                     |
| `store:LoadProfileAsync(key, "ForceLoad")`       | `store:load(key)`                                           | The default `stealPolicy = "steal"` asks the holder to release first and takes the lease after `stealAfter` seconds |
| `"Steal"`                                        | `stealPolicy = "steal"` with `stealAfter = 0`               |                                                                                                                     |
| A handler returning `"Cancel"`                   | `stealPolicy = "fail"`                                      | The load fails with `leaseHeld`                                                                                     |
| `profile:Release()`                              | `profile:release()`                                         |                                                                                                                     |
| `profile:ListenToRelease(fn)`                    | `profile.released` and `profile.sessionLost`                | `Geode.players` already kicks a player whose session another server took                                            |
| `profile:ListenToHopReady(fn)`                   | No direct equivalent                                        | The new server asks the old one to release, so a teleport doesn't need to wait for it                               |
| `GlobalUpdates`                                  | `store:mail(key, op, ...)`                                  | No active and locked stages. Each mail op applies once, on the next load                                            |
| MetaTags                                         | Keep the value in the data                                  | Purchase ids are kept for you, outside your data                                                                    |
| `store:ViewProfileAsync(key)`                    | `store:history(key)` and `store:version(key, id)`           | See the `GetAsync` row above                                                                                        |
| `store:WipeProfileAsync(key)`                    | `store:erase(key)`                                          |                                                                                                                     |
| Autosave every 30 s                              | Every 60 s by default                                       | Set with `autosaveInterval` on the store                                                                            |

## From Lapis

| Lapis                                           | Geode                                                 | Notes                                                                                                   |
| ----------------------------------------------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `Lapis.createCollection(name, options)`         | `Geode.Profile.store({ name = name, ... })`           | A collection is a store, a document is a profile                                                        |
| `defaultData`                                   | `template`                                            | Missing fields are filled in on every load                                                              |
| `validate`                                      | `schema`, and guards for rules across fields          | Checked on every write, not only when saving                                                            |
| `migrations`                                    | `migrations` keyed by version, plus `schemaVersion`   | Each one runs as a transaction on the stored form, oldest first                                         |
| `backwardsCompatible`                           | No direct equivalent                                  | A server that finds data saved by a newer schema version fails the load with `newerData`                |
| `collection:load(key)`                          | `store:load(key)`                                     | Yields and returns a result instead of a promise                                                        |
| `document:read()`                               | `profile:get()` or `profile:snapshot()`               | Frozen, like Lapis's default                                                                            |
| `document:write(data)`                          | Ops, or `profile:set({}, data)` to replace everything |                                                                                                         |
| `document:close()`                              | `profile:release()`                                   |                                                                                                         |
| `document:save()`                               | `profile:save()`                                      |                                                                                                         |
| `beforeSave`, `beforeClose`                     | Reactions and derived fields                          | They run inside each transaction, not at save time. See [Bundles, reactions and derived fields](facets) |
| `defaultUserIds`, `addUserId`                   | `userId` or `userIds` load option                     |                                                                                                         |
| `collection:remove(key)`                        | `store:erase(key)`                                    |                                                                                                         |
| A locked load retries, then errors              | `stealPolicy = "fail"`                                | Geode's default takes the lease over instead                                                            |
| `setConfig({ dataStoreService = ... })` to mock | Studio mode `"mock"`, or `Geode.Testing`              |                                                                                                         |

## Moving existing data

Each of these libraries keeps data in its own record format, so Geode can't read those keys directly. Keep the old library for reading and copy each player's data across the first time they join, behind a flag so it happens once.

1. Give the Geode store a new DataStore name, so old and new keys never collide
2. On a player's first Geode load, read their old data with the old library, the way your game does today
3. Write the old data into the new profile in one transaction with a note, and keep a flag such as `migrated = true` in the template so it never runs twice

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

-- Stands in for reading the player's old data with the library you used before
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
	end, { note = "moved from the old store" })
end)
```

Once every active player has been moved, the old store can stay readable for support cases and be dropped later.
