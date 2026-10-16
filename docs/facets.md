---
sidebar_position: 10
---

# Bundles, reactions and derived fields

Facets add behavior to the data itself, so it happens on every write without the code that made the write knowing about it.

## Bundles

A bundle owns a group of fields that must stay consistent, like experience and level. Its normalize function runs whenever any of its fields change, in the same transaction.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local levels = Geode.bundle({ "xp", "level" }, function(tx)
	local xp = tx:get("xp") :: number
	local level = tx:get("level") :: number
	while xp >= level * 100 do
		xp -= level * 100
		level += 1
	end
	tx:set("xp", xp)
	tx:set("level", level)
end)

local PlayerData = Geode.players({
	name = "PlayerData",
	template = { xp = 0, level = 1, coins = 0 },
	bundles = { levels },
})
```

## Reactions

A reaction is a one-way effect: when its dependencies change, it writes somewhere else in the same transaction. Reactions declare what they write, so cycles are caught when the store is made instead of looping in a live server. They run in dependency order, and a reaction that writes outside its declaration fails the transaction.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local levelReward = Geode.react({ "level" }, function(tx)
	if tx:get("level") ~= tx:getBefore("level") then
		tx:increment("coins", 50)
	end
end, { writes = { "coins" } })

local PlayerData = Geode.players({
	name = "PlayerData",
	template = { level = 1, coins = 0 },
	reactions = { levelReward },
})
```

## Derived fields

A derived field is computed from other fields and never saved. It reads like normal data, can be observed and can be replicated.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local power = Geode.derive("power", { "level", "inventory" }, function(state)
	return state.level * 10 + #state.inventory
end)

local Profiles = Geode.Profile.store({
	name = "Profiles",
	template = { level = 1, inventory = {} },
	derived = { power },
})

local result = Profiles:load("player_1")
if result.ok then
	print(result.profile:get("power"))
	result.profile:release()
end
```

Derived values are cached and only recomputed when one of their dependencies changes.
