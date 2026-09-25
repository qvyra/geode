# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/). Before 1.0 the API may still break between minor versions.

## [Unreleased]

### Added

- Adapters for DataStore, OrderedDataStore, MemoryStore hash maps, sorted maps and queues, MessagingService, TeleportService, players, purchases and remote events, with in-memory mocks, virtual time and fault injection
- A request scheduler with priorities, aging, the modern request budgets, per key throughput limits and coalesced reads
- Schemas, codecs for Roblox datatypes, validation with full paths and size budgets
- The transaction pipeline with built-in and custom ops, frozen reads, commit records and listeners
- Guards for type, range, delta, rate, value rate, relations and custom rules, with warn, flag, reject, kick and custom actions
- Bundles, reactions and derived fields
- Session locked profiles with autosave, steal policies, Studio modes, migrations, receipts, a mailbox and erasure
- Fast server hops through release requests and a MemoryStore handoff key
- `Geode.players` and `Geode.setup` for player data with the lifecycle handled
- Shared stores written through the pipeline inside UpdateAsync
- MemoryStore wrappers and the Presence, Mutex, Counter, RateLimiter and JobQueue premades
- A matchmaker with an elected matcher, and all-time and windowed leaderboards
- Replication with per path visibility, the client atoms, a Charm adapter and rate limited remote ops
- Version history, rollback through the holder, an audit log, a registry of running modules and a telemetry bus
- Typings for roblox-ts, an example place and a Studio place for checks against live services
