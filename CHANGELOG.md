# Changelog

All notable changes to Geode are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Before 1.0 the public API may still change between minor versions.

## [Unreleased]

## [0.7.0] - 2026-11-23

A last write as each session ends, one Studio setting for every store, scopes on boards, erasure that reaches every kind of store, typed paths for roblox-ts, pruning of keys the template dropped, and leaderstats.

**Breaking, in Studio only:** every store now defaults to `mock` when neither it nor `Geode.setup` sets a mode. Shared stores, boards, the MemoryStore helpers, premades and matchmakers used to default to `real`, so a playtest no longer reads or writes their live data unless the game sets `studio = "real"` or `"scope"`. `Geode.setup({ studio })` now reaches every store made after it, not just `Geode.players`: profile stores, shared stores, boards, the MemoryStore helpers and matchmakers follow its mode unless they pass their own `studio`. In the `scope` mode, MemoryStore names and messaging topics now get a `studio_` prefix as well, so a playtest never talks to live servers. Live servers behave as before.

### Added

- `beforeRelease` on profile stores and `Geode.players`: one system transaction just before the final save, on every release while the session is still this server's. It hears why: `leave`, `shutdown`, `handoff`, `release` or `destroy`. It must not yield, it goes through the pipeline and guards, and an error or a rejection is reported while the release goes on. It never runs once the session is lost, and edits and rollbacks from development tools skip it
- `profile:release(reason)` and `store:releaseAll(reason)` take the reason the hook hears. `store:destroy()` releases every profile, stops listening for handoffs and refuses later loads with the load error `destroyed`
- `studio = "auto"`: in Studio, one read decides. With API access the stores use `scope`, without it, or in a place that was never published, `mock`. A read that fails some other way picks `mock` and is reported. On live servers it does nothing
- Every store takes `studio`: shared stores, boards, the MemoryStore helpers, premades and matchmakers, as profile stores did. The bridge's `profiles` answer names the mode in use, never `auto`
- `scope` on `Geode.Ranked` boards, with `board.scope`, and `Geode.setup({ scope })` as the default for profile stores, shared stores and boards that aren't given one
- `board:remove(userId)` takes a player off a board: an all-time board, or the current window and every window still kept
- `sharedStore:delete(key)`, and `keyForUser` on shared stores so `Geode.erase` reaches the key of each player
- `Geode.erase(userId)` erases the player on every profile store, every board and every shared store with `keyForUser`, and lists each one in its report's `stores`. Failures carry the store's `kind`
- Typed paths in the typings. Give `Geode.players`, `Geode.Profile.store` or `Geode.Client.start` the data's type and every path and value is checked against it: list paths only, reads frozen and typed by the path, `increment` only on numbers, `append` and `insert` only on lists. Without a type, everything stays as loose as before
- `prune = { version, keep, dryRun }` on profile stores and `Geode.players`: keys the template no longer has are removed on load, after reconciling, as one system transaction. They're archived first in a `<name>_pruned` DataStore, and when that write fails nothing is removed. Lists, empty template tables and kept paths are left alone. `version` goes up with every template change, and a server never prunes a record that a newer template wrote, nor lowers its version, so rolling deploys are safe. Two templates under one version stop pruning at that version on every server, reported on every load it holds back, until the version is raised. Studio on live data only ever does a dry run. Each load that prunes sends `pruned` telemetry, and the bridge's `hello` lists `prune`
- `leaderstats = { { path, name, order, format } }` on `Geode.players`: an IntValue, NumberValue or StringValue per stat in each player's `leaderstats` folder, picked from the template's value, kept in step through `observe` and removed when the profile is released. A player who leaves while their data loads never gets any. The game's own objects are never destroyed or replaced: a value it made under a stat's name is used when the class matches, and otherwise that stat is skipped. Both are reported once. Values only go from the data to the player list, so what the game writes to them is never saved
- Services have an optional `leaderstats` adapter. Mock servers have one, and `server.playerList` reads back what it shows. Its `attach` lists the stats it left out in `skipped` and the game's values it writes to in `adopted`
- Record meta gains `templateVersion` and `templateShape`, written only by stores that prune. The shape is `clash` once two templates wrote the same version. `meta.format` stays `1`

### Changed

- The `mock` Studio mode keeps one in-memory server per services table, on the real clock, shared by every store. Before, each profile store made its own
- `store:erase` and `Geode.erase` also remove the profile's prune archive, one more request per erase
- A shared store that holds a copy of a key whose stored value is gone reads it again past the DataStore cache, so a delete on another server whose message never arrived doesn't leave old data behind
- Docs: values written as a session ends, where Studio keeps data, board scopes, erasure across stores and what Roblox keeps after it, deleting shared keys, typed paths in roblox-ts, pruning and the meta it leaves, and leaderstats

### Fixed

- `replicate` on `Geode.players` reaches players who were already on the server when it was called and whose data loaded without waiting, as in-memory Studio data does

