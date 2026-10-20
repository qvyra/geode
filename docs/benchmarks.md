---
sidebar_position: 19
---

# Benchmarks

These numbers come from the bench in `tests/bench`, run against live Roblox services with the same steps for Geode, ProfileStore, ProfileService, Lapis and DataStore2. The versions are the ones listed on [Comparing libraries](comparison). Every number here is from a real run, and anything that couldn't be measured fairly says so.

## Results

Seven runs: four on 2026-10-19 (bench runs `1d449b46`, `25532752`, `3561e8c8` and `76954271`) and three on 2026-10-20, `0f6881b6` right before Geode's change to loads and hops and `1b5acb20` and `7d89ae32` with it. "Geode before" takes the first five runs and "Geode after" the last two. After the change Geode runs twice: with its defaults, and with `mailbox = true`, which reads a mailbox on every load. The other libraries didn't change, so their rows take all seven runs. Each cell is the median, then the lowest and highest value and how many samples went in. Lapis isn't in the tables, see [Not measured](#not-measured).

Runs differ more than the steps do. In `0f6881b6` ProfileStore loaded a new profile in 0.45 s (median), in `1b5acb20` a quarter of an hour later in 0.30 s. Timings are best compared within one run, and request counts don't vary at all.

### Load, save and release

Each run loads five fresh profiles, saves each, releases each after a change, loads them again and releases them again, with the steps on one key at least 8 seconds apart.

| Library                       | Load, new profile (s)   | Load, stored profile (s) | Save (s)                | Release (s)             |
| ----------------------------- | ----------------------- | ------------------------ | ----------------------- | ----------------------- |
| Geode before                  | 0.38 (0.28 to 0.52, 25) | 0.33 (0.27 to 0.40, 25)  | 0.23 (0.15 to 0.30, 25) | 0.25 (0.18 to 0.40, 25) |
| Geode after                   | 0.27 (0.18 to 0.40, 10) | 0.22 (0.18 to 0.30, 10)  | 0.21 (0.15 to 0.28, 10) | 0.24 (0.20 to 0.27, 10) |
| Geode after, `mailbox = true` | 0.32 (0.22 to 0.55, 10) | 0.27 (0.20 to 0.35, 10)  | 0.24 (0.17 to 0.33, 10) | 0.26 (0.18 to 0.32, 10) |
| ProfileStore                  | 0.32 (0.18 to 0.50, 35) | 0.28 (0.20 to 0.48, 35)  | 0.25 (0.17 to 0.40, 35) | 0.28 (0.18 to 0.47, 35) |
| ProfileService                | 0.32 (0.20 to 0.45, 35) | 0.28 (0.18 to 0.38, 35)  | 0.27 (0.17 to 0.35, 35) | 0.28 (0.17 to 0.43, 35) |
| DataStore2                    | 0.08 (0.03 to 0.12, 35) | 0.03 (0.02 to 0.07, 35)  | 0.30 (0.20 to 0.38, 35) | 0.25 (0.18 to 0.33, 35) |

DataStore requests per step, the same in every sample:

| Library                       | Load                                                        | Save          | Release       |
| ----------------------------- | ----------------------------------------------------------- | ------------- | ------------- |
| Geode before                  | 1 UpdateAsync, then 1 GetAsync (its mailbox)                | 1 UpdateAsync | 1 UpdateAsync |
| Geode after                   | 1 UpdateAsync                                               | 1 UpdateAsync | 1 UpdateAsync |
| Geode after, `mailbox = true` | 1 UpdateAsync and 1 GetAsync (its mailbox) at the same time | 1 UpdateAsync | 1 UpdateAsync |
| ProfileStore                  | 1 UpdateAsync                                               | 1 UpdateAsync | 1 UpdateAsync |
| ProfileService                | 1 UpdateAsync                                               | 1 UpdateAsync | 1 UpdateAsync |
| DataStore2                    | 1 GetAsync                                                  | 1 UpdateAsync | 1 UpdateAsync |

A DataStore2 load is one GetAsync and takes no lock. The others write their lock in the same request that reads the data.

