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

**Note, 2026-08-13:** until release requests over MessagingService exist, stealing from a live holder throws away up to one autosave interval of that server's unsaved changes, because the holder only finds out it lost the session on its next save. Release requests are what shrink that window in practice.

## 15. Receipts, mail and erasure ride on the profile save

**Date:** 2026-08-08

Purchases must never be granted twice, mail for an offline player has to apply exactly once, and an erased player's data must not come back from a server that still held it. The choice was between tracking all of that in separate keys written on their own, or keeping it in the profile record's metadata and saving it in the same write as the data. I went with the same write.

A purchase grant and its receipt, or an applied message and the mailbox cursor, change together in memory with no yield in between, so a save carries both or neither. If a server dies before saving, the grant or message is lost along with the data it changed and simply gets applied again. PurchaseGranted is only returned after the save succeeded.

Erasure leaves an erased marker in the record instead of deleting the key. A server still holding the profile then fails its lease check on the next save and loses the session, rather than writing the data back.

Migrations run on the stored form before decoding, since old data may not match the current schema, and reconcile only adds what the template has and the data lacks.

**Commits:** abb8145, 4d98f43, d713d56, 891d2ef

## 16. Errors are matched by name as well as code

**Date:** 2026-08-13

**Revises:** entry 6

Entry 6 classified DataStore errors by numeric code and everything else by wording. Going through the official error reference showed problems with that: newer throttles come back as names like `KeyThrottled` with no code, a few codes were in the wrong group, and MemoryStore and MessagingService have no documented wording at all.

Went with matching codes and throttle names for DataStore, and treating unmatched MemoryStore and MessagingService errors as retryable. Codes now follow the reference:

- 301 to 306 are throttles
- 404 and 501 to 505 are retryable internal errors
- 401 and 402 mean the server is shutting down
- 1xx, 403, 509 and 511 to 513 are never retried

Names ending in `Throttled` are throttles. An unmatched DataStore error stays unknown and is never retried, since a guess there could hammer a key that will never accept the call. MemoryStore and MessagingService errors can't be matched reliably, so an unmatched one is retried a bounded number of times.

**Commits:** 88c4b75

## 17. Budgets follow the modern request types

**Date:** 2026-08-13

**Revises:** entry 9

Entry 9 checked budgets against the legacy request types, which are deprecated, and spaced writes to one key 6 seconds apart, a rule Roblox doesn't have. Both are gone.

Budgets now use the modern types, and a call waits on every budget it draws from. UpdateAsync waits until both the read and the write budget have room, RemoveAsync draws on its own budget, and OrderedList counts as unlimited because it isn't metered and always reports 0.

Writes are no longer spaced by default. The scheduler tracks each key's reads and writes over a rolling 60 seconds against 25 MB and 4 MB, rounds every request up to the next kilobyte the way Roblox does, and holds a request until it fits. The mocks throttle the same way when a test turns it on.

**Commits:** dfbd203, 60443f5

## 18. Retries recognize their own landed writes

**Date:** 2026-08-13

**Context:** Roblox documents that a failed UpdateAsync doesn't guarantee the write didn't happen. That bit us twice. A release that landed but reported failure left the profile active with the lease already gone, and the next save reported the session lost. A mail send that landed and was retried queued the message twice.

**Options:**

- Treat every failure as not written, and accept lost sessions and duplicates as rare
- Mark every write with the session behind it, so a retry can recognize its own earlier write

**Chosen:** mark the writes. Every profile write records `meta.lastSession = { session, revision }`. The session is a unique id generated per load, not the job id, since one server can load, release and load the same key again. A save that finds the lease gone while the last write is still ours knows its own release landed and nobody wrote since, so it takes the lease back and carries on. A retried release simply writes again, and revisions never move backwards.

The same idea covers the other paths. Mail carries an id so a landed send isn't queued twice, a load that gives up hands back a lease its acquire may have taken, and erasure clears `lastSession` so nothing reclaims an erased record. A new mock fault lets writes land and then report failure, and chaos tests cover acquire, save, autosave, release, erase, receipts and mail.

**Commits:** 9464483, 66295cc, cc76a54

## 19. Erased players start over

**Date:** 2026-08-13

Erasure leaves a marker record with no data, so when the player joins again the load has to do something with it. Refusing the load and firing an event would lock that player out of the game forever. Instead the load starts a fresh profile from the template.

The marker's `erasedAt` stays in the record, so history and rollback can refuse every version from before it while Roblox keeps old versions readable for 30 days. The load that starts over reports `erasedAt` in its result and fires `erasedProfileLoaded`.

**Commits:** 1c7c2b1

## 20. Player data is usable before it loads

**Date:** 2026-09-01

Beginners write UI code that reads player data the moment a player joins, before the profile has loaded, and something has to answer those reads. There were three ways to go: hand out nothing until the load finishes and make every caller wait, hand out a handle right away that reads the template and refuses writes, or queue early writes and apply them after the load.

The handle won. `PlayerData:get(player)` returns one for any player on the server. Reads return template values until the profile loads, and `isLoaded` tells defaults from real data. Writes before the load are refused with a not loaded error instead of being queued, because a queued write would apply to data its author never saw.

Loads that can pass on their own are retried three times before the player is kicked, and a load that finishes after the player left is released at once. `Geode.setup` only affects stores made after it and says so when called late.

