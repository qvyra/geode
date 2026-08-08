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

## 10. Codecs are chosen by the schema, not tagged in the data

**Date:** 2026-07-13

Datatypes like Vector3 and CFrame can't be stored as they are. They become plain values on save and turn back on load. One way is to tag each value, like `{ __type = "Vector3", x, y, z }`, and decode anything tagged. I store the bare form, `{ x, y, z }`, and let the schema say which codec applies.

That keeps stored data small, which matters against the DataStore size limit, and a tag can't be spoofed or collide with real data. The cost is that data saved without a schema can't hold datatypes at all. The storable check reports that instead of letting JSON mangle them. Each codec has a version so its stored form can change later through a migration.

**Commits:** 71c9b19, 5704530

## 11. State is an immutable tree with structural sharing

**Date:** 2026-07-13

**Context:** Reads have to return values nobody can mutate. Every write needs an exact diff for guards, replication and history. A failed transaction has to leave no trace.

**Options:**

- Mutable state, deep copied on every read and snapshotted before every transaction
- Proxy tables that record writes
- An immutable tree where a write clones only the path it touches

**Chosen:** the immutable tree. Reads hand out the frozen tree directly, with no copy. A transaction is just a draft root, so rolling back means dropping it. Diffs walk the old and new roots and skip every subtree they share, so their cost follows the size of the change. Proxies were out because tables behind proxies break `#`, `ipairs` and `table.*` for callers.

**Commits:** 69d8bba, 3fb1eea

## 12. Guards run last and resolve to one action

**Date:** 2026-07-26

Several guards can object to the same transaction with different actions, and some reactions write on behalf of a change a player already made. The alternative to what I picked was running guards per op, as each op lands.

Went with running them once, on the final diff, as the last stage of the pipeline after bundles and reactions. A guard then sees what would really be written, and a rejection rolls back reaction writes too.

Every violation is reported and the strongest action wins: kick, then reject, then flag, then warn. A custom action that returns nothing rejects, so a broken handler fails closed. Rate guards count only committed changes, so a rejected attempt never uses up a player's budget. Reaction and bundle writes skip rate guards by default but still face every other kind.

**Commits:** 5b75df1, 70ac40d

## 13. Reactions declare what they write

**Date:** 2026-07-26

Reaction cycles should be caught when reactions are defined, not when they loop in a live server. A dependency graph for that needs to know what each reaction reads and also what it writes, so declaring dependencies alone and detecting loops at runtime with a depth limit wasn't enough.

`Geode.react(deps, run, { writes = { ... } })` refuses to build without writes. Cycles, including loops through a bundle, fail when the facet set is created, and reactions run in a fixed topological order. A reaction or bundle that writes outside its declaration fails the transaction, which keeps the up front check honest. The depth limit stays as a backstop for long chains through bundles.

Bundle and reaction writes are labeled with their writer. Rate guards skip them by default while every other guard still sees them, so a level up reward doesn't use up the player's coin rate limit but still can't push coins past a range guard.

**Commits:** 5d7e925, 1582005

## 14. Lease timings and what a failed release does

**Date:** 2026-08-08

**Context:** The session lease needs default timings, a policy for leases another server holds, and a rule for what happens when the last save before release fails.

**Options:**

- Release the lease anyway, so the next server isn't blocked
- Keep the lease and the data, and try again

**Chosen:** keep both. Dropping the lease after a failed save would hand the next server stale data and lose the player's changes. A failed release puts the profile back to active with its data, and the next release or autosave tries again. The profile goes read only before its final snapshot, so nothing written during a release can slip away unsaved.

Defaults: an autosave every 60 seconds, a lease that goes stale after 300 seconds without renewal (about five missed autosaves), and a steal after 15 seconds of retrying a live holder. The default session lost policy kicks the player. In Studio, data stays in memory unless the store asks for a separate scope or live data. Loads keep retrying throttled requests for up to 30 seconds before giving up.

**Commits:** f7ad3a2

## 15. Receipts, mail and erasure ride on the profile save

**Date:** 2026-08-08

Purchases must never be granted twice, mail for an offline player has to apply exactly once, and an erased player's data must not come back from a server that still held it. The choice was between tracking all of that in separate keys written on their own, or keeping it in the profile record's metadata and saving it in the same write as the data. I went with the same write.

A purchase grant and its receipt, or an applied message and the mailbox cursor, change together in memory with no yield in between, so a save carries both or neither. If a server dies before saving, the grant or message is lost along with the data it changed and simply gets applied again. PurchaseGranted is only returned after the save succeeded.

Erasure leaves an erased marker in the record instead of deleting the key. A server still holding the profile then fails its lease check on the next save and loses the session, rather than writing the data back.

Migrations run on the stored form before decoding, since old data may not match the current schema, and reconcile only adds what the template has and the data lacks.

**Commits:** abb8145, 4d98f43, d713d56, 891d2ef
