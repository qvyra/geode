---
sidebar_position: 2
---

# Installation

## Wally

Add Geode to the `[dependencies]` of your `wally.toml` and run `wally install`:

```toml
[dependencies]
Geode = "qvyra/geode@0.4.0"
```

Wally puts it in `Packages`. The examples in these docs expect that folder in ReplicatedStorage, so clients can reach it too:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)
```

## roblox-ts

A roblox-ts package is coming. Its typings already cover the whole API with the same names and shapes as Luau.

## Studio

Out of the box, Studio keeps player data in memory, so playtests never touch real data and don't need DataStore access. To test against real DataStores, either in a separate scope or against live data, turn on Studio access to API Services in the experience's settings and set the Studio mode, as shown in [Profiles](profiles).
