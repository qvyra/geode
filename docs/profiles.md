---
sidebar_position: 5
---

# Profiles and the beginner layer

A profile is one player's data, held by one server at a time under a session lease. The beginner layer, `Geode.players`, loads and releases profiles for you. The profile store underneath is there when you need more control.

## Player data with Geode.players

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local PlayerData = Geode.players({
	name = "PlayerData",
	template = { coins = 0, level = 1, inventory = {} },
	products = {
		[1234567] = function(tx)
			tx:increment("coins", 500)
		end,
	},
})

PlayerData:onLoaded(function(player, profile)
	print(player.Name, "has", profile:get("coins"), "coins")
end)

PlayerData:onReleased(function(player)
	print(player.Name, "was saved and released")
end)
```

What it handles:

- A player's profile loads when they join and is released when they leave. A load that can pass on its own is retried, and a player whose data can't load is kicked with a clear message instead of playing without it
- Shutdown releases every profile, and a profile another server takes over ends its session here
- Listed developer products are granted exactly once. The grant and its receipt are saved together, and the purchase only counts as granted after that save succeeds
- In Studio, data stays in memory unless you ask for a separate scope or live data

## Before the data loads

`PlayerData:get(player)` works from the moment a player joins. Until their profile loads, reads return the template and writes are refused, so UI code can draw defaults right away and check `isLoaded` to tell them from real data.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)
local Players = game:GetService("Players")

local PlayerData = Geode.players({
	name = "PlayerData",
	template = { coins = 0 },
})

for _, player in Players:GetPlayers() do
	local data = PlayerData:get(player)
	if data then
		print(data:get("coins"), data:isLoaded())
	end
	local profile = PlayerData:waitFor(player, 10)
	if profile then
		profile:increment("coins")
	end
end
```

## Shared defaults with Geode.setup

`Geode.setup` sets the services, one shared scheduler, error reporting and the Studio mode for every `Geode.players` store made after it. Call it once, before making any store.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

Geode.setup({ studio = "scope" })

local PlayerData = Geode.players({ name = "PlayerData", template = { coins = 0 } })
```

## Profile stores

`Geode.Profile.store` makes a store you load profiles from yourself, by any key. `PlayerData.store` is one of these.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local Guilds = Geode.Profile.store({
	name = "GuildData",
	template = { members = {}, bank = 0 },
	autosaveInterval = 60,
})

local result = Guilds:load("guild_42")
if result.ok then
	local profile = result.profile
	profile:increment("bank", 250)
	profile:release()
else
	warn(result.error.kind, result.error.message)
end
```

A profile's writes go through the transaction pipeline: `set`, `increment`, `decrement`, `append`, `insert`, `remove`, `clear`, `merge`, `update`, custom ops and `transact` for several at once. Reads return frozen values. `observe` calls back after each commit that changes a path.

## Schemas and migrations

A schema checks every write and converts Roblox datatypes to and from their stored form. Migrations upgrade data saved by an older schema version, oldest first, before the schema decodes it.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)
local t = Geode.t

local Profiles = Geode.Profile.store({
	name = "Profiles",
	template = { coins = 0, spawn = Vector3.new(0, 5, 0) },
	schema = t.struct({
		coins = t.integer({ min = 0 }),
		spawn = Geode.codec.Vector3,
	}),
	schemaVersion = 2,
	migrations = {
		[2] = function(tx)
			if tx:get("gold") ~= nil then
				tx:set("coins", tx:get("gold"))
				tx:remove("gold")
			end
		end,
	},
})
```

Missing template fields are filled in on load. Unknown fields are never removed without a migration.

## Mail for offline players

`store:mail` queues an op for a profile wherever its player is. It applies, exactly once, the next time the profile loads.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local PlayerData = Geode.players({ name = "PlayerData", template = { coins = 0 } })

PlayerData.store:mail(PlayerData.store:keyForUser(1001), "increment", "coins", 50)
```

## How sessions stay safe

Each profile record holds a session lease. Every save is an UpdateAsync that writes the data and renews the lease in one step, and only if the lease is still this server's. A server that finds the lease held elsewhere asks the holder to release it and waits for the release, so a player hopping servers usually waits only for the old server's final save. A server that stops renewing its lease loses it, and its next save refuses to write instead of overwriting newer data.
