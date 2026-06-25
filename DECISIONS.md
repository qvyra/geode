# Decisions

The design decisions behind Geode, roughly in the order they were made, and why each one went the way it did.

## 1. MemoryStore is not a write-back cache for profiles

**Date:** 2026-06-06

Writing profiles to MemoryStore first and flushing them to DataStore later was tempting: fewer DataStore requests and faster saves. I decided against it. MemoryStore items have a much smaller size cap than DataStore keys, the quota is shared across the whole experience, and nothing there is durable, so a profile that only lived in MemoryStore could simply be lost.

DataStore stays the only durable store for profiles. MemoryStore is used for the handoff key between servers and for ephemeral data.

**Commits:** none

## 2. The session lease lives in the DataStore record

**Date:** 2026-06-06

**Context:** Profiles are session locked, so only one server writes a player's data at a time. Every server needs to be able to read the lease.

**Options:**

- A lease in MemoryStore, separate from the data
- A lease inside the DataStore record, next to the data

**Chosen:** the record. The lease sits in the record's `meta`, and acquire, renew and release all happen inside the same `UpdateAsync` transform that reads and writes the data, so the ownership check and the write can't drift apart. A MemoryStore lease would mean a second system that has to agree with DataStore, and it could expire or be evicted on its own.

**Commits:** none

## 3. No automatic truncation when data hits the size limit

**Date:** 2026-06-06

DataStore values have a size limit, and data that grows past it can't be saved. Trimming old or large fields to make the save go through would be silent data loss that the player only notices when something is gone. So the write is rejected with a precise error and the data is left as it is.

To catch it early, each store has a soft size budget that warns and a hard budget that rejects. Developers should see the warning long before any player hits the wall.

**Commits:** none

## 4. Strict Luau core, hand-written typings

**Date:** 2026-06-06

Geode has to work for Luau and roblox-ts users alike. Writing the core in TypeScript and compiling it with roblox-ts would tie it to the roblox-ts runtime library and lose the Luau type information, which hurts the Luau users who make up most of the audience.

So the core is strict Luau and roblox-ts users get hand-written `.d.ts` typings. More upkeep, but both groups get something that feels native.

**Commits:** none

## 5. One transaction pipeline for every write

**Date:** 2026-06-06

Guards, reactions, replication, history and telemetry all need to see every change to a store. Letting each feature hook into writes on its own would leave the ordering between features undefined and would let some writes skip guards.

Went with a single pipeline. Game code, reactions, the plugin, the mailbox and migrations all write through it. Each write becomes one commit record with a diff, and every feature reads from that record.

**Commits:** none

## 6. Adapters return results instead of throwing

**Date:** 2026-06-25

Any Roblox service call can fail, and the scheduler and stores need to know why before deciding whether to retry. Throwing would mean wrapping every call in pcall at the call site, so adapters return a result instead: `{ ok = true, value }` or `{ ok = false, error = { kind, code?, message } }`.

DataStore errors are classified by numeric code and MemoryStore errors by their wording. Unknown codes map to `unknown`, so nothing gets retried on a guess.

**Commits:** eea78d0

## 7. Time goes through a clock adapter

**Date:** 2026-06-25

Leases, TTLs, backoff and rate windows all depend on time, and tests that wait in real time are slow and flaky. So all time goes through a `Clock` adapter instead of the task library and wall time. Its mock only moves when a test tells it to, which makes time heavy tests run instantly and the same way every run. It's built on plain coroutines, so it works in both Lune and Roblox.

**Commits:** 5ee585a

## 8. Real adapters are tested against fake Roblox objects

**Date:** 2026-06-25

Real adapters can't run in Lune, and a Studio test place can't run in CI. Left alone, their wrapping code (argument order, pcall, key info conversion, paging) would only ever be checked by hand.

Rather than test them only in Studio, I inject the Roblox globals they need. Enum values and option instances come in through a `RobloxApi` record, tests build fake service objects backed by the mocks, and the same contract suites run on both the mocks and the real adapters. The real services still need a check in Studio, noted as a TODO.

**Commits:** b85446a, f6bd436

## 9. Request scheduling with aging and budget checks

**Date:** 2026-06-25

Under load, every DataStore request competes for the same per-server budget. A release on shutdown matters more than a background read, so firing requests as they come and relying on retries when throttled isn't good enough. A strict priority queue has the opposite problem: a steady stream of urgent work starves everything below it.

Went with a priority queue where waiting requests gain priority over time, one class every ten seconds by default. Before starting a request, the scheduler checks the budget it draws from and waits instead of firing into a throttle. Only throttled and internal errors are retried, with full jitter backoff.

The scheduler is event driven. It reacts to submits and completions and sets one timer for the next moment a blocked request could start. There is no polling loop.

**Commits:** 5142ce4, 968ce27
