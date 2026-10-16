---
sidebar_position: 13
---

# Matchmaking and leaderboards

## Matchmaking

`Geode.Matchmaker.new` makes a matchmaker for one mode and region. Any server adds and cancels tickets. One server per mode and region is elected to group tickets into matches every couple of seconds, so reads don't grow with the number of servers. When that server goes away, its lock runs out and another one takes over.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local Arena = Geode.Matchmaker.new({
	name = "Arena",
	placeId = 1234567,
	matchSize = 4,
	mode = "ranked",
	region = "eu",
	band = { start = 100, widenPerSecond = 10, max = 800 },
	onMatch = function(match)
		print("match", match.id, "for", #match.players, "players")
	end,
})
Arena:start()

local ticket = Arena:enqueue({ 1001, 1002 }, 1450)
if ticket.ok then
	local status = Arena:status(ticket.value)
	if status.ok and status.value.state == "matched" then
		print("reserved server", status.value.ticket and status.value.ticket.reservedCode)
	end
end
```

- A party is one ticket and always lands in the same match
- The rating band a ticket accepts widens the longer it waits
- Every ticket is claimed with an atomic update that only lands while it's unclaimed, and a pass that loses any claim gives back the others, so a player is never placed in two matches even while two servers overlap during a handover
- A matched ticket carries the reserved server's code, and `Arena:teleport(ticket, players)` sends that server's players there

## Leaderboards

All-time boards live in an OrderedDataStore and last forever. Windowed boards keep one MemoryStore sorted map per window, which expires a grace period after the window closes. Daily and weekly windows follow UTC, and weeks start on Monday.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local Wins = Geode.Ranked.allTime("Wins", { mode = "sum" })
Wins:submit(1001, 1)

local Daily = Geode.Ranked.windowed("DailyScore", { window = "daily", mode = "max" })
Daily:submit(1001, 4200)

local top = Daily:top(10)
if top.ok then
	for rank, entry in top.value do
		print(rank, entry.userId, entry.score)
	end
end
```

A submit combines with the stored score by mode: `max` and `min` keep the best, `sum` adds up and `latest` replaces. Top lists are cached for 30 seconds by default, so a busy lobby doesn't spend quota on every refresh.