Geode used to read its mailbox after taking the lease, so every load waited for two requests one after the other. Before, its load was the slowest of the three libraries that lock in four of the five runs. Now a store reads a mailbox only when it's made with `mailbox = true`, and then at the same time as the UpdateAsync. In the two runs after the change Geode loaded a new profile in 0.25 and 0.32 s (medians), next to 0.30 and 0.30 s for ProfileStore and 0.28 and 0.33 s for ProfileService. With `mailbox = true` it took 0.27 and 0.35 s, a few hundredths more than the default rather than a whole extra request.

### Server hops

A hop needs two servers at once, so the bench starts two tasks together: one plays the old server, the other the new one. They coordinate through a MemoryStore hash map named after the run. Both tasks of every pair ran at the same time, each with its own JobId, and MessagingService messages reached from each task to the other in every run.

The old server loads a profile, saves a value (777), waits 8 seconds, then changes it to 888 without saving and tells the new server it's ready.

- **Old server releases.** The new server writes "go" and starts loading at once. The old server sees "go" (within 0.4 s in every sample) and releases, the way a server releases when a player leaves for another one. The time is from the new server's load call until it has the data. 888 means the new server saw the old server's final save
- **Old server keeps it.** Same, with 999 as the unsaved value, but the old server never releases on its own. Whatever happens next is the library's doing. 999 means the library got the old server to hand the profile over with its last change, 777 means the new server went ahead without it

| Library                       | Old server releases (s) | Saw the final save | Old server keeps it (s)   | Value seen when kept | Requests by the new server                                      |
| ----------------------------- | ----------------------- | ------------------ | ------------------------- | -------------------- | --------------------------------------------------------------- |
| Geode before                  | 4.95 (4.55 to 5.17, 15) | 15 of 15           | 4.98 (4.62 to 5.20, 5)    | 999 in 5 of 5        | 4 UpdateAsync and 1 GetAsync                                    |
| Geode after                   | 0.62 (0.62 to 0.67, 6)  | 6 of 6             | 0.68 (0.63 to 0.73, 2)    | 999 in 2 of 2        | 2 UpdateAsync and 1 GetAsync past the cache                     |
| Geode after, `mailbox = true` | 0.59 (0.50 to 0.75, 6)  | 6 of 6             | 0.63 (0.58 to 0.68, 2)    | 999 in 2 of 2        | 2 UpdateAsync, 1 GetAsync past the cache and 2 mailbox GetAsync |
| ProfileStore                  | 5.52 (0.75 to 5.60, 21) | 21 of 21           | 5.55 (5.38 to 5.62, 7)    | 999 in 7 of 7        | 1 or 2 UpdateAsync                                              |
| ProfileService                | 7.25 (0.78 to 7.30, 21) | 21 of 21           | 21.32 (21.23 to 21.52, 7) | 999 in 7 of 7        | 1 or 2 UpdateAsync, 4 when kept                                 |
| DataStore2                    | 0.03 (0.02 to 0.07, 21) | 0 of 21            | 0.03 (0.02 to 0.07, 7)    | 777 in 7 of 7        | 1 GetAsync                                                      |

When it kept the profile, the old server saw this: Geode's profile fired `released` after the new server's request, ProfileStore's fired `OnLastSave` with `"External"`, and ProfileService's `ListenToRelease` fired. DataStore2 has no lock, so both servers had the data open at the same time and the new one read the value saved 8 seconds earlier.

ProfileStore's usual 5.5 s is its `FIRST_LOAD_REPEAT` wait before it reads again. Once, its first read already found the session released, and the hop took 0.75 s. ProfileService's usual 7.3 s matches its 7 second per key cooldown. In one run all three of its hops took about 0.8 s with one UpdateAsync that ran while the old server was releasing. Its 21 s when kept fits the old server's next autosave seeing the request, as its source describes: the timeline shows four UpdateAsync calls 7 s apart.

