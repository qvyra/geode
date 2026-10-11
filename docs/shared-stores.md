---
sidebar_position: 6
---

# Shared stores

A shared store holds data no single server owns, like global configuration, guild banks or an auction. There is no lease: any server may write any key at any time.

## Writing

Every write is an UpdateAsync transform that runs the whole pipeline, bundles, reactions and guards included, against the freshest stored value. Two servers writing at once never lose each other's changes, and guards judge what will really be stored.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local Guilds = Geode.Shared.store({
	name = "Guilds",
	template = { bank = 0, members = {} },
	guards = { Geode.guard.range("bank", { min = 0 }) },
})

local deposit = Guilds:increment("guild_42", "bank", 500)
if not deposit.ok then
	warn(deposit.error.kind, deposit.error.message)
end

Guilds:transact("guild_42", function(tx)
	tx:append("members", 1001)
	tx:decrement("bank", 100)
end, { note = "new member fee" })
```

Because UpdateAsync can run a transform more than once, everything inside it must be synchronous: the transaction body and every custom guard, bundle and reaction of the store. A transaction that yields fails with an error instead of writing. Listeners and deferred callbacks run once, after the write landed.

## Reading

Reads come from a cache that lives 30 seconds by default. A write tells other servers over MessagingService that the key changed, so they read it again sooner, but the cache lifetime is what bounds staleness.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local Config = Geode.Shared.store({
	name = "Config",
	template = { eventActive = false, multiplier = 1 },
	cacheTtl = 10,
})

local multiplier = Config:get("live", "multiplier")
if multiplier.ok then
	print("multiplier", multiplier.value)
end

Config:observe("live", "eventActive", function(active)
	print("event active", active)
end)
```

When a refresh fails, a read serves the value it already has and reports the failure, since a slightly stale value is better than none.