## [0.6.2] - 2026-11-19

Kicked players read a sentence meant for them, the typings fit roblox-ts games better, and the docs say what they left out. Nothing breaks.

### Changed

- The `kick` guard action kicks with "You were removed because of a problem with your data. Please rejoin." instead of the violation's `reason`, which is written for logs and shows paths and values. `kickMessage` on a profile store, a shared store or `Geode.players` sets the text for every guard, and `kickMessage` in a guard's options sets it for that guard alone. The message is the kicking guard's: before, it was the transaction's first violation, even when that guard had only flagged. `guardBroken` and telemetry still get the `reason` as it was
- `tx:op` called with a built-in op's name, such as `tx:op("set", ...)`, now says that built-ins are methods (`tx:set`, `tx:increment` and the rest) instead of "no op named set is registered". The error kind is still `unknownOp`
- Typings: a `template` can be any object type, so data declared as an `interface` fits. `Geode.receipts` returns the decision type it's given, `Enum.ProductPurchaseDecision` by default, so it can be assigned to `MarketplaceService.ProcessReceipt`, and its `decisions` have a type of their own, `Geode.Decisions`. `Testing.universe({ clock })` takes any clock, and `universe.clock` keeps the type of the one given
- The typings are checked with TypeScript 5.5.3, the version roblox-ts uses, as well as the current one
- Docs: how `guard.subset` reads a map or a list, what an action function gets and when `guardBroken` fires, that guard state lives in memory per load, the order of a release another server asks for, that `onLoaded` also calls back for profiles loaded earlier, that a digit segment in a string path is a list index, how receipts read their handlers and decisions, and where leaderboards keep their scores

## [0.6.1] - 2026-10-31

Custom ops can say what their arguments are called and what they do, so development tools can show a readable form for them. Nothing else changes.

### Added

- Custom ops can name their arguments and say what they do: `Geode.op(name, handler, { args = { ... }, names = { "item", "coins" }, description = "Give the player an item and some coins" })`. Neither changes how the op runs. The bridge's `ops` answer uses the names instead of `arg1`, `arg2` and adds the description, so development tools can show a readable form. `names` needs `args` and may name fewer arguments than it declares

## [0.6.0] - 2026-10-24

Faster loads and server hops, Geode on npm for roblox-ts, and what tools need to edit Geode's records safely and find Geode wherever it's installed.

**Breaking:** mail is now opt in. A game that sends mail with `store:mail` has to make that store with `mailbox = true`, or those calls fail. Mail already queued is kept and applies once the store opts in.

### Added

- Geode is on npm for roblox-ts as `@rbxts/geode`, with the Luau source and the typings. Install it with `npm i @rbxts/geode`
- The typings name every type through the namespace (`Geode.Profile`, `Geode.TxResult` and the rest) and now cover the service adapters, mock servers and their test controls, `Scheduler.stats` and the pipeline stage methods
- Profile and shared records carry `meta.format`, the layout of the stored record. Geode writes `1`. Records without it were written by 0.4.0 to 0.5.0 and keep loading; their next write adds it. `Geode.Raw.recordFormat` holds the current value
- `Geode.Raw.externalWrite(stored, data, { now, id })` for tools that edit a stored record directly in its DataStore key. It returns the record with the new data, `meta.revision` one higher, `meta.lastSession` set to an `external:` session and a new `meta.updatedAt`, and leaves the rest of `meta` alone. That way a server whose release already landed can't take the profile back and save over the edit, and shared store caches pick it up
- Geode's main module carries the `Geode` tag and a `GeodeVersion` attribute, so tools find it wherever it's installed. Both come from `src/init.meta.json`, so Rojo builds, Wally and npm installs and the model file all have them
- `lune run model` builds Geode alone as `Geode.rbxm`, the model file for releases, and checks the tag and attribute are in it
- Docs pages on the stored record format and the rule for external writes, and a comparison with ProfileStore, ProfileService, Lapis and DataStore2, with benchmarks run on live Roblox servers

### Changed

- **Breaking:** mail is opt in. A profile store reads its mailbox on load only when it's made with `mailbox = true`, so stores that never get mail save a GetAsync on every load. `store:mail` on a store without it fails instead of queuing mail nobody reads. Games that send mail need to add `mailbox = true` wherever the store is made; mail already queued stays in the mailbox and applies once they do
- A store that takes mail reads the mailbox while it takes the lease instead of after, so a load waits for one round trip instead of two
- Server hops are faster. When the old server announces its release, the new one reads the record once past the DataStore cache before trying to take the lease. Live hops used to spend about 4 seconds on retries that kept seeing the released lease as held, and now take about 0.6 s
- A profile that loses its session because a tool edited it after its release says so in the reason

## [0.5.0] - 2026-10-18

Development tools can now edit data through the Studio bridge, safely, and see more of what happens while a game runs.

### Added

#### Studio bridge

