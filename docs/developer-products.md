---
sidebar_position: 5
---

# Developer products

A developer product purchase has to be granted exactly once, even if the server crashes halfway or Roblox calls ProcessReceipt again for the same purchase. Geode handles the receipt side for you.

## With Geode.players

List your products in `products`. Each handler runs inside a transaction on the buyer's profile:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local PlayerData = Geode.players({
	name = "PlayerData",
	template = { coins = 0, gems = 0 },
	products = {
		[1234567] = function(tx)
			tx:increment("coins", 500)
		end,
		[7654321] = function(tx, info)
			tx:increment("gems", 10)
		end,
	},
})
```

`Geode.players` sets ProcessReceipt for you, so only one `Geode.players` store in a game can take `products`.

## What happens on a purchase

1. Roblox calls ProcessReceipt with the purchase id
2. If the buyer's profile isn't loaded on this server, Geode answers "not processed yet" and Roblox asks again later
3. If the purchase id is already recorded in the profile, the handler doesn't run again
4. Otherwise the handler and the purchase id commit in one transaction
5. Geode makes sure that commit is saved, and only then tells Roblox the purchase was granted

If the server dies before step 5, the grant and the record of it are lost together, and Roblox asks again on the player's next server. A handler that throws refuses the purchase for now, and nothing it wrote is kept. A product with no handler stays pending and is reported.

Each profile keeps its most recent purchase ids, 50 by default, set with the store option `receiptHistory`. `profile:wipe()` resets data to the template but keeps those ids.

## Without Geode.players

For a store you made with `Geode.Profile.store`, build the callback with `Geode.receipts(store, handlers)` and assign it to `MarketplaceService.ProcessReceipt` yourself. It behaves the same way. See `Geode.receipts` in the API reference.
