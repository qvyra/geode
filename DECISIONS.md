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
