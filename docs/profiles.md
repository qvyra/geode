---
sidebar_position: 8
---

# Profiles and the beginner layer

A profile is one player's data, held by one server at a time under a session lease (a session lock). The beginner layer, `Geode.players`, loads and releases profiles for you. The profile store underneath is there when you need more control.

## Player data with Geode.players

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local PlayerData = Geode.players({
	name = "PlayerData",
	template = { coins = 0, level = 1, inventory = {} },
	products = {
		[1234567] = function(tx)
			tx:increment("coins", 500)
		end,
	},
})

PlayerData:onLoaded(function(player, profile)
	print(player.Name, "has", profile:get("coins"), "coins")
end)

PlayerData:onReleased(function(player)
	print(player.Name, "was saved and released")
end)
```

What it handles:

- A player's profile loads when they join and is released when they leave. A load that can pass on its own is retried, and a player whose data can't load is kicked with a clear message instead of playing without it
- Shutdown releases every profile, and a profile another server takes over ends its session here
- Listed developer products are granted exactly once. The grant and its receipt are saved together, and the purchase only counts as granted after that save succeeds
- In Studio, data stays in memory unless you ask for a separate scope or live data

`onLoaded` also calls back for every profile that loaded before you connected, each in its own thread, so connecting late misses no one.

### Leaderstats

`leaderstats` puts values in each player's `leaderstats` folder, the one Roblox's player list reads, and keeps them in step with the data:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local PlayerData = Geode.players({
	name = "PlayerData",
	template = { coins = 0, stats = { kills = 0 }, rank = "Rookie" },
	leaderstats = {
		{ path = "coins", name = "Coins", order = 1 },
		{ path = "stats.kills", name = "Kills", order = 2 },
		{
			path = "rank",
			name = "Rank",
			format = function(rank)
				return string.upper(rank)
			end,
		},
	},
})
```

- The template's value at the path picks the kind: a whole number makes an IntValue, any other number a NumberValue and a string a StringValue. A stat with `format` is a StringValue showing what `format` returns, which is how a table or a boolean gets shown. Anything else fails when the game starts.
- The values are made once the player's data has loaded, and change with every commit through `observe`. They're removed when the profile is released, whether the player left, the server shut down or the session was lost. A player who leaves while their data loads never gets any.
- Stats with an `order` come first, lowest first, then the rest in the order listed.
- Geode never destroys or replaces what the game made. A folder the game already made is used as it is, and only Geode's values are taken out of it. A value the game already put there under a stat's name is written to when it's the class the stat needs, left in place on release, and reported once. When it's another class, that stat isn't shown, the game's value is left alone and the store reports it once. A folder Geode made stays when the game has put values of its own in it.
- Leaderstats only go one way, from the data to the value. Geode writes the value on every change to the data. If the game's own code changes it, that change never reaches the saved data, and Geode overwrites it on the next change. To change a stat, change the data.
- A value a stat can't show, like a string at a number stat, shows as 0 or empty text and is reported once per stat. An IntValue stat shows a value with a fraction rounded down; give it a `format` to show fractions.
- Only the server makes them. Roblox copies the folder to clients like any other Instance under the player.

## Before the data loads

`PlayerData:get(player)` works from the moment a player joins. Until their profile loads, reads return the template and writes are refused, so UI code can draw defaults right away and check `isLoaded` to tell them from real data.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)
local Players = game:GetService("Players")

local PlayerData = Geode.players({
	name = "PlayerData",
	template = { coins = 0 },
})

for _, player in Players:GetPlayers() do
	local data = PlayerData:get(player)
	if data then
		print(data:get("coins"), data:isLoaded())
	end
	local profile = PlayerData:waitFor(player, 10)
	if profile then
		profile:increment("coins")
	end
end
```

## Shared defaults with Geode.setup

`Geode.setup` sets defaults for the stores made after it. Its Studio mode reaches every store: profile stores, shared stores, boards, the MemoryStore helpers and matchmakers. Its `scope` is the DataStore scope profile stores, shared stores and boards use when they aren't given one, so a test universe can keep its data apart with one line. The services, one shared scheduler and error reporting reach `Geode.players` stores. Call it once, before making any store. A store's own options still win.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

Geode.setup({ studio = "auto" })

local PlayerData = Geode.players({ name = "PlayerData", template = { coins = 0 } })
```

## Where Studio keeps data

The Studio mode only matters in Studio. Live servers always use the real services.

| Mode    | In Studio                                                                                                                                                            |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `mock`  | DataStores, MemoryStores and messaging come from one in-memory server shared by every store, on the real clock. Data is gone when the playtest ends                  |
| `scope` | The real services, kept apart from live servers: DataStore data goes under `studio_` plus the scope, and MemoryStore names and messaging topics start with `studio_` |
| `real`  | Live data, the same as a live server                                                                                                                                 |
| `auto`  | `scope` when Studio has API access, `mock` when it doesn't                                                                                                           |

