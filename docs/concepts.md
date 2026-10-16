---
sidebar_position: 4
---

# Concepts

## The layers

Geode is built in layers. Each layer only uses the public API of the one below it, so you can start at the top and drop down a level whenever you need more control.

| Layer          | What it holds                                                                                   | Who it's for                          |
| -------------- | ----------------------------------------------------------------------------------------------- | ------------------------------------- |
| Beginner layer | `Geode.players` and `Geode.setup`: player data with the lifecycle handled                       | Most games                            |
| Stores         | Profiles, shared stores, ephemeral stores, leaderboards, the matchmaker and the premades        | Games that need more than player data |
| Primitives     | The scheduler, schemas, transactions, leases, guards, bundles and reactions                     | Custom stores                         |
| Adapters       | DataStore, MemoryStore, MessagingService and remotes behind one interface, plus in-memory mocks | Tests and tooling                     |

`PlayerData.store` is the profile store the beginner layer made, with every option visible. `Geode.Raw` gives the adapters and primitives directly.

## One write path

Every change to data goes through the same transaction pipeline, whoever makes it: game code, a reaction, a mail message, a migration or a tool.

1. The transaction body runs ops against a draft of the current state
2. Bundles normalize the fields they own
3. Reactions run in dependency order, in the same transaction
4. Guards judge the final change and can reject all of it
5. The commit applies the draft and records what changed
6. Listeners, replication and telemetry hear about the commit

A transaction is all or nothing. If a guard rejects it, every write in it is undone, including what reactions wrote.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local document = Geode.Raw.document({ data = { coins = 50, inventory = {} } })

local result = document:transact(function(tx)
	tx:decrement("coins", 30)
	tx:append("inventory", "sword")
end, { source = "system", note = "shop purchase" })

if result.ok and result.record then
	print("now at revision", result.record.revision)
end
```

Reads hand out frozen values, so nothing outside a transaction can change data by accident.

## What each Roblox service does in Geode

**DataStore is the source of truth.** Profiles, shared stores and all-time leaderboards live there. Every profile write is an UpdateAsync that also checks the session lease, so two servers can never write the same profile at once.

**MemoryStore makes things faster or more convenient, never more correct.** It holds the handoff key that speeds up server hops, the ephemeral stores and premades, windowed leaderboards and the matchmaker's queue. If MemoryStore is down, profiles still load and save correctly, just more slowly when a player hops servers.

**MessagingService coordinates servers.** A server that wants a profile asks the server holding it to let go, shared stores tell each other when a key changed, and rollbacks reach the server that holds a profile. Messages can be lost, so nothing depends on one arriving: each one only says "try now".

Every request goes through a scheduler that runs releases before saves, saves before loads and loads before background work, stays inside the request budgets and retries throttled calls with backoff.
