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

## 27. Typings build on the roblox-ts type packages

**Date:** 2026-09-29

The hand-written typings need Roblox types like Player and Enum, and Luau functions that return several values need roblox-ts's LuaTuple, which the compiler only recognizes from its own package. A local LuaTuple would compile but break destructuring in real roblox-ts projects, and structural stand-ins for the Roblox types would drift from the real ones.

So the typings depend on @rbxts/types and @rbxts/compiler-types, pinned to exact versions as development dependencies. The check suite compiles the typings without the default library, the way roblox-ts does, and skips checking the libraries themselves, which don't build cleanly against the newest TypeScript. A usage file that never runs is compiled alongside, so a typing change that breaks ordinary code fails the check.

**Commits:** 5dd2ede

## 28. Review follow-ups that change behavior

**Date:** 2026-09-29

A review of the new stores, replication and tooling turned up places where the code did something other than what its design promised. For each one the question was whether to patch the symptom where it showed up or change the rules so the whole class of problem couldn't happen. Where a rule was missing, the rule changed:

- A visibility map that puts a stricter path under a more open one is refused when the store is made, since a shared path always sends everything under it
- Release requests and handoff keys name the session they're about, so a late message can't affect a newer session of the same key
- A rollback sent to the holding server waits for an answer and reports failure when none comes
- A release in the beginner layer retries until it lands, since giving up left the profile open and locked the player out of that server

The rest, in the shared store, the client, the premades and the matchmaker, were plain bug fixes with tests.

**Commits:** c881919, 8d062bc, 01120ae, bf18b5f, 311b4e6, e8c875b, 0c4c4e6

## 29. Live testing settled the undocumented behavior

**Date:** 2026-10-05

**Revises:** entries 8 and 26

Wherever Roblox's documentation was silent, the mocks had a guess, each marked for a check against live services. Entry 8 also left the real services to a Studio check that hadn't run yet. The guesses could have stayed until a bug report proved one wrong.

Went with running the checks and the adapter contract suites against live services and matching the mocks to what happened:

- A sorted map bound holding only a key now sits where that key with no sort key would
- RemoveAsync with an old read id does nothing
- The JSON encoder writes DEL raw, like HttpService
- An unknown version id counts as not found instead of a retryable internal error
- A key keeps one version per UTC hour, so the history and rollback from entry 26 move in hourly steps and a later write in the same hour replaces the version before it
- UpdateAsync clears metadata a transform leaves out, which the adapter already carries forward

Every answer has a contract test that runs against both the mocks and live services. The last live run passed all 32 checks with 8 observations recorded, and nothing contradicted an earlier decision.

**Commits:** 3369f40, 1886f30, af6da69

## 30. Live checks run headlessly through Open Cloud

**Date:** 2026-10-05

The live checks needed Studio, a Rojo connection and someone pressing Run, which meant they would only ever run by hand. They now go through Open Cloud Luau Execution against a dedicated test place, both locally and in CI.

`lune run live` builds the check place and uploads it as a saved version, so the published game never changes. Each group of checks runs as its own execution task, since a task stops after five minutes. Execution tasks reach DataStore, MemoryStore and MessagingService, so every check runs there except the teleport contract, which is reported as observed. The runner fails on any failed check, failed task or timeout.

In CI it runs on pull requests from the repository and on demand, never on pull requests from forks, with read-only repository access and the key in a secret.

**Commits:** 7b06ab1, e5ad2ce, a3d448a

## 31. Studio tools read the game through a bridge in ServerStorage

**Date:** 2026-10-15

**Context:** Studio development tools, such as an inspector plugin, need to see what Geode is doing in a playtest. A plugin runs in its own VM, so requiring the game's Geode would give it a fresh, empty copy, and reaching into internals would break the rule that tools only use public surfaces.

**Options:** have the plugin require Geode's modules and read their state, or have Geode expose a versioned, read only bridge that the plugin finds in the DataModel.

**Chosen:** the bridge. The first store made in a Studio playtest creates `ServerStorage.GeodeVein`, through a Quartz adapter like every other Roblox service, with a Request BindableFunction and a Telemetry BindableEvent. Its folder carries the bridge and Geode versions, so a tool can tell when either side is too old before reading anything.

A Bindable copies tables and mangles mixed or sparse ones, so profile answers send the stored form with the path of each codec value, and the tool decodes them for display. Nothing outside Studio ever creates the bridge, and `Geode.setup({ studioBridge = false })` keeps it shut.

**Commits:** 6a44bdb, ddb804b

## 32. Studio on live data never steals a lease or asks for a release

**Date:** 2026-10-16

A playtest with `studio = "real"` loads the same keys live servers hold. When a key is held, a normal load asks the holder over MessagingService to release, and steals the lease once `stealAfter` runs out. Roblox's docs say MemoryStore data is isolated between Studio and production, but they say nothing about MessagingService, and nobody has tested it. If Studio messages do reach live servers, a playtest could make one release a player's profile and kick them.

Until that's settled, a profile store in Studio on live data never sends a release request and never steals. With the default steal policy the load fails at `stealAfter` and says why. With `stealPolicy = "wait"` it waits until the live server lets go on its own. `"scope"` mode keeps working as before: its records live in their own scope, and a live holder only releases on a request that names its own session.

**PR:** #6

## 33. guardBroken telemetry carries the whole violation, values capped

**Date:** 2026-10-16

Tools showing guard events need to know who broke what and how. The message used to carry only store, key, guard, action and reason. Now it adds the guard kind, path, source, player, the ops that ran, and the value at the path before and after the transaction. Shared stores publish it too, with the key that was being written.

The values are captured while the guard runs, because a rejected draft is gone by the time listeners hear about it. In the message they go out in stored form, so codec values survive a Bindable, and anything over 1 KB encoded is left out with only its size. A value that breaks its schema is sent as it is, since encoding it could produce garbage. None of this is built unless something listens to the bus, so games without tooling pay nothing extra.