Every store defaults to `mock`: profile stores, shared stores, boards, the MemoryStore helpers and matchmakers. A playtest only touches live data when `Geode.setup` or the store's own `studio` option asks for it. Players, purchases, shutdown, teleports, remotes and the Studio bridge stay real in every mode.

`auto` finds out by reading one key the first time a store needs to know, so that first store waits for one DataStore request, in Studio only. Stores made while it runs wait for the same answer. An error saying Studio has no API access means `mock`, and so does a place that was never published. Any other error also lands on `mock`, and Geode reports it, so a check that went wrong keeps data in memory instead of reaching live data. Development tools see the mode a store ended up with, never `auto`.

## Profile stores

`Geode.Profile.store` makes a store you load profiles from yourself, by any key. `PlayerData.store` is one of these.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local Guilds = Geode.Profile.store({
	name = "GuildData",
	template = { members = {}, bank = 0 },
	autosaveInterval = 60,
})

local result = Guilds:load("guild_42")
if result.ok then
	local profile = result.profile
	profile:increment("bank", 250)
	profile:release()
else
	warn(result.error.kind, result.error.message)
end
```

A profile's writes go through the transaction pipeline: `set`, `increment`, `decrement`, `append`, `insert`, `remove`, `clear`, `merge`, `update`, custom ops and `transact` for several at once. Reads return frozen values. `observe` calls back after each commit that changes a path.

## Values written as a session ends

`beforeRelease` runs one system transaction just before a profile's final save, so values like the logout time or the playtime not counted yet land in the same write. It runs once per profile, on every way a profile is released while its session is still this server's, and the reason says which one:

| Reason     | When                                                                      |
| ---------- | ------------------------------------------------------------------------- |
| `leave`    | the player left a `Geode.players` server                                  |
| `shutdown` | the server is closing, through `releaseAll` and BindToClose               |
| `handoff`  | another server asked for the profile. It runs before the player is kicked |
| `release`  | game code called `profile:release()`                                      |
| `destroy`  | the store's `destroy()` released it                                       |

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local PlayerData = Geode.players({
	name = "PlayerData",
	template = { lastSeen = 0, playtime = 0 },
	beforeRelease = function(tx, profile, reason)
		tx:set("lastSeen", os.time())
	end,
})
```

It goes through the same pipeline as any write, so reactions, bundles and guards see it. It has to finish without yielding: one that yields fails, since a shutdown gives every release only `closeTimeout` seconds. When it yields, errors or a guard rejects it, Geode reports it through `reportError` and releases with the data as it was. It never runs once the session is lost, because the profile can't be written then, and it stays out of the short loads a development tool makes to edit a profile nobody holds. A server that crashes runs nothing, so values that matter should also be written as the game goes.

`profile:release(reason)` and `store:releaseAll(reason)` take the reason to pass on. `store:destroy()` releases every profile with the reason `destroy`, stops listening for other servers' requests and refuses loads from then on. `PlayerData:destroy()` only stops handling joins and leaves; its profiles stay open until `PlayerData.store:destroy()`.

## Custom ops

`Geode.op` registers an op once for the whole game, and a store lists the ones it allows in `ops`. Give it `args`, one schema per argument, and every call is checked before the handler runs, whoever made it: game code, mail or a development tool. A call that doesn't match fails with `invalidArgs` and writes nothing. Tools also use the schemas to describe the op and to decode values like a `Vector3` that crossed in stored form.

`tx:op` and `profile:op` only run ops registered with `Geode.op`. Built-ins are methods, such as `tx:set` and `tx:increment`, and `tx:op("set", ...)` fails with `unknownOp`.

`names` gives the arguments names, one per schema in the same order, and `description` says in a line what the op does. They change nothing about how the op runs. Development tools show them, so an edit form reads `item` and `amount` instead of `arg1` and `arg2`. `names` needs `args` and can stop early; the rest keep their numbered names.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)
local t = Geode.t

Geode.op("guideGrantItem", function(tx, item: string, amount: number)
	tx:update({ "inventory", item }, function(current)
		return (current or 0) + amount
	end)
end, {
	args = { t.string(), t.integer({ min = 1 }) },
	names = { "item", "amount" },
	description = "Give the player some of an item",
})

local PlayerData = Geode.players({
	name = "PlayerData",
	template = { inventory = {} },
	ops = { "guideGrantItem" },
})

PlayerData:onLoaded(function(player, profile)
	profile:op("guideGrantItem", "potion", 3)
end)
```

## Schemas and migrations

A schema checks every write and converts Roblox datatypes to and from their stored form. Migrations upgrade data saved by an older schema version, oldest first, before the schema decodes it.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)
local t = Geode.t

local Profiles = Geode.Profile.store({
	name = "Profiles",
	template = { coins = 0, spawn = Vector3.new(0, 5, 0) },
	schema = t.struct({
		coins = t.integer({ min = 0 }),
		spawn = Geode.codec.Vector3,
	}),
	schemaVersion = 2,
	migrations = {
		[2] = function(tx)
			if tx:get("gold") ~= nil then
				tx:set("coins", tx:get("gold"))
				tx:remove("gold")
			end
		end,
	},
})
```

