---
sidebar_position: 4
---

# Getting started

Player data with the whole lifecycle handled takes one call. Each player's data loads when they join, autosaves, and is saved and released when they leave or the server shuts down.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local PlayerData = Geode.players({
	name = "PlayerData",
	template = { coins = 0, xp = 0, level = 1, inventory = {} },
	replicate = { coins = "owner", level = "public" },
})

PlayerData:onLoaded(function(player, profile)
	profile:increment("coins", 100)
end)
```

`replicate` sends `coins` to its owner and `level` to everyone. Every other path stays on the server. On the client, those paths arrive as atoms:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local client = Geode.Client.start()
client:atom("coins"):subscribe(function(coins)
	print("coins", coins)
end)
```

## Where to go next

- [How it works](how-it-works) explains session leases, releases and autosave
- [Developer products](developer-products) grants purchases exactly once
- [Concepts](concepts) explains the layers and the transaction pipeline every write goes through
- [Profiles and the beginner layer](profiles) covers player data in depth
- [Testing with Geode.Testing](testing) shows how to run all of it in Lune without Roblox
