---
sidebar_position: 9
---

# Guards

Guards are rules every transaction has to pass before it commits. They judge the final change, after bundles and reactions ran, so they see exactly what would be written. When any guard rejects, the whole transaction is undone.

## Kinds

| Guard                                                 | What it checks                                                                       |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `Geode.guard.range(path, { min, max })`               | The value stays within bounds                                                        |
| `Geode.guard.delta(path, { max, up, down })`          | One change moves the value by at most this much                                      |
| `Geode.guard.rate(path, { count, window })`           | At most `count` committed changes per player in a rolling window                     |
| `Geode.guard.rateValue(path, { gain, loss, window })` | The total gained or lost per player in a rolling window                              |
| `Geode.guard.requires(path, other)`                   | `path` only changes when `other` changed in the same transaction                     |
| `Geode.guard.subset(path, of)`                        | Every item in `path` is also in `of`                                                 |
| `Geode.guard.schema(schema)`                          | Changed regions still match the schema. Stores with a schema add this one themselves |
| `Geode.guard.custom(check)`                           | Your own function gets the diff, the draft state and the context                     |

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)
local guard = Geode.guard

local PlayerData = Geode.players({
	name = "PlayerData",
	template = { coins = 0, level = 1, xp = 0, equipped = {}, inventory = {} },
	guards = {
		guard.range("coins", { min = 0 }),
		guard.rateValue("coins", { gain = 50000, window = 60 }, { action = "kick" }),
		guard.requires("level", "xp"),
		guard.subset("equipped", "inventory"),
		guard.custom(function(diff, state)
			return #diff <= 20, "too many changes at once"
		end, { name = "small changes" }),
	},
})
```

## Actions

Each guard has an action for when it breaks. The default is `reject`.

- `warn` and `flag` log the violation and let the transaction commit
- `reject` undoes the whole transaction. `rollback` is the same thing
- `kick` undoes it and kicks the player who made it
- A function decides for itself. It gets the violation and returns an action name, and returning nothing rejects, so a broken handler fails closed

When several guards break, the strongest action wins: kick, then reject, then flag, then warn. A rejected transaction fails with the kind `rejected`, and `error.guard` names the guard that blocked it. Every violation fires the store's `guardBroken` signal. A violation names the guard, its kind, the path, the reason, the action, the source and player, the ops that ran, and the value at the path before and after the transaction.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local PlayerData = Geode.players({
	name = "PlayerData",
	template = { coins = 0 },
	guards = { Geode.guard.delta("coins", { up = 1000 }, { action = "flag" }) },
})

PlayerData.store.guardBroken:connect(function(violation)
	print(violation.guard, violation.reason, violation.userId)
end)
```

## Trying an edit first

A profile transaction with `{ dryRun = true }` runs the body, reactions, bundles and guards, then throws the draft away. Nothing commits and no listener runs. Guards report every violation instead of stopping at the first one that rejects, and they don't fire `guardBroken`, kick anyone, or count the transaction toward a rate limit. The result's `dryRun` holds the paths that would change and the violations, in `findings`. Shared stores don't take dry runs, since one would still cost a write request.

Development tools reach the same thing through the Studio bridge's `apply` request with `dryRun`, which needs the profile open on that server.

## Who made the change

Each transaction has a source: `system` for game code, `player` with a user id for client intent, `reaction` and `bundle` for facet writes, `mailbox`, `migration` and `plugin`. Rate guards skip reaction, bundle and plugin writes by default, so a level up reward or an edit from a Studio tool doesn't use up a player's coin limit, but every other guard still judges them. `skipSources` changes that per guard, and `ops` limits a guard to transactions that ran certain ops.
