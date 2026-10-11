---
sidebar_position: 1
---

# Getting started

Geode is a data framework for Roblox. It puts DataStoreService, MemoryStoreService and MessagingService behind one API, with guards, reactive data and replication on top.

## Install

With [Wally](https://wally.run), add Geode to `wally.toml` and run `wally install`:

```toml
[dependencies]
Geode = "qvyra/geode@0.3.0"
```

With roblox-ts, install the package from npm:

```sh
npm install @rbxts/geode
```

The npm package ships hand-written typings for the whole API, so TypeScript code gets the same names and shapes as Luau code.

## Quick start

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

The same in TypeScript:

```ts
import Geode from "@rbxts/geode";

const playerData = Geode.players({
	name: "PlayerData",
	template: { coins: 0, xp: 0, level: 1, inventory: [] },
	replicate: { coins: "owner", level: "public" },
});

playerData.onLoaded((player, profile) => {
	profile.increment("coins", 100);
});
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

- [Concepts](concepts) explains the layers and the transaction pipeline every write goes through
- [Profiles and the beginner layer](profiles) covers player data in depth
- [Testing with Geode.Testing](testing) shows how to run all of it in Lune without Roblox