**PR:** #8

## 34. Tools pick features from hello, not from version numbers

**Date:** 2026-10-16

The bridge is going to grow: writes, schema lookups, more telemetry. If tools compared version numbers to guess what a game supports, every new request would need a version bump and every tool a table of which version added what. Instead `hello` lists the bridge's features (`read`, `telemetry`, `guards`, more as they land), and a tool shows whatever the game offers.

A protocol range stays, but only for what a feature list can't express: a change to a request or answer that old tools would misread. The folder carries `BridgeVersion` and `BridgeMinVersion`, and a tool can send its own protocol with `hello` to be turned away with a reason that says which side to update.

**PR:** #9

## 35. Tools edit profiles only through the pipeline, with a note

**Date:** 2026-10-16

Entry 31 kept the bridge read only for its first version. Editing data from Studio is the next step, and the risk is a tool that writes around the rules the game relies on.

So every edit is an op run through the normal transaction pipeline with a `plugin` source, and it needs a note saying why, which lands in the commit record and the audit log. Guards still judge it. Rate guards are the one exception, since a developer fixing a profile shouldn't use up the player's limits. A profile open on this server is edited there. One open on another server gets the edit sent to its holder, which runs it and answers, the same way rollbacks work. Nobody holding it means this server takes the lease, edits and releases, and the release runs even when a guard refuses the edit.

Messages can arrive twice or not at all, so each edit sent to a holder carries an id. The holder remembers the ids it applied and answers a repeat with its first answer instead of applying it again. A sender that hears nothing within the timeout can't tell a lost edit from a lost answer, so it reports `unknown` with the last saved revision rather than a failure, and the tool can look before trying again.

Values cross the bridge in stored form and are decoded with the schema where the op runs, so codec values survive the Bindable and the messaging hop. The `ops` request describes the built-in ops' arguments. Custom ops are listed without arguments, because they don't declare them yet. Studio on live data still never messages a live holder (entry 32), so in a playtest an edit to a profile held by a live server is refused. The bridge only exists in a running playtest, so nothing can edit from edit mode.

**PR:** #10

## 36. Custom ops declare their arguments with schemas

**Date:** 2026-10-16

Custom ops took whatever they were given. Remote ops already checked a client's arguments against schemas (entry 25), but the same op called from game code, mail or a development tool got no check at all, and tools couldn't tell what to ask for or decode codec values that crossed in stored form.

`Geode.op(name, handler, { args = { schemas } })` takes one schema per argument, the same shape remote ops use. The transaction checks a call against them before the handler runs, whoever made it, and a mismatch fails with `invalidArgs` so nothing in the transaction lands. Fewer arguments are fine when the missing ones are optional. Tools list each argument with its schema described and decode stored values with it. Ops registered without `args` behave as before, so this adds nothing to existing games.

The alternative was named arguments, a map from name to schema. Positional lists match how ops are called and how remote ops already declare them. Names for tool forms can come later as an option next to `args`.

**PR:** #14

## 37. A dry run reports every guard and leaves no trace

**Date:** 2026-10-17

Tools want to know what the guards would say before an edit lands. `transact` takes `dryRun = true`: the body and every stage run on a draft, then the draft is thrown away. No commit, no listeners, no deferred callbacks. In a dry run guards collect every violation instead of stopping at the first rejection, and they check against a copy of their state, so a rate guard never counts a dry run and the real edit afterwards sees the same limits. Nothing fires `guardBroken`, nobody is kicked.

The bridge's `apply` takes `dryRun` and answers with the paths that would change, each violation as plain data, and `wouldCommit`, false when any violation rejects or kicks. It needs no note, since nothing changes, and only works on a profile open on that server. Running it on a profile held elsewhere would mean a round trip through the holder for an answer that may be stale by the time it arrives, and loading a free profile would take its lease just to look. Tools list it as the `dryRun` feature.

Shared stores refuse dry runs. Their transactions run inside UpdateAsync, so a dry run would still spend a write request to learn nothing a write result can carry.

**PR:** #17

## 38. Commits go out as telemetry only while someone listens

**Date:** 2026-10-17

A change log needs to know who changed what, and when, as it happens. The audit log already summarizes each commit, but it's written in batches after a save and only when a store keeps one. Every profile commit now also publishes `profileCommitted` on the Bus: store, key, revision, source, player, note, the ops that ran and the changed paths. It reuses the audit log's summary, so the two never disagree.

Building the summary costs a walk over the diff on every commit, so it runs only while `Bus.listening()` is true. With nothing subscribed, a commit does no extra work. In a Studio playtest the bridge subscribes as soon as it opens, so tools always get it there. The bridge lists the message as the `commits` feature, and the Bus version stays at 1 since it's a new message type, not a changed one.

Values aren't in the message. Before and after values can be big, and a change log can ask for the profile when it needs them. Shared stores don't publish it yet, since nothing reads their commits.

**PR:** #18

## 39. Tools that write records directly follow one rule

**Date:** 2026-10-19

Tools are starting to edit Geode records straight in their DataStore keys, with no Geode running. Two parts of Geode trip over a write like that. A server whose release reported failure takes the profile back on its next save when the lease is gone and `meta.lastSession` still names its own session at the current revision (entry 18), so an edit that left `lastSession` and the revision alone would be saved over. And shared store caches only take values at the same or a newer revision, and drop a cached value only for a message naming a newer one.

So an external write raises `meta.revision` by one, sets `meta.lastSession` to `{ session = "external:" .. id, revision = <new revision> }` with an id fresh for every write, updates `meta.updatedAt`, and leaves everything else in `meta` alone. Geode's own sessions are GUIDs, so the prefix never matches one, and the reclaim check needed no change: both the session and the revision differ from what the server left. Servers already running 0.5.0 behave the same way. `Geode.Raw.externalWrite` applies the rule, so tools and tests share one definition, and a profile that loses its session to such an edit says so in the reason.