**Commits:** cdbb409, 7a3a0a6, 1a6b7c9, 6acc1fd

## 21. Server hops wait for an announcement, not a poll

**Date:** 2026-09-01

A player who hops servers finds their profile still held by the server they left. With retries, backoff and then the steal window, that hop could take up to 15 seconds and, if it ended in a steal, cost the old server its unsaved changes.

Polling the MemoryStore handoff key every half second was the obvious fix, but MemoryStore reads would then scale with every waiting player. I went with announcements over MessagingService instead. The waiting server publishes one release request. The holder releases, kicks the player if they're still there, and publishes that it released, and the waiter retries the acquire as soon as it hears.

The handoff key stays as a slower fallback. Every release writes one with a 30 second lifetime, and a waiter checks it every 2 seconds until the steal window closes, so a lost message costs at most a couple of seconds. Neither path is trusted. Both only say "try now", and the lease check inside UpdateAsync still decides who holds the profile.

**Commits:** 19861e4

## 22. Shared writes run the pipeline inside the transform

**Date:** 2026-09-01

Shared stores have no lease, so any server may write a key at any moment, and guards, bundles and reactions still have to see exactly what gets written. Running the pipeline on cached data and then writing the result with UpdateAsync doesn't hold up: a guard could approve a change that breaks its rule once applied to fresher data, and the write would overwrite other servers' changes.

Went with running the whole pipeline inside the UpdateAsync transform, against the value UpdateAsync hands over. The transform builds a scratch document from the stored value and runs the full pipeline on it. UpdateAsync can run a transform more than once, so that document holds its deferred callbacks, and they run once, along with listeners, for the run that landed. Transforms must not yield, so the pipeline runs in its own coroutine and a yield fails the write with an error naming the rule.

Stored keys carry a small `meta` with a revision, so caches and invalidation messages can tell newer data from older.

**Commits:** 17f70e6, ac6d184

## 23. Premades trade precision for quota

**Date:** 2026-09-01

MemoryStore quota is shared by the whole experience and grows with server count, and each premade had a cheaper design and a more precise one. The precise options were sliding window rate limits, auto renewed locks and per call presence lookups. I took the cheaper designs and kept their tradeoffs out in the open.

RateLimiter counts in fixed windows with one atomic update per check, accepting that a burst across a window edge can reach twice the limit. Mutex locks have a lease that callers renew, and each acquire hands out a fencing token that never goes below the wall clock in milliseconds, so it keeps growing even after the stored item expires. JobQueue's nack leaves jobs to reappear after the invisibility timeout instead of re-adding them, which could duplicate them.

Every premade reports an estimated request rate and registers itself, so the cost is visible before it becomes a surprise.

**Commits:** 8275936

## 24. One elected matcher per queue

**Date:** 2026-09-16

Matchmaking reads the whole queue every tick. If every server ran a matching pass on every queue, MemoryStore reads would grow with the number of servers. So one server per mode and region is elected to match, using the Mutex premade, and every server can still add and cancel tickets. The matcher's lock has a short lease it renews each tick, so when its server dies another one takes over within a lease.

Correctness doesn't rest on the election. Every ticket is claimed with an atomic update that only lands while it's unclaimed, and a pass that loses any claim gives back the others, so two matchers that overlap during a handover still can't place a player twice.

Windowed leaderboards run every mode through the sorted map's atomic update. Only all-time sum boards use IncrementAsync on an OrderedDataStore.

**Commits:** c31a550, f77cddc

## 25. Replication sends visible paths, intent goes through remote ops

**Date:** 2026-09-16

**Context:** Clients need to see some of their own data and some of other players' data. They also need a way to ask for changes without being able to write anything themselves.

**Options:**

- Forward every commit's raw diff and let the client filter it
- Declare visibility per path on the server, send only visible values that changed, and take client intent only as declared ops

**Chosen:** declared visibility. Paths are private unless marked `owner` or `public`, so new fields never leak by default. After each commit the replicator compares each visible path with what it last sent, which is cheap because unchanged subtrees are the same frozen tables, and queues only what changed. The queue goes out once per frame, and clients get atoms over a read only copy.

Remote ops check the attempt rate limit before anything else, then each argument against its schema, then run on the asking player's own profile with a player source, so guards apply as they would to any write. The default limit is 30 attempts per 10 seconds and requests past it are dropped. Remote ops send no reply. The client sees the result through replication, which keeps a refused request from leaking why it was refused.

**Commits:** 8f100c5, a17ede5

## 26. Rollback goes through the holder, audit batches chain backwards

**Date:** 2026-09-16

Two related problems. Rolling back a profile another server holds can't be a direct write, because the holder would overwrite it on its next save. And the audit log has to be readable without listing DataStore keys, which the adapters don't support.

For rollback, the blunt option was writing the old version straight to the key and letting the holder lose its session. Instead the rollback is sent to the holder over the handoff topic. A profile nobody holds is loaded through the normal lease, changed and released, and one open on the same server is changed directly.

For the audit log it came down to one key per commit or one key per save. It's one batch per save, keyed by the batch's last revision and holding its first, so a reader starts at the current revision and steps back batch by batch. That keeps the cost at one write per save, not one per commit. History and rollback refuse every version from before `meta.erasedAt`, and erasure removes the audit batches it can reach.

**Commits:** 7dbaf39
