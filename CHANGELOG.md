# Changelog

All notable changes to Geode are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Before 1.0 the public API may still change between minor versions.

## [0.4.0] - Unreleased

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

[0.4.0]: https://github.com/qvyra/geode/releases/tag/v0.4.0