Geode before took about 5 s although the old server released within half a second. The timelines show where the time went: its tries started at 0, about 0.5, 2.5 and 4.6 s. The second and third came back in under 10 ms (in `0f6881b6` under 1 ms) and still found the lease held, and only the fourth, about 4.6 s after the first, took a normal 0.2 to 0.3 s and got the profile. Those tries are UpdateAsync calls. Roblox documents a 4 second local cache for GetAsync, and says SetAsync and UpdateAsync write into it, but not that UpdateAsync reads from it. These timings say it does: an UpdateAsync whose transform writes nothing gets answered from the server's copy of the key, and since nothing is written, nothing goes to the backend to set it right.

Geode after reads the key once with `DataStoreGetOptions.UseCache = false` when the old server announces its release, and only then tries the UpdateAsync. In all sixteen hops after the change, kept ones included, that UpdateAsync took the lease, and the hop took 0.50 to 0.75 s. So the read past the cache also refreshes the copy UpdateAsync sees, which matches the docs' "GetAsync calls that retrieve a value ... from the backend update the cache". Both halves come from these timings, not from Roblox's docs. With `mailbox = true` the mailbox is read again with the try that takes the lease, so mail sent during the wait still arrives.

### Throttling

What can be provoked fairly is a used up request budget on the library's own server. Each task starts with the same budgets (120 or 121 for UpdateAsync, GetAsync, StandardRead and StandardWrite), fires 160 or 161 UpdateAsync calls at once on throwaway keys, then has the library load, save and release one profile. The burst's transform returns nil, so it writes nothing and leaves no keys behind. In every run the burst took the UpdateAsync and StandardRead budgets to 0 and left StandardWrite as it was. Roblox queued most of it ("DataStore request was added to queue") and dropped 9 calls with "StandardReadGameServerThrottled: StandardRead request was throttled by game server limits or the request queue was full". The library's steps then run back to back, without the 8 second gap. That's one sample per run.

| Library                       | Load (s)       | Save (s)     | Release (s)  | What the proxy saw during the load                                                                                                                                               |
| ----------------------------- | -------------- | ------------ | ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Geode before                  | 33.79 to 34.11 | 0.20 to 1.23 | 0.17 to 0.28 | 1 UpdateAsync and 1 GetAsync, none failed. Geode's scheduler held the UpdateAsync back for about 32.6 s until the budget allowed it, and the mailbox GetAsync for another second |
| Geode after                   | 32.71 to 32.89 | 1.17 to 1.25 | 0.18 to 0.22 | 1 UpdateAsync, none failed, sent about 32.6 s in                                                                                                                                 |
| Geode after, `mailbox = true` | 32.93 to 33.69 | 1.18 to 1.20 | 0.17 to 0.18 | 1 GetAsync and 1 UpdateAsync, none failed. Both wait for the read budget, so here too the second went about a second after the first                                             |
| ProfileStore                  | 31.16 to 31.47 | 0.12 to 0.27 | 0.15 to 0.32 | 2 UpdateAsync. The first was dropped at once, the retry a second later sat in Roblox's queue for about 30 s                                                                      |
| ProfileService                | 30.19 to 31.74 | 0.13 to 0.47 | 7.03 to 7.25 | 1 UpdateAsync, sent 5.5 s in and queued by Roblox until it went through. The release waits out the 7 second per key cooldown                                                     |
| DataStore2                    | 31.04 to 31.10 | 1.12 to 1.18 | 0.10 to 0.20 | 61 to 63 GetAsync, all failed but the last: it retries at once until a request gets through                                                                                      |

Every library got its data in the end and none lost a write. Geode's, ProfileStore's and DataStore2's save and release there were two writes to one key back to back, and the second one wasn't held up. These numbers show how each one behaves behind a queue that Roblox drains at its own pace, not how fast any of them is. A server with players has bigger budgets, which wasn't measured.

## Not measured