- Tools can edit profiles during a playtest with the bridge's `apply` request. Every edit is one op run through the normal transaction pipeline with a `plugin` source and a required note, so guards judge it and it lands in the commit record and the audit log
- An edit to a profile held by another server is sent to that server, which applies it once even if the message arrives twice. When no answer comes back in time the result is `unknown` with the last saved revision, so a tool can look before trying again
- `ops` lists the ops a tool may call with their arguments, and `schemaAt` describes the schema at a path, so tools can build edit forms
- `apply` with `dryRun = true` runs the edit and every guard on a copy and keeps nothing. It answers with the paths that would change, every guard that would complain, and whether the edit would go through
- `hello` lists the bridge's features, and the bridge folder carries a protocol range (`BridgeMinVersion` to `BridgeVersion`), so tools use what a game offers instead of guessing from version numbers
- The `profiles` answer says where each store keeps its Studio data: `mock`, `scope` or `real`
- `guardBroken` telemetry carries the whole violation: guard kind, path, source, player, the ops that ran, and the value before and after (left out above 1 KB, with its size). Shared stores send it too
- `profileCommitted` telemetry for every profile commit: revision, source, player, note, ops and changed paths. It's only built while something listens

#### Writes

- `transact` takes `dryRun = true`. Everything runs on a draft that's thrown away: no commit, no listeners, no `guardBroken`, and rate guards don't count it. Guards report every violation instead of stopping at the first rejection
- Custom ops can declare their arguments with schemas: `Geode.op(name, handler, { args = { ... } })`. Every call is checked before the handler runs, whoever made it, and a mismatch fails with `invalidArgs`
- A guard's rejection names the guard in `error.guard`, next to the message

#### Docs

- New pages: installation, getting started, how it works, developer products, troubleshooting, and a mapping for anyone coming from ProfileStore, ProfileService or Lapis

### Changed

- A Studio playtest on live data (`studio = "real"`) never steals a lease and never asks a live server to release a profile. With the default steal policy the load fails at `stealAfter` and says why, and with `stealPolicy = "wait"` it waits for the live server to let go. Nobody has confirmed that Studio's messages can't reach live servers, and a release request could kick a player
- Rate guards don't count edits from development tools, so fixing a profile doesn't use up the player's limits
- A shorter README that points to the docs site

### Fixed

- A tool edit refused by a guard still releases the profile it loaded to make the edit

## [0.4.0] - 2026-10-16

The first public release.

### Added

#### Player data

- `Geode.players` and `Geode.setup`: player data with the whole lifecycle handled. Data loads when a player joins, autosaves, and is saved and released when they leave or the server shuts down
- Session locked profiles and profile stores under `Geode.Profile`, for full control over keys, scopes and leases
- Profiles hand over between servers when a player moves, instead of waiting for the old lease to expire
- Migrations and reconciliation against a template when stored data loads
- Exactly once purchase receipts, mail delivered on a profile's next load, and erasure of a player's data on request

#### Writes and data safety

- One transaction pipeline for every write, with ops, commit records and the source of each change
- Schemas with datatype codecs, validation and encoding, plus soft and hard size budgets
- Guards that check every transaction before it commits, including writes from clients
- Bundles, reactions and derived fields that stay consistent with the data they depend on
- History, rollback and an audit log of who changed what

#### Shared and cross-server data

- Shared stores for data any server can write, through the same pipeline as profiles
- MemoryStore wrappers and premades for presence, locks, counters, rate limits and job queues
- A matchmaker with one elected matcher per queue
- All-time and windowed leaderboards

#### Clients

- Replication of chosen paths to their owner or to everyone, read on the client as atoms
- Client intent through declared, guarded ops, so clients never write state directly

#### Services and testing

- One adapter layer over DataStore, MemoryStore, MessagingService, players and remotes, with a request scheduler that spends the documented budgets
- `Geode.Testing`: in-memory services with fault injection and a virtual clock, matched to what the live services did in testing, so whole games run in Lune without Roblox
- Live checks that run the same contract tests against real Roblox services

#### Tooling and docs

- A Studio bridge for development tools. In a Studio playtest, `ServerStorage.GeodeVein` answers read only requests about what is running and forwards telemetry. `Geode.setup({ studioBridge = false })` keeps it shut
- `Geode.version`, shared with the bridge so tools can tell which Geode a game runs
- Hand-written typings for the whole API in `types/`, ahead of a roblox-ts package
- An API reference generated from the doc comments, and guides for every part of Geode

[Unreleased]: https://github.com/qvyra/geode/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/qvyra/geode/releases/tag/v0.7.0
[0.6.2]: https://github.com/qvyra/geode/releases/tag/v0.6.2
[0.6.1]: https://github.com/qvyra/geode/releases/tag/v0.6.1
[0.6.0]: https://github.com/qvyra/geode/releases/tag/v0.6.0
[0.5.0]: https://github.com/qvyra/geode/releases/tag/v0.5.0
[0.4.0]: https://github.com/qvyra/geode/releases/tag/v0.4.0