The other options were clearing `lastSession`, the way erasure does, or a new field such as `meta.editedBy` for the reclaim check to read. Clearing works but forgets who wrote last. A new field would be ignored by older servers, which would still reclaim.

The lease stays untouched on purpose. A tool can't keep a lease alive the way a server does, so a server that still holds one saves over any external edit. Tools edit only records with no lease and go through the holder otherwise (entry 35).

Records also carry `meta.format`, `1` from 0.6.0, so tools can tell layouts apart without guessing from which fields are there. Missing means 0.4.0 to 0.5.0, and those records keep loading. An external write doesn't set it, since the tool didn't change the layout. Older servers keep the field on profiles, since they copy `meta`, but drop it when they write a shared record, so during an update a shared record can lose it until a newer server writes it again.

**PR:** #21

## 40. Mail is opt in, and its read runs next to the lease

**Date:** 2026-10-20

Every profile load read the store's mailbox with a GetAsync after taking the lease, so a load cost two round trips one after the other, even in games that never send mail. Nothing in a store's options says whether it gets mail: any store can be mailed a built-in op, and custom ops listed in `ops` are just as callable from game code.

So a store says it with `mailbox = true`. Without it a load never touches the mailbox, and `store:mail` fails instead of queuing mail nothing would read. Mail already queued is left alone and applies once the option is on. The other choice was keeping mail on by default with `mailbox = false` to opt out, which would keep the extra request for nearly every game.

A store with the option starts the mailbox read on its own thread next to each acquire attempt, and applies the mail once the lease is taken, before `load` returns, as before. Reading before the lease is ours changes nothing about exactly once: the cursor in the record the acquire returns decides what applies, and pruning only drops messages at or before that saved cursor. A read that saw less than the latest mailbox only leaves mail for the next load, which a cached GetAsync could already do. A read from an attempt that found the lease held is redone with the next attempt, so mail sent while a hop waits still lands.

**PR:** #23

## 41. A hop reads the record past the cache after the release announcement

**Date:** 2026-10-20

Live benchmark hops took about 5 s although the old server released within half a second. The new server's tries were at 0, 0.5, 2.5 and 4.6 s. The second and third answered in under 10 ms with the lease still held, and only the fourth, about 4 s after the first, reached the backend and got the profile. Those tries are UpdateAsync calls. Roblox documents a 4 second cache for GetAsync only, and says SetAsync and UpdateAsync write into it, so the documented cache doesn't explain it. The timings fit this server's cached copy of the key being handed to a transform that then writes nothing, so nothing goes to the backend to correct it. That part isn't documented.

After a release announcement (the message, or the handoff key showing the release) the load now reads the record once with `DataStoreGetOptions.UseCache = false`, which the docs say always asks the backend. If the lease is free there, the UpdateAsync follows at once; if it's still held, the load keeps waiting without spending an UpdateAsync. The UpdateAsync still decides, so nothing about correctness rests on the read. The docs say a GetAsync that reaches the backend refreshes the cache, which is what lets the UpdateAsync after it see the release. The benchmarks bear that out: in all sixteen hops measured with this change the UpdateAsync right after the uncached read took the lease, and a hop went from about 5.1 s (5.02 to 5.17 s on the same day) to about 0.6 s (0.50 to 0.75 s). Both halves, the stale UpdateAsync and the refresh, are observed rather than documented.

The adapter's `get` takes `{ useCache = false }`, and the mock can keep a per server copy of keys (`dataStoreCache`) so tests can reproduce the slow hop. Waiting longer before retrying was the other idea, but that only moves the 4 seconds around.

**PR:** #23

## 42. The npm package ships the Luau source with its Rojo project

**Date:** 2026-10-21

roblox-ts games get packages from npm, under `node_modules/@rbxts`, which their Rojo project puts in ReplicatedStorage. roblox-ts maps an import to a Luau file through the package's `main` and `types`, and works out the instance path from the Rojo tree. So `@rbxts/geode` ships the same `src` as Wally, with `main` at `src/init.luau` and `types` at `types/index.d.ts`, and no build step of its own.

`default.project.json` ships too. With it, Rojo builds the package folder as one ModuleScript named `Geode`, the same as a Wally install, and roblox-ts resolves imports to that name. Without it the folder would be a Folder holding a `src` ModuleScript, which also works but differs from every other install. Both layouts were built with roblox-ts 3.0.0 and Rojo 7.7.1 before choosing.

`package.json` drops `"type": "module"`. With it, TypeScript treats `types/index.d.ts` as an ES module under Node16 resolution and refuses its `export =`; the ESLint config moved to `.mjs` instead. The typings also moved into a `Geode` namespace merged with the value, so roblox-ts code can name `Geode.Profile` and the rest, the way Luau code names the exported types.

The npm and Wally packages share one version number and are bumped in the same release PR.

**PR:** #24

## 43. The main module carries a tag and its version, for tools to find

**Date:** 2026-10-24

Geode will also ship as a model file, attached to GitHub releases and on the Creator Store, so it can end up in any folder under any name, not only where Wally or Rojo put it. The Studio bridge already works from anywhere, since it lives in its own folder in ServerStorage. What didn't was a tool looking for Geode itself while no bridge exists yet, to say that a game has Geode but hasn't made a store, or that its Geode predates the bridge. Guessing folder names breaks as soon as someone drops the model somewhere else.

So the main module carries the `Geode` tag and a `GeodeVersion` attribute holding `Geode.version`. A tool calls `CollectionService:GetTagged("Geode")` and reads the attribute. Both come from `src/init.meta.json`, the one place every install path shares: Rojo reads it when building the project, Wally and npm ship `src` with it, and the model file is a Rojo build. Setting them at run time instead would only work once something required Geode, which is exactly what a tool can't count on.

