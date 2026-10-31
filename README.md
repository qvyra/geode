<p align="center"><img src="https://raw.githubusercontent.com/qvyra/geode/main/.moonwave/static/geode.png" alt="Geode logo" width="160"></p>

# Geode

A data framework for Roblox. Geode puts DataStoreService, MemoryStoreService and MessagingService behind one API, with session-locked player data, guards, reactive data and replication on top.

> Geode is in early development. The API can still change before 1.0.

Geode is an independent project. It shares no code with ProfileStore, ProfileService or Lapis. If you're coming from one of them, [this guide](https://qvyra.github.io/geode/docs/coming-from-profilestore) maps what you know.

## Features

- **Player data in one call:** profiles load on join, autosave, and save and release on leave or shutdown
- **Session locking:** a session lease lives in the DataStore record, so two servers never write the same profile
- **Fast server hops:** the old server is asked to release instead of waiting out the lease
- **Purchases granted once:** each grant and its receipt are saved together
- **Migrations and schemas,** including Roblox datatypes, with size budgets that never trim data
- **Guards:** rules every write must pass, from clients and servers alike
- **Bundles, reactions and derived fields** that stay consistent with the data
- **Shared stores** for data any server writes
- **MemoryStore helpers:** presence, locks, counters, rate limits and job queues
- **Matchmaking and leaderboards**
- **Replication** of chosen paths to clients, read there as atoms
- **History, rollback and an audit log**
- **Testable without Roblox:** in-memory services with fault injection and a virtual clock

## Install

With [Wally](https://wally.run), add Geode to `wally.toml` and run `wally install`:

```toml
[dependencies]
Geode = "qvyra/geode@0.6.1"
```

With roblox-ts, install it from npm:

```sh
npm i @rbxts/geode
```

and import it with `import Geode from "@rbxts/geode"`. The typings cover the whole API with the same names as Luau.

Without Rojo or a package manager, download `Geode.rbxm` from the [latest release](https://github.com/qvyra/geode/releases/latest) and insert it in Studio: right-click ReplicatedStorage, choose Insert from File and pick the file. Then require it with `require(ReplicatedStorage.Geode)`. The [installation page](https://qvyra.github.io/geode/docs/installation#model-file) has the details.

## Quick start

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

Each player's data loads when they join and is saved and released when they leave or the server shuts down. `coins` replicates to its owner and `level` to everyone.

## Documentation

- [Docs site](https://qvyra.github.io/geode): installation, getting started, guides for every part, troubleshooting and the API reference
- [DECISIONS.md](DECISIONS.md): why Geode is built the way it is
- `example/`: a small game that uses most of it
- [CONTRIBUTING.md](CONTRIBUTING.md): setup and the check suite

## License

MIT, see [LICENSE](LICENSE).
