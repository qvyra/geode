---
sidebar_position: 1
---

# Introduction

Geode is a data framework for Roblox. It puts DataStoreService, MemoryStoreService and MessagingService behind one API, with session-locked player data, guards, reactive data and replication on top.

> Geode is in early development. The API can still change before 1.0.

Geode is an independent project. It shares no code with ProfileStore, ProfileService or Lapis. If you're coming from one of them, [Coming from ProfileStore, ProfileService or Lapis](coming-from-profilestore) maps what you know.

## What it does

- Player data with the whole lifecycle handled: load on join, autosave, save and release on leave or shutdown
- Session locking with the lease kept in the DataStore record, and fast server hops
- Purchases granted exactly once, a mailbox for players who are offline, and erasure on request
- Schemas with Roblox datatypes, migrations, and size budgets that warn or refuse but never trim
- Guards that every write has to pass, plus bundles, reactions and derived fields
- Shared stores, MemoryStore structures and premades, matchmaking and leaderboards
- Replication to clients, history, rollback and an audit log
- In-memory services with fault injection and a virtual clock, so all of it runs in tests without Roblox

## How it fits together

Geode is built in layers. The top one, `Geode.players`, handles player data in one call. Underneath are stores you configure yourself, then the primitives they are made of, then adapters over the Roblox services. Each layer only uses the public API of the one below it, so you can start at the top and drop down when you need more control. [Concepts](concepts) goes through the layers and the transaction pipeline every write runs through.

## Where to go next

- [How it works](how-it-works), the life of a player's data from join to leave
- [Installation](installation)
- [Getting started](getting-started)
- [Developer products](developer-products)
- [Troubleshooting](troubleshooting) when something doesn't behave the way you expect