The version now sits in four files, so a test keeps the attribute, `wally.toml` and `package.json` equal to `Version.luau`, and `lune run model` builds the release model file and reads it back to check the tag, the attribute and the bridge are really in it. The check suite runs it, so every PR proves the model still builds. Geodes from before the tag have neither; tools need another way to spot those, such as their module layout.

**PR:** #25

## 44. Ops name their arguments in a list next to args

**Date:** 2026-10-31

Tools showed a custom op's arguments as `arg1`, `arg2`, since a schema says what a value may be but not what it means. `Geode.op` now takes `names`, one string per argument by index, and `description`, a line saying what the op does. Both are only for tools: the handler, the argument checks and replication don't look at them.

The names sit in their own list rather than on the schemas. A schema is a value that can be shared, so one schema may check arguments of several ops, and a name on it would either show up in every use or need a copy per argument. A separate list also leaves `args` exactly as it was. The cost is that the two lists have to line up, so registration checks it: `names` needs `args`, can't be longer, and holds only non-empty strings. It may be shorter, and the arguments past it keep their numbered names, so an op can name the ones that need it.

`Transaction.opInfo` hands both to tools, and the bridge's `ops` answer uses the names in each argument's `name` and adds `description` to custom ops. That only adds fields to an answer old tools already read field by field, so the protocol stays at 1, as the bridge's rule asks (entry 34). No feature flag either: a tool sees whether a description is there, and a name it gets is the one to show either way.

**PR:** #28

## 45. Bench runs are kept in the repo and published as data

**Date:** 2026-10-31

The numbers on the benchmarks page came from workflow artifacts, which GitHub deletes after 90 days, so nobody could check them later, not even against the page. Every run now lives in `benchmarks/runs`, cleaned of the ids that point at the test place or a server. `benchmarks/catalog.json` says what was measured and how: suites, scenarios, metrics, the Geode builds and the libraries. `lune run benchdata build` turns both into the files the docs site serves under `data/benchmarks` (a `latest.json`, an index, one file per run and the JSON Schema they follow) and writes the tables on the page between markers. The check suite fails when any of them doesn't match the runs, so the page can't drift from its data.

A run names the Geode it measured by the git tree of `src` and the bench by the tree of `tests/bench`, plus a link to its workflow run. Commit ids don't work for that: the bench often runs on a pull request's merge commit, which isn't kept, and a rebase merge gives every commit a new id anyway. A tree id stays the same for the same files.

Results from before and after a change in behavior never mix. Builds belong to lines, and a subject keeps to the runs of its line. All current subjects take the same runs, the last five in which the current Geode ran, so every row of a table compares the same conditions. Geode before the mailbox change stays on the page as a historical subject with its own runs.

Each suite records its timing resolution. Bench times are wall clock seconds read at frame steps, and 95% of the samples so far are multiples of 1/60 s, so differences under that are ties. Memory per loaded profile is read from the Lua heap in every run, but a suite can be marked `recordedOnly`: its results stay in the run files and stay out of `latest.json` and the page. Memory is, since garbage collection moves it either way by more than the profiles take; two runs gave Geode -0.5 and 4.0 KB and flipped the order of the libraries. Edit time is measured for Geode alone, in Lune; the other libraries' edits do different work (a plain table change or a `:Update` call), so the catalog lists that comparison as not measured rather than putting the numbers side by side.

Runs on a release tag, by hand or once a month open a pull request with their data, using the workflow's own token. Pushes with that token start no workflows, and dispatching CI on the branch didn't help either: GitHub doesn't count a dispatched run's checks for a pull request. What it does is hold the pull request's own CI run until a maintainer approves it, which is one click per data pull request. A personal token or a GitHub App would avoid the click, but each needs a secret to set up and look after, for a pull request a person reviews anyway.

Tables keep a notes column written by hand, matched to rows by label. The prose around them stays hand written too, so when new runs change a number the prose quotes, the data pull request lists it for a person to rewrite.

**PR:** #34

## 46. A kicked player reads a kick message, not the violation's reason

**Date:** 2026-11-17

The `kick` guard action kicked with the first violation's `reason`. Reasons are written for logs: "coins rose by 1000000, more than 1000 at once" shows a path and values, tells a cheater exactly where the limit sits, and reads oddly to everyone else. It also took the transaction's first violation, which isn't always the kicking one: a guard that only flagged, listed before the one that kicked, gave its reason.

A kick now reads, in this order: the kicking guard's `kickMessage`, the store's `kickMessage`, or "You were removed because of a problem with your data. Please rejoin." When several guards kick in one transaction, the first of them in the store's list gives the message. The violation's `reason` stays as it was, so `guardBroken` and telemetry don't change. Both options are checked when the guard or store is made, so an empty message fails at game start, not on the first kick.

Rejected: `kickMessage` as a function of the violation. It would let the text depend on what happened, but brings back the risk of showing log details, and adds a callback inside the deferred stage. A game that wants that already can: an action function returns "reject" and the game kicks with its own text. Also rejected: keeping the reason as the default and making the plain text opt in, since the default is where the leak was. `Geode.setup` doesn't take a kick message either. Its defaults are services and modes, and the text belongs next to the guards it's for.

**PR:** #39

## 47. A template is typed `object` until the typings take generics

**Date:** 2026-11-18

`template` was `Record<string, unknown>`. That type has a string index signature, and TypeScript only gives an implicit one to object literal types, never to an interface, so a roblox-ts game that declared its data as an `interface` couldn't pass it. The fix had to keep every existing call compiling, since the generic typings come later and will change these options again.

