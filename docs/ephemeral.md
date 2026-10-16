---
sidebar_position: 9
---

# Ephemeral stores and premades

MemoryStore is fast and shared by every server, but its data expires and its quota is shared by the whole experience. Geode wraps it with validation and retries, and builds the tools most games write by hand on top. Nothing here costs quota until you create it.

## Wrappers

`Geode.Ephemeral` gives hash maps, sorted maps and queues. Values are checked against an optional schema before they're written, and every call goes through the scheduler, so throttles are retried with backoff.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local Lobbies = Geode.Ephemeral.hashMap("Lobbies", {
	schema = Geode.t.struct({ host = Geode.t.integer(), open = Geode.t.boolean() }),
})

Lobbies:set("lobby_7", { host = 1001, open = true }, 300)

local lobby = Lobbies:get("lobby_7")
if lobby.ok then
	print(lobby.value)
end
```

## Premades

| Premade                                          | What it gives you                                              |
| ------------------------------------------------ | -------------------------------------------------------------- |
| `Geode.Presence.new(options)`                    | Which server each player is on, kept alive with heartbeats     |
| `Geode.Mutex.new(name, options)`                 | A lock every server respects, with a lease and a fencing token |
| `Geode.Counter.new(name, options)`               | Counters every server can change atomically                    |
| `Geode.RateLimiter.new(name, { limit, window })` | A limit shared by every server, counted in fixed windows       |
| `Geode.JobQueue.new(name, options)`              | Jobs any server adds and one server at a time claims           |

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local Bosses = Geode.Mutex.new("Bosses", { lease = 30 })
local acquired = Bosses:acquire("dragon", 5)
if acquired.ok and acquired.value then
	local lock = acquired.value
	print("spawning the dragon with token", lock.token)
	lock:release()
end

local Kills = Geode.Counter.new("Kills")
Kills:increment("global", 1)

local Trades = Geode.RateLimiter.new("Trades", { limit = 5, window = 60 })
local allowed = Trades:allow("player_1001")
if allowed.ok and not allowed.value then
	print("too many trades, try again in a minute")
end

local Rewards = Geode.JobQueue.new("Rewards")
Rewards:push({ userId = 1001, coins = 100 })
local claimed = Rewards:claim()
if claimed.ok and claimed.value then
	print(#claimed.value.jobs, "jobs to grant")
	claimed.value:ack()
end
```

A few choices keep quota low, and each one is visible:

- A rate limiter counts in fixed windows with one atomic update per check, so a burst across a window edge can reach twice the limit
- A lock's token never goes below the wall clock in milliseconds, so it keeps growing even after the stored item expires. Pass it along with writes so a holder whose lease ran out can be refused
- A job that isn't acknowledged reappears once its invisibility timeout passes

Every premade reports `estimatedCost()`, the requests per minute it's spending right now.