- **Lapis, in every part.** Lapis sends every DataStore request from a `RunService.PostSimulation` handler. In a Luau Execution task `Heartbeat` fired about 62 times a second, but `PostSimulation`, `PreSimulation` and `Stepped` never fired, in any task of any run. In the first run Lapis loads made no DataStore request at all in 40 to 90 seconds, and its first task ran out of time. Later runs check the event first and skip Lapis. Measuring it needs a server that steps physics, such as a live game server
- **Taking over a crashed server's lock.** That waits for the lock to time out (Geode 300 s, ProfileStore 630 s, ProfileService and Lapis 30 minutes), longer than a five minute task
- **DataStore2's default OrderedBackups method**, which needs DataStores named per player. Only the Standard method ran
- **Servers with players.** Request budgets grow with the player count, and every task here had none
- Memory and CPU use

## How it runs

`lune run bench` (or the Benchmarks workflow on a pull request that changes the bench) does this:

1. Downloads each library from its repository at a pinned commit into `.cache`, which git ignores. Before using one, it checks the license file against the hash recorded in `tests/bench/libraries.json` and refuses the library if it changed
2. Builds a place holding the usual Studio checks plus the bench and the libraries, and uploads it to the test place as a saved version, the same way the live checks do
3. Runs each part as a Luau Execution task on that version and collects what each task returns

Each library runs in its own task. In every run each task reported its own JobId, saw nothing a previous task left in the DataModel, reported `RunService:IsStudio()` as false and started with the same request budgets (120 or 121 for the main request types), so every library starts on a fresh server with no players.

### Same conditions for every library

- Every library gets one DataStore, `GeodeStudioCheck_Bench_<Library>`, and fresh keys each run. Nothing else is allowed. Geode with `mailbox = true` runs as its own library, `GeodeMail`
- The data is the same everywhere: a few fields and a 50 item inventory
- Steps on one key are at least 8 seconds apart. That's longer than ProfileService's 7 second per key cooldown, so it doesn't show up in a timing. The throttling test is the exception, its steps run back to back
- Times are wall clock seconds from calling the library to the moment its DataStore request finished. ProfileStore and ProfileService start saves and releases on a separate thread and return right away, so for them the bench waits until the proxy sees the write finish
- A release always follows a change, so every library has something to write. A DataStore2 release is a player leaving, which is when it saves

### Counting requests

The libraries call DataStoreService themselves, so the bench gives each one a stand-in that forwards every call unchanged and logs it. That's an exact count of the requests a library sends for a key during a step, retries included. Requests Roblox might repeat inside the engine aren't visible to it. The bench also records the request budgets before and after each step, but budgets refill while a step runs, so those deltas only roughly agree with the counts and the counts are what's reported.

How each library gets the stand-in:

- Geode: through its `services` option, built with `Geode.Raw.fromRoblox`. With `mailbox = true` Geode keeps mail in a second DataStore named `<name>_mailbox`, which the stand-in moves under a scope of the allowed name, so Geode reads the same number of keys it would otherwise. The stand-in also marks a GetAsync that skips the cache (`DataStoreGetOptions.UseCache = false`)
- Lapis: through `Lapis.setConfig({ dataStoreService = ... })`
- DataStore2: through the two modules its own tests patch (`DataStoreServiceRetriever` and `IsPlayer`). There are no players in a task, so it gets a stand-in player with a `UserId`, `AncestryChanged` and `IsDescendantOf`. Its default OrderedBackups method opens a DataStore and an OrderedDataStore per player, named after the player, which the one allowed name rules out, so it runs with the Standard method, one DataStore keyed by user id
- ProfileStore and ProfileService: both read `game:GetService("DataStoreService")` once when they're required. The runner swaps that one line for the stand-in after downloading them and refuses to run either if the line isn't there exactly once. Nothing else in them changes

## Running it yourself

The Benchmarks workflow runs on pull requests that change the bench and can be started by hand. It needs the same `ROBLOX_API_KEY` secret as the live checks and uploads `results.json` (every step, request and budget) and `summary.md` as an artifact. Locally, `lune run bench` does the same with the key in the environment, and `lune run bench Geode,ProfileStore` runs only some libraries. Every run uploads a new saved version of the test place, which still runs the Studio checks.
