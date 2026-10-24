---
sidebar_position: 14
---

# Replication and remote ops

Clients see the data the server chooses to share, and never write it. When a player wants something changed, the client asks for a declared op and the server decides.

## Visibility

Each path is `private` (the default), `owner` or `public`. Owner paths reach their own player, public paths reach everyone, private paths never leave the server. A path under a shared one can't be stricter, since the shared path sends everything under it, and a map that tries is refused when the store is made.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local PlayerData = Geode.players({
	name = "PlayerData",
	template = { coins = 0, level = 1, inventory = {}, banReason = "" },
	replicate = { coins = "owner", inventory = "owner", level = "public" },
})
```

After each commit, only the visible paths that changed are queued, and the queue goes out once per frame, so a burst of writes costs one remote call. A client that joins or asks to resync gets a full snapshot first.

## Remote ops

`Geode.remoteOp` lets clients ask for an op on their own profile. Each request is checked in order of cost: the attempt rate limit first, then each argument against its schema, then the store's pipeline with a player source, so every guard knows who asked.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local PRICES = { sword = 100, shield = 75 }

Geode.op("guideBuyItem", function(tx, item: string)
	tx:decrement("coins", PRICES[item])
	tx:append("inventory", item)
end)

local PlayerData = Geode.players({
	name = "PlayerData",
	template = { coins = 0, inventory = {} },
	replicate = { coins = "owner", inventory = "owner" },
	ops = { "guideBuyItem" },
	guards = { Geode.guard.range("coins", { min = 0 }) },
})

Geode.remoteOp("guideBuyItem", {
	store = PlayerData.store,
	args = { Geode.t.enum({ "sword", "shield" }) },
	rateLimit = { count = 5, window = 10, action = "drop" },
})
```

Remote ops send no answer. The client sees the result through replication, which also keeps a refused request from revealing why it was refused.

## The client

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local client = Geode.Client.start()

local coins = client:atom("coins")
local inventory = client:atom("inventory")

local worth = client:computed(function()
	return (coins:get() or 0) + #(inventory:get() or {}) * 50
end)

worth:subscribe(function(value)
	print("total worth", value)
end)

client:op("guideBuyItem", "sword")
```

`atom(path, userId)` reads another player's public paths. `computed` tracks the atoms it reads and runs again when any of them changes. To use Charm instead, pass the Charm module to `client:charm(Charm)` and its `atom(path)` returns Charm atoms that follow the replicated data.

In roblox-ts the client has the same names: `Geode.Client.start()` from `@rbxts/geode`, then `client.atom("coins")` and the rest.
