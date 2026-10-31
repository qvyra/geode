---
sidebar_position: 3
---

# Installation

## Wally

Add Geode to the `[dependencies]` of your `wally.toml` and run `wally install`:

```toml
[dependencies]
Geode = "qvyra/geode@0.6.1"
```

Wally puts it in `Packages`. The examples in these docs expect that folder in ReplicatedStorage, so clients can reach it too:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)
```

## roblox-ts

Install the package from npm:

```sh
npm i @rbxts/geode
```

It holds the Luau source and its typings. The Rojo project of a roblox-ts game already puts `node_modules/@rbxts` in ReplicatedStorage, so clients can reach it too, and there is nothing else to set up:

```ts
import Geode from "@rbxts/geode";

const playerData = Geode.players({
	name: "PlayerData",
	template: { coins: 0, level: 1 },
});

playerData.onLoaded((player, profile) => {
	profile.increment("coins", 100);
});
```

The typings cover the whole API with the same names and shapes as Luau. Luau `nil` is `undefined`, and a result is narrowed by checking its `ok` field first. The npm package has the same version number as the Wally one.

## Studio

Out of the box, Studio keeps player data in memory, so playtests never touch real data and don't need DataStore access. To test against real DataStores, either in a separate scope or against live data, turn on Studio access to API Services in the experience's settings and set the Studio mode, as shown in [Profiles](profiles).

## Where Geode lives

Geode works from any folder, under any name, as long as server scripts can require it. Its main module carries the `Geode` tag (CollectionService) and a `GeodeVersion` attribute with its version, whichever way it was installed, so tools can find it with `CollectionService:GetTagged("Geode")` wherever it is.
