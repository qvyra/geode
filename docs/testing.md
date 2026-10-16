---
sidebar_position: 16
---

# Testing with Geode.Testing

Every Roblox service Geode uses sits behind an adapter with an in-memory mock, so game code built on Geode runs in Lune, without Roblox. `Geode.Testing` gives those mocks, with virtual time and fault injection.

## A universe of servers

A universe holds the data every mock server shares. Each server gets its own services, and stores take them through their `services` option. Time only moves when the test moves it, so tests that wait minutes run instantly and the same way every time.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local universe = Geode.Testing.universe()
local serverA = universe:server({ jobId = "A" })
local serverB = universe:server({ jobId = "B" })

local storeA = Geode.Profile.store({ name = "Players", template = { coins = 0 }, services = serverA })
local storeB = Geode.Profile.store({ name = "Players", template = { coins = 0 }, services = serverB })

universe.clock:run(function()
	local first = storeA:load("player_1")
	assert(first.ok)
	first.profile:increment("coins", 5)
	first.profile:release()

	local second = storeB:load("player_1")
	assert(second.ok and second.profile:get("coins") == 5)
	second.profile:release()
end)
```

`universe.clock:run` runs a function to completion on the virtual clock. `universe.clock:advance(seconds)` moves time forward and runs everything that came due, like autosaves.

## Faults

`server:inject` makes calls from one server fail, slow down, or race with another server's write, so error handling gets tested on purpose rather than by luck.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local universe = Geode.Testing.universe()
local server = universe:server()
local store = Geode.Profile.store({ name = "Players", template = { coins = 0 }, services = server })

-- The next two UpdateAsync calls are throttled, the scheduler retries them
server:inject({ method = "update", fault = "throttle", times = 2 })
-- The next one lands, then reports failure anyway, the way Roblox may
server:inject({ method = "update", fault = { landed = 501 }, times = 1 })

universe.clock:run(function()
	local result = store:load("player_1")
	assert(result.ok)
	result.profile:release()
end)
```

Other faults add latency, return any error code, or land another server's write first. `server:setBudget` caps a request budget, `server:crash()` kills a server mid flight, and `server:shutdown()` runs its BindToClose callbacks.

## Players and clients

Mock servers have players and clients too, so the beginner layer, purchases and replication can be tested end to end.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local universe = Geode.Testing.universe()
local server = universe:server()

local PlayerData = Geode.players({
	name = "TestPlayers",
	template = { coins = 0 },
	replicate = { coins = "owner" },
	services = server,
})

server:join(42)
local client = Geode.Client.start(server:client(42))
universe.clock:advance(1)
print(client:atom("coins"):get())
```

## Live services

The same adapter contract suites the mocks pass also run against live Roblox services, from Studio or headlessly through Open Cloud with `lune run live`. See `tests/studio/README.md` in the repository for the setup.
