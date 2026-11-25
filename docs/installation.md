---
sidebar_position: 3
---

# Installation

## Wally

Add Geode to the `[dependencies]` of your `wally.toml` and run `wally install`:

```toml
[dependencies]
Geode = "qvyra/geode@0.8.0"
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

The typings cover the whole API with the same names and shapes as Luau. Luau `nil` is `undefined`, and a result is narrowed by checking its `ok` field first. A `template` can be any object type, so data declared as an `interface` fits. The npm package has the same version number as the Wally one.

### Typed paths

Give `Geode.players`, `Geode.Profile.store` or `Geode.Client.start` the data's type and every path and value is checked against it. Paths are then lists: `["settings", "music"]`, with a `string` for a key of a record and a 1-based `number` for an item of a list. Reads come back frozen and typed by the path, and the ops only take paths that lead to the right kind of value: `increment` a number, `append` and `insert` a list.

```ts
import Geode from "@rbxts/geode";

interface Data {
	coins: number;
	settings: { music: boolean };
	inventory: { id: string }[];
	pets: Record<string, { level: number }>;
}

const playerData = Geode.players<Data>({
	name: "PlayerData",
	template: { coins: 0, settings: { music: true }, inventory: [], pets: {} },
});

playerData.onLoaded((player, profile) => {
	profile.increment(["coins"], 100);
	profile.append(["inventory"], { id: "sword" });
	const music: boolean = profile.get(["settings", "music"]);
	// a pet that isn't there reads undefined
	const level: number | undefined = profile.get(["pets", "rex", "level"]);
	print(player.Name, music, level);
});

const client = Geode.Client.start<Data>();
// undefined until the data arrives
const coins = client.atom(["coins"]);
print(coins.get());
```

Without a type, a store takes any `Path` and reads `unknown`, the same as before, so existing code compiles as it is. Paths are checked up to eight segments; past that any tail is accepted and its value still checked. A client atom reads `undefined` until the data arrives, and for paths the server doesn't send.

## Model file

Without Rojo or a package manager, use the model file. Every [release](https://github.com/qvyra/geode/releases) has `Geode.rbxm` under its Assets, the same Geode the Wally and npm packages hold:

1. Download `Geode.rbxm` from the [latest release](https://github.com/qvyra/geode/releases/latest)
2. In Studio, right-click ReplicatedStorage in the Explorer, choose Insert from File and pick the file. A ModuleScript named `Geode` appears
3. Require it from there:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Geode)
```

The examples in these docs use `ReplicatedStorage.Packages.Geode`; with the model file, it's `ReplicatedStorage.Geode` instead, or put it in a `Packages` folder of your own. To update, download the newer file and replace the module with it. Saved data isn't in the module, so it stays as it is.

A Creator Store copy of the model may come later, as one more way to get the same file.

## Studio

Out of the box, Studio keeps the data of every store in memory, so playtests never touch real data and don't need DataStore access. To test against real DataStores, either in a separate scope or against live data, turn on Studio access to API Services in the experience's settings and set the Studio mode, as shown in [Profiles](profiles).

## Where Geode lives

Geode works from any folder, under any name, as long as server scripts can require it. Its main module carries the `Geode` tag (CollectionService) and a `GeodeVersion` attribute with its version, whichever way it was installed, so tools can find it with `CollectionService:GetTagged("Geode")` wherever it is.
