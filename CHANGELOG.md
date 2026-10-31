# Changelog

All notable changes to Geode are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Before 1.0 the public API may still change between minor versions.

## [Unreleased]

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

[Unreleased]: https://github.com/qvyra/geode/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/qvyra/geode/releases/tag/v0.6.0
[0.5.0]: https://github.com/qvyra/geode/releases/tag/v0.5.0
[0.4.0]: https://github.com/qvyra/geode/releases/tag/v0.4.0