Missing template fields are filled in on load, which other libraries call reconciling. Unknown fields are never removed without a migration, unless the store prunes.

## Removing keys the template dropped

Reconciling only adds. A key the template no longer has stays in the data until a migration removes it, or until the store prunes. With `prune`, every load removes the keys the template's tables don't have any more. It runs after reconciling, as one system transaction with the note `prune`, so guards and listeners see it like any other change.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local PlayerData = Geode.players({
	name = "PlayerData",
	template = { coins = 0, inventory = {}, settings = { music = true } },
	prune = {
		version = 3,
		keep = { "legacy", { "settings", "theme" } },
	},
})
```

- Only tables the template spells out with keys are pruned. A list, an empty table like `inventory = {}` and keys that aren't strings are left alone, whatever they hold.
- `keep` lists paths that stay, with everything under them.
- Before anything goes, the removed keys and their stored values are added to the profile's key in the `<name>_pruned` DataStore, one entry per prune. If that write fails, nothing is removed and the next load tries again. `store:erase` and `Geode.erase` clear the archive with the profile.
- `version` is a whole number that goes up with every template change, `keep` included. Every write leaves it in the record's meta with a hash of the template's shape. A server never prunes a record that a server with a higher version wrote, so during a rolling deploy the older servers leave alone the keys a newer template added. An older server never lowers the version either, so its saves leave the newer mark, and the newer servers go on pruning as before. A record written under the same version by a different template isn't pruned either: the version wasn't raised. Its `meta.templateShape` becomes `clash`, and from then on no server prunes it at that version, whichever loads it. The store reports every load it holds back, with the keys it kept. Raising the version clears it: the first server with a higher version that saves the record leaves its own shape there, and pruning goes on as before.
- `dryRun = true` removes and archives nothing, and only reports what would go.
- A load whose data fails the schema or a migration fails before pruning, and a profile that is already read only is never pruned. Studio with `studio = "real"` only ever does a dry run and leaves no version in the record, so a template still being worked on can't drop live data or hold live servers back.

Every load that removes keys, or would on a dry run, sends a `pruned` telemetry message with `store`, `key`, `paths`, `version` and `dryRun`:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

Geode.Vein.subscribe(function(message)
	if message.type == "pruned" then
		print(message.key, table.concat(message.paths, ", "), message.dryRun)
	end
end)
```

## Mail

`store:mail` queues an op for a profile wherever its player is, and it applies exactly once, as a mailbox transaction:

- When the profile is open on this server, in this store or another one with the same name, it applies before `mail` returns.
- When it's open on another server, it applies there within moments. The mail is stored first, then a ping on the store's handoff topic tells the holder to read its mailbox. Both servers need `handoff`, which is on unless a store turns it off.
- Otherwise, and whenever the ping is lost, it applies the next time the profile loads.

Mail is off unless the store is made with `mailbox = true`, so a store that never gets mail never reads a mailbox. Set it everywhere the store is made, on the servers that send mail too: a store without it refuses to send. A store that has it reads the mailbox while it takes the lease, so the load doesn't wait for one more request.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local PlayerData = Geode.players({ name = "PlayerData", template = { coins = 0 }, mailbox = true })

PlayerData.store:mail(PlayerData.store:keyForUser(1001), "increment", "coins", 50)
```

The profile's mailbox cursor is what makes it exactly once. A message applies only past the cursor, and the cursor is saved in the same write as the data the message changed. A ping only says when to look: one that comes twice changes nothing, and mail that arrives while the profile is being released, or in the middle of a hop, applies once, on the server that loads it next. Mail applies in the order it was stored, so a holder that hears of new mail while earlier mail hasn't reached it reads the mailbox and applies both. Applied mail leaves the mailbox once a save has carried the cursor. Until then, a server that dies before saving leaves both the change and the cursor unsaved, and the next load applies the mail again.

## How sessions stay safe

Each profile record holds a session lease. Every save is an UpdateAsync that writes the data and renews the lease in one step, and only if the lease is still this server's. A server that finds the lease held elsewhere asks the holder to release it and waits for the release, so a player hopping servers usually waits only for the old server's final save. If the holder doesn't let go within `stealAfter` seconds, the store's `stealPolicy` decides what happens: take the lease anyway (`"steal"`, the default, sometimes called force loading), keep waiting (`"wait"`) or give up (`"fail"`). A server that stops renewing its lease loses it, and its next save refuses to write instead of overwriting newer data. [How it works](how-it-works) walks through it.

When another server asks for a profile, this one runs `beforeRelease` with the reason `handoff`, kicks the player if they're still here, with Geode's own text, "Your data was opened on another server. Please rejoin.", and then releases the profile with its final save. A store's `kickMessage` doesn't change that text; it's for guards.