`object` does that: it takes interfaces, type literals and `Record`s alike. It also takes arrays and functions. Both stores already assert at run time that the template is a table, so a function still fails as soon as the store is made, and nothing the old type refused gets further than before. Rejected: `Record<string, any>`, which has the same index signature problem; a generic `template: T` now, which is the larger change planned for the typed paths and would land twice; and loosening only `Geode.players`, which would leave the same problem on profile and shared stores.

**PR:** #39

## 48. `Geode.receipts` returns the decision type it was given

**Date:** 2026-11-18

The callback returned `unknown`, so `MarketplaceService.ProcessReceipt = Geode.receipts(...)` didn't compile: ProcessReceipt wants an `Enum.ProductPurchaseDecision`. The callback now returns `D`, the type of the `decisions` passed in, and `D` defaults to `Enum.ProductPurchaseDecision`, which is what the Luau code returns when no decisions are given. Tests that pass strings get strings back. `Decisions<D>` is a named type now, and `PlayerDataOptions.decisions` takes `Decisions<unknown>`, since Geode sets ProcessReceipt itself there and nothing reads the type back.

The callback's argument is Geode's `ReceiptInfo` or Roblox's own, so it's assignable to ProcessReceipt (which hands Roblox's) while tests keep calling it with a plain table. Rejected: returning `Enum.ProductPurchaseDecision` always, which is wrong for tests and mock decisions, and dropping Geode's `ReceiptInfo` for Roblox's, which would make every test spell out fields like `CurrencySpent`.

**PR:** #39

## 49. A test universe keeps the type of the clock it was given

**Date:** 2026-11-18

`Testing.universe({ clock })` asked for a `MockClock`, but the mock servers only call what every clock has: `now`, `wait`, `spawn`, `delay` and `resume`. A test checked it by running a profile hop on a clock that follows real time. So the option takes any `Clock`, and `Universe<C>` keeps the clock's type in `universe.clock`, defaulting to `MockClock`. Existing code still gets `advance` and `run` on it, and a universe on another clock doesn't claim methods its clock lacks.

Rejected: typing `universe.clock` as a plain `Clock`, which would break every test that advances it, and overloads for the two cases, which say the same as the generic with more lines. The Luau option type stays `MockClock` for now: Luau can't make a class's field follow a constructor argument the way the TypeScript generic does, and widening it would cost every Luau test a cast on `universe.clock`. Passing another clock works in Luau at run time with a cast.

**PR:** #39

## 50. The typings compile with TypeScript 5.5.3 in the check suite

**Date:** 2026-11-18

roblox-ts pins TypeScript 5.5.3, so that's the compiler every roblox-ts game runs the typings through, while the repo's own `tsc` is the current release. A typing only the newer compiler accepts would pass CI and break games. The check suite now runs `tsc` twice over the typings and `typings-test`: once with the current version, once with 5.5.3 from an npm alias, `typescript-5.5`.

Rejected: pinning the repo's only TypeScript to 5.5.3, which would hold ESLint's TypeScript tooling back and miss errors the newer compiler finds; and `npx typescript@5.5.3` in the check, which downloads on every run and isn't locked by `package-lock.json`. When roblox-ts moves its pin, the alias moves with it.

**PR:** #39

## 51. `tx:op` names the method when it gets a built-in

**Date:** 2026-11-18

`tx:op("set", ...)` failed with "no op named set is registered", which reads as if `set` were missing rather than called the wrong way. Built-ins are methods on the transaction (`tx:set`, `tx:increment` and the rest) and never go through `tx:op`, so the error now says so and shows the call to make. The kind stays `unknownOp`, so code that matches on the kind behaves as before; only the message changed. Rejected: running the built-in from `tx:op`, which would give built-ins two spellings, and records and guards would see a custom op call where a built-in ran.

**PR:** #39

## 52. `beforeRelease` writes one transaction before every release

**Date:** 2026-11-20

Games write values as a session ends: the logout time, the last spawn, playtime not counted yet. Before this they had to wrap the leave, kick and BindToClose services so their write landed before Geode's release. A profile store, and so `Geode.players`, now takes `beforeRelease(tx, profile, reason)`. It runs as one system transaction just before the final save, while the profile can still be written, and the reason is one of `leave`, `shutdown`, `handoff` (another server asked for the profile), `release` (game code called `profile:release()`) and `destroy`. The arguments put `tx` first like migrations and receipt handlers, then the profile and the reason in the order the request named them.

- It runs from `Profile.release`, so every path goes through it, and the paths pass their reason in: `Geode.players` on leave, `releaseAll` on shutdown, the release another server asks for, `destroy`. The handoff path runs it before the kick, so the player is still in the game while it runs.
- It runs once per profile. A release whose save failed and is tried again doesn't write the same values twice. It never runs once the session is lost, since the profile can't be written then.
- It must not yield: a shutdown gives every release `closeTimeout` seconds, and a hook waiting on something would use them up. Profile transactions had no yield check; only shared store writes did. The hook runs in its own coroutine inside the transaction, and a yield closes that coroutine and fails the transaction, so the rest never runs later. Reactions and guards inside a profile transaction are still unchecked, as before.
- It goes through the pipeline like any write, so reactions, bundles and guards judge it. A yield, an error or a rejection is reported through `reportError`, and the release goes on with the data as it was. Nothing it does can keep a release from happening.
- The short loads a development tool makes to edit or roll back a profile nobody holds skip it: those aren't play sessions, and the game's closing values would land in a support edit.

Profile stores had no `destroy`, so `destroy()` is new: it releases every profile with the reason `destroy`, stops listening on the handoff topic and makes later loads fail with the new load error kind `destroyed`. `PlayerData:destroy()` keeps doing only what it did, stopping joins and leaves.

Rejected: a hook that only gets the profile and writes through it, which would be a transaction per write and could leave half the values written; letting it yield with a time limit, which would hold BindToClose for slow code; running it again on every retry; and one hook per reason, when a single function with the reason covers each case with an `if`.

**PR:** #40

## 53. One Studio setting for every store, with `auto`

**Date:** 2026-11-21

Only profile stores had a Studio mode, and `Geode.setup({ studio })` reached `Geode.players` stores only. A game that wanted Studio kept apart had to build its own services table for shared stores, boards, the MemoryStore helpers and matchmakers. Now the mode lives in one module, `Quartz/Studio`, and every store asks it: `Geode.setup`'s mode, unless the store passes its own `studio`. Lower layers can't read Polish, so `Geode.setup` hands the mode to Quartz instead of each store reading Polish defaults. `Geode.setup`'s services, scheduler and error reporting still reach `Geode.players` stores only.

- **Defaults.** Profile stores stay at `mock`. Every other store stays at `real`, which is what it did before, so nothing changes in Studio until a game sets a mode. Changing them all to `mock` would quietly move existing games' shared stores and boards into memory. Entry 59 changed this before release.
- **`mock`.** DataStore, MemoryStore and messaging come from one in-memory server per services table, on the real clock, shared by every store. Before, each profile store made its own. Players, purchases, shutdown, teleports, remotes and the bridge stay live; the mock budget stays too, since those requests never reach Roblox. Before, the clock-only copy kept the mock's remotes, teleports, JSON and ids.
- **`scope`.** DataStore data goes under `studio_` plus the scope, as before, and now MemoryStore names and messaging topics get a `studio_` prefix too. Profile stores in this mode used to send release requests on the live topic and read the live handoff map. Studio data never matches live data, so a Studio session has nothing to say to live servers, and now it can't.
- **`auto`.** In Studio, the first store reads one key (`probe` in `geode_studio_access`) once per services table, and stores made meanwhile wait for the answer. Success means `scope`. `noAccess`, the 403 Studio gets without API access, means `mock`. A place that was never published (place id 0) means `mock` without a request. Any other error also means `mock` and is reported, so a check that went wrong keeps data in memory instead of reaching live data. With access, it picks `scope`, not `real`, so turning access on never points a playtest at live data by itself. On live servers it does nothing. The read yields, in Studio only. Tested in Studio: without access, a GetAsync fails with a 502 whose message says "Studio access to APIs is not allowed" (error code 7), not the 403 Roblox's error table lists for writes. That 502 counts as `noAccess`, so it isn't retried either.
- **What the bridge reports.** The `profiles` answer's `studio` field names the mode in use, `mock`, `scope` or `real`, never `auto`. No answer changed shape.
- Services a Studio mode built pass through untouched, so a matchmaker's own mutex shares the matchmaker's memory server instead of getting a second one.

Rejected: services that pick their adapters on first use, which would keep store constructors from yielding but would also stall the first request of every store behind the check; checking with a write, which costs more and would leave a key behind; and a mode per kind of store in `Geode.setup`, when a store's own `studio` option already covers the exceptions.

**PR:** #40

## 54. Boards take a scope, and `Geode.setup` sets one for every store

**Date:** 2026-11-21

Profile and shared stores took a `scope`, but `Geode.Ranked` boards didn't, so a test universe or a new season could keep its saved data apart everywhere except on its boards. Boards now take `scope`, and `Geode.setup({ scope })` is the default for profile stores, shared stores and boards that aren't given one. Without either, every store stays in `global`, as before.

- An all-time board passes the scope to its OrderedDataStore, which has scopes of its own.
- A windowed board's MemoryStore sorted maps have no scope, so it goes into the map name: `geode_rank<length>_<scope>_<name>_<window number>`. The length in front keeps every pair of board name and scope apart: joined with plain underscores, the board `2_Daily` in scope `s` and the board `Daily` in scope `s_2` would share a map. `global` keeps the old names, `geode_rank_<name>_<window number>`, so existing windows keep their scores through the update.
- In Studio's `scope` mode the board's DataStore scope gets the `studio_` prefix like every other store, and its map names get it from the services.
- The MemoryStore helpers and matchmakers take no scope. Nothing they hold outlives a session, so no saved data mixes.

Rejected: a separate name option, which would ask every game to spell the scope into each board by hand; escaping underscores in names, which changes the names of existing windowed boards; and `liveUniverses` with a list of live universes in `Geode.setup`, which wasn't asked for here. A game that wants it passes its own scope from the universe id.

**PR:** #40

## 55. Erasure reaches boards and opted-in shared stores

**Date:** 2026-11-22

`Geode.erase` reached profile stores only. Boards had no way to remove a player and shared stores had no delete, so a game answering an erasure request removed board keys and shared keys by hand through raw adapters.

- `board:remove(userId)` runs RemoveAsync on the all-time board's key, the user id as a string. A windowed board removes the player from the current window and from every earlier window that can still hold items: the ones whose close plus the grace is still ahead, which is when `submit` sets their items to expire. Cached top lists are dropped either way.
- `sharedStore:delete(key)` runs RemoveAsync, puts this server's cached copy back to the template so observers hear it, and broadcasts on the invalidation topic without a revision. A key written after a delete starts over at revision 1, which is below what other servers hold, and a message without a revision already makes them drop any copy.
- That made a gap visible. A server that missed the message would read nothing where it held revision 7, take it for a stale read and keep serving the deleted value. When a read finds nothing where this server held a value, it now reads once more past Roblox's cache and believes that answer, and a server's own write is believed as well, so a lower revision after a delete gets in. Those are the only cases where a lower revision replaces a higher one.
- Shared stores opt in with `keyForUser(userId) -> key?`. Geode can't know which keys belong to a player, and a guild key holding many players must not be deleted for one of them, so a store without it is left alone. Returning nil means the store holds nothing for that player. An error from it is a failure for that store.
- The report keeps `erased` and `failures` as they were, each failure now with its `kind`, and adds `stores` with one entry per store that held something: name, kind (`profile`, `shared` or `board`), whether it worked and the message. A failing store doesn't stop the others.
- Boards register for erasure when made and stay registered after `destroy`, like profile stores, since their saved scores outlive the object.

The `TODO(verify)` in `Sapphire/Registry.luau` asked whether versions older than 30 days stop being readable and whether they can be dropped sooner. Roblox's versioning page says "Versioned backups expire 30 days after a new write overwrites them. The latest version never expires", and the DataStore reference marks RemoveVersionAsync deprecated without naming a replacement. That answers both from the docs: they expire, and there's no supported way to drop them sooner. The comment and the docs now quote that instead of guessing.

Rejected: a `remove(key)` name for shared stores, which already have `remove(key, path)` for a path inside a value; deleting by writing the template, which keeps the key and its revision but isn't the RemoveAsync an erasure asks for; and erasing every shared store by default with the user id as the key, which would delete whatever happens to sit under a number.

**PR:** #40

## 56. Typed paths for stores, profiles, transactions and the client

**Date:** 2026-11-22

Paths were `string | (string | number)[]` and every read was `unknown`, so a roblox-ts game built its own typed wrappers over each read, op and transaction. The typings now take the data's type: `Geode.players<T>`, `Geode.Profile.store<T>`, `ProfileStore<T>`, `Profile<T>`, `PlayerData<T>`, `PlayerProfile<T>`, `Transaction<T>` and `Geode.Client.start<T>`. With a type, `get`, `observe`, the ops and `transact` check the path against `T` and take or return the type at that path. Typings only, no Luau change.

- **Opt-in, so existing code compiles unchanged.** `T` defaults to `object`, which keeps the loose `Path` and `unknown` everywhere. `template` is `NoInfer<T>`, so a template alone never turns typing on: inferring `T` from it would have made every existing string path a type error.
- **List form only.** A typed store takes paths as lists, ported from the kit's `PathOf`, `ValueAt` and `PathTo` but on tuples instead of dotted strings. A record keyed by string takes a `string` segment, and a list item takes a 1-based `number` index, since Geode addresses list items by index where the kit ended paths at lists. Lists sidestep the digit rule that makes `"friends.1001"` an index.
- **Missing values.** A record's entry or a list's item may not be there, so reading one, or anything under it, includes `undefined`. Optional fields keep theirs. A client atom also reads `undefined` until the data arrives and for paths the server doesn't send.
- **Reads are frozen.** `get` and `observe` hand out `Frozen<V>`, readonly all the way down, matching the frozen tables Geode returns. Writes take the plain type.
- **Ops only take paths that fit.** `increment` and `decrement` take paths to numbers, `append` and `insert` paths to lists with items of the list's type, `merge` a partial of the table at the path.
- **Depth.** Spelling out every path is a union that grows with the template, so it stops at eight segments, the kit's six plus room for list indices. Past that any tail is accepted, and `ValueAt` still works out the exact type, so a deep path still checks its value. `typings-test/paths.ts` covers a ten-level template and a 64-key one with nested records, and TypeScript 5.5.3 checks it in about half a second.
- `products` handlers on `Geode.players<T>` get `Transaction<T>`. Migrations stay untyped, since they run on older shapes of the data, and so do guards and facets.

Rejected: typed dotted strings with template literal types, which the request ruled out and which can't tell a digit key from an index; keeping loose overloads next to the typed ones, which would let a typo through as `unknown`; and a separate family of typed interfaces, which would double every name in the typings.

**PR:** #40

## 57. Pruning keys the template dropped

**Date:** 2026-11-23

Reconciling only adds, so a key a game stops using stays in every profile until a migration removes it. `prune` on a profile store, and so on `Geode.players`, removes those keys on load.

- **Opt-in, and archived first.** Nothing leaves the record before it's added to the profile's key in a `<name>_pruned` DataStore, so the rule that Geode never drops user data on its own still holds: the game asks for it and the values stay recoverable. When the archive write fails, nothing is removed and the next load tries again. The archive key carries the profile's user ids, and erasing a profile removes it on every profile store, whether or not it prunes now, since it may have before. That's one more RemoveAsync per erase.
- **What counts.** Only tables the template spells out with string keys. Lists, empty template tables like `inventory = {}`, keys that aren't strings and anything under a value that isn't a table are containers the template doesn't describe, so what's in them stays. Kept paths stay with everything under them. Lists are left alone for the same reason Reconcile leaves them alone.
- **One system transaction after reconciling**, with the note `prune`, so guards can reject it and the audit log, listeners and telemetry see it. A guard that rejects it leaves the archive entry behind, which is harmless.
- **The rolling-deploy guard needs a version from the game.** `prune.version` is required, a whole number that goes up with every template change. The request named only `keep` and `dryRun`; the version was added because nothing in a template says which of two templates is newer. Every write from a pruning store leaves `meta.templateVersion` and `meta.templateShape`, a 32-bit FNV-1a hash of the template's fields and the kept paths, unless the record already holds a higher version. A server prunes a record only when its stored version is missing or not higher than its own, and at an equal version only when the shapes agree. The shape catches a deploy that forgot to raise the version: both sides hold back and the store reports it once. Entry 60 closes a gap in this. Records stay at `meta.format = 1`, since these are two optional meta fields that older Geode copies along untouched.
- **Studio on live data only reports.** With `studio = "real"` in Studio, pruning is always a dry run and leaves no mark, so a template still being worked on can neither drop live keys nor push the version past the live servers'.
- **Read only.** A profile that's already read only when its load finishes, because its session went during the load, isn't pruned. Data that fails the schema or a migration fails the load before this point.
- **Telemetry.** A `pruned` message for every load that removes or would remove keys, with `store`, `key`, `paths`, `version` and `dryRun`, and a `prune` feature in the bridge's `hello`. No answer changes shape.

Rejected: taking the version from `schemaVersion`, which would make every template change a schema bump and turn a rolling deploy into `newerData` load failures on the old servers; a hash alone, which can't tell an older template from a newer one; keeping the template's full path list in meta, which grows every record; keeping the archive inside the record, which keeps the size pruning is meant to free; and pruning inside lists by matching items against the template's first item, which is a guess.

**PR:** #40

## 58. Leaderstats on Geode.players

**Date:** 2026-11-23

Most games copy a few values into the player list by hand: make the folder once the data loads, update it on every change, clean up when the player leaves. `leaderstats = { { path, name, order?, format? } }` on `Geode.players` does that.

- **A new adapter.** Making Instances in Polish would break the rule that only Quartz touches Roblox, so the values come through `services.leaderstats`. The live one makes the Folder and its value children, and the mock one, read back through `server.playerList`, is what the tests check. It's optional on `Services`, so services built by hand still type check, and `Geode.players` refuses the option without it.
- **The template picks the kind.** A whole number makes an IntValue, any other number a NumberValue and a string a StringValue, and `format` makes a StringValue. Anything else, a path the template doesn't have included, fails in `Geode.players`, so a typo shows when the game starts. The kind never changes afterwards: a value that doesn't fit shows 0 or empty text and is reported once per stat, and a fraction on an IntValue stat is rounded down and reported, instead of swapping the Instance for another class.
- **When they exist.** They're made on `loaded`, which PlayerData only fires for a player still on the server, and only for a profile that is still active, so a player who leaves while their data loads never gets any. They follow the data through `observe` and go on `released`, which also fires when a session is lost. A folder the game already made is used as it is, and only Geode's values are taken out of it.
- **Order.** Stats with an `order` come first, lowest first, then the rest as listed, and their values are parented in that order. Roblox doesn't document how the player list orders its columns, so the real adapter has a `TODO(verify)` for a Studio check.
- **Server only.** The folder is made on the server and reaches clients the way any Instance under the player does.

Rejected: picking the kind from each value as it changes, which would replace Instances under the player list; a separate `Geode.leaderstats(PlayerData, ...)` call, which needs the same hooks and is one more name to learn; and typing `format` by the path's value, which a list of stats with different paths can't infer in TypeScript.

**PR:** #40

## 59. Every store defaults to `mock` in Studio

**Date:** 2026-11-23

Entry 53 kept shared stores, boards, the MemoryStore helpers and matchmakers at `real` in Studio, so nothing moved for existing games. That left a playtest writing live guild banks, board scores and MemoryStore keys unless the game set a mode. Now a store with no `studio` of its own, and none from `Geode.setup`, uses `mock` like profile stores, so a playtest reaches live data only when the game asks for it.

- **One default, in one place.** `Quartz/Studio` holds it, and every store asks it for its mode: its own, else `Geode.setup`'s, else `mock`.
- **Live servers don't change.** Outside Studio every mode uses the services the store was given.
- **Breaking, in Studio only.** A game whose playtests relied on shared stores or boards reading live data now gets an empty in-memory copy. `studio = "real"` on the store, or `Geode.setup({ studio = "real" })`, brings back what it did before. The 0.7.0 breaking note says so.
- No bridge, record or meta changes.

Rejected: keeping `real` as the default for everything but profile stores, which entry 53 chose so nothing moved, since a playtest that writes live data by default is the worse surprise; and `auto` as the default, which sends a DataStore read from every Studio session and moves a playtest onto real services as soon as API access is on.

**PR:** #40

## 60. A prune mark only moves up, and a clash holds every server back

**Date:** 2026-11-23

- **Older servers can't lower the version.** Every write marks the meta it read in the same UpdateAsync, not the copy its session loaded, and leaves it alone when it holds a higher version. So a server on version 4 that loads a profile a version 5 server saved, changes it and saves it leaves version 5 and its shape in place, and the next load on version 5 prunes as before. A test runs that sequence.
- **A clash sticks.** Entry 57 said a deploy that forgot to raise the version holds both sides back. It only did while loads alternated: each server wrote its own shape, so its next load saw that shape and pruned what the other template added. Now a write that finds another shape under its own version leaves `clash`, which no template hashes to, so every server at that version holds back until one with a higher version saves the record. That write replaces both fields like any other, so one clash can't turn pruning off for good, and a test prunes again after it.
- **Reported on every load it holds back**, with the keys it kept, instead of once per store, so a clash that lasts keeps showing up in the logs. A clash that holds back nothing is reported too, since the next template change would be held back the same way.
- **A version written by hand stays.** The verdict already left such a record alone, and marking now leaves the value alone too.
- `meta.format` stays `1`: `clash` is a new value of an optional field.

Rejected: keeping the first shape, which lets the old servers go on pruning keys the new template added; keeping the latest, as before; and keeping every shape in meta, which grows with each template that clashes.

**PR:** #40

## 61. Leaderstats never destroy or replace what the game made

**Date:** 2026-11-23

- **Another class under a stat's name.** When the folder already holds something by a stat's name, of another class than the stat needs, that stat isn't shown, the store reports it once and the game's object stays as it is. The adapter lists those stats in `skipped`, an optional field, so adapters built by hand still fit.
- **The same class.** A value of the class the stat needs is written to and left in place on release, so a game that already made `Coins` ends up with one `Coins`, not two. The store reports it once per stat, since Geode now writes to an object it didn't make. The adapter lists those stats in `adopted`.
- **One way.** Geode writes the value on every change to the data and never reads it back. A change the game's own code makes to it is never saved, and the next change to the data overwrites it. The docs say so.
- **Releases remove only Geode's values.** A folder Geode made is destroyed only when nothing else is in it, so values the game put there later stay.

Rejected: replacing the game's value with one of the right class; adding Geode's value under the same name next to it, which the player list would show twice; and skipping a value of the same class too, which leaves the stat showing a number nothing updates.

**PR:** #40
