---
sidebar_position: 19
---

# Benchmarks

These numbers come from the bench in `tests/bench`, run against live Roblox services with the same steps for Geode, ProfileStore, ProfileService, Lapis and DataStore2. The versions are the ones listed on [Comparing libraries](comparison). Every number here is from a real run, and anything that couldn't be measured fairly says so.

## Results

Four runs on 2026-10-19 (bench runs `1d449b46`, `7ef740a9`, `25532752` and `3561e8c8`, place versions 27, 29 and 30). The fourth run also recorded when each request started and ended, which the notes below use. Each cell is the median, then the lowest and highest value and how many samples went in. Lapis isn't in the tables, see [Not measured](#not-measured).

### Load, save and release

Each run loads five fresh profiles, saves each, releases each after a change, loads them again and releases them again, with the steps on one key at least 8 seconds apart.

| Library        | Load, new profile (s)   | Load, stored profile (s) | Save (s)                | Release (s)             |
| -------------- | ----------------------- | ------------------------ | ----------------------- | ----------------------- |
| Geode          | 0.38 (0.28 to 0.70, 20) | 0.37 (0.27 to 0.48, 20)  | 0.23 (0.15 to 0.35, 20) | 0.26 (0.18 to 0.40, 20) |
| ProfileStore   | 0.31 (0.18 to 0.38, 20) | 0.28 (0.20 to 0.38, 20)  | 0.24 (0.17 to 0.33, 20) | 0.27 (0.18 to 0.35, 20) |
| ProfileService | 0.32 (0.20 to 0.38, 20) | 0.28 (0.18 to 0.37, 20)  | 0.27 (0.17 to 0.38, 20) | 0.28 (0.17 to 0.43, 20) |
| DataStore2     | 0.07 (0.03 to 0.13, 20) | 0.03 (0.02 to 0.07, 20)  | 0.32 (0.20 to 0.63, 20) | 0.26 (0.18 to 0.35, 20) |

DataStore requests per step, the same in every sample:

| Library        | Load                                       | Save          | Release       |
| -------------- | ------------------------------------------ | ------------- | ------------- |
| Geode          | 1 UpdateAsync and 1 GetAsync (its mailbox) | 1 UpdateAsync | 1 UpdateAsync |
| ProfileStore   | 1 UpdateAsync                              | 1 UpdateAsync | 1 UpdateAsync |
| ProfileService | 1 UpdateAsync                              | 1 UpdateAsync | 1 UpdateAsync |
| DataStore2     | 1 GetAsync                                 | 1 UpdateAsync | 1 UpdateAsync |

A DataStore2 load is one GetAsync and takes no lock. The others write their lock in the same request that reads the data.

### Server hops

A hop needs two servers at once, so the bench starts two tasks together: one plays the old server, the other the new one. They coordinate through a MemoryStore hash map named after the run. Both tasks of every pair ran at the same time, each with its own JobId, and MessagingService messages reached from each task to the other in every run.

The old server loads a profile, saves a value (777), waits 8 seconds, then changes it to 888 without saving and tells the new server it's ready.

- **Old server releases.** The new server writes "go" and starts loading at once. The old server sees "go" (within 0.4 s in every sample) and releases, the way a server releases when a player leaves for another one. The time is from the new server's load call until it has the data. 888 means the new server saw the old server's final save
- **Old server keeps it.** Same, with 999 as the unsaved value, but the old server never releases on its own. Whatever happens next is the library's doing. 999 means the library got the old server to hand the profile over with its last change, 777 means the new server went ahead without it

| Library        | Old server releases (s) | Saw the final save | Old server keeps it (s)   | Value seen when kept | Requests by the new server      |
| -------------- | ----------------------- | ------------------ | ------------------------- | -------------------- | ------------------------------- |
| Geode          | 4.95 (4.55 to 5.32, 12) | 12 of 12           | 5.01 (4.62 to 5.38, 4)    | 999 in 4 of 4        | 4 UpdateAsync and 1 GetAsync    |
| ProfileStore   | 5.50 (0.75 to 5.65, 12) | 12 of 12           | 5.57 (5.47 to 5.65, 4)    | 999 in 4 of 4        | 1 or 2 UpdateAsync              |
| ProfileService | 7.25 (0.78 to 7.32, 12) | 12 of 12           | 21.34 (21.23 to 21.52, 4) | 999 in 4 of 4        | 1 or 2 UpdateAsync, 4 when kept |
| DataStore2     | 0.05 (0.02 to 0.08, 12) | 0 of 12            | 0.05 (0.02 to 0.07, 4)    | 777 in 4 of 4        | 1 GetAsync                      |

When it kept the profile, the old server saw this: Geode's profile fired `released` after the new server's request, ProfileStore's fired `OnLastSave` with `"External"`, and ProfileService's `ListenToRelease` fired. DataStore2 has no lock, so both servers had the data open at the same time and the new one read the value saved 8 seconds earlier.

ProfileStore's usual 5.5 s is its `FIRST_LOAD_REPEAT` wait before it reads again. Twice, its first read already found the session released, and the hop took 0.75 or 0.78 s. ProfileService's usual 7.3 s matches its 7 second per key cooldown. In the fourth run all three of its hops took about 0.8 s with one UpdateAsync that ran while the old server was releasing. Its 21 s when kept fits the old server's next autosave seeing the request, as its source describes: the timeline shows four UpdateAsync calls 7 s apart.

Geode took about 5 s although the old server released within half a second. The fourth run's timeline shows where the time went: its tries start at 0, about 0.5, 2.5 and 4.6 s. The second and third returned in under 10 ms and still found the lease held, and only the fourth, 4.6 s after the first read, took a normal 0.2 to 0.3 s and got the profile. That fits Roblox answering an UpdateAsync whose transform changes nothing from its cache of the key for about 4 seconds. TODO(verify) that cache explanation. ProfileStore's and ProfileService's waits are longer than that window.

### Throttling

What can be provoked fairly is a used up request budget on the library's own server. Each task starts with the same budgets (120 or 121 for UpdateAsync, GetAsync, StandardRead and StandardWrite), fires 160 or 161 UpdateAsync calls at once on throwaway keys, then has the library load, save and release one profile. The burst's transform returns nil, so it writes nothing and leaves no keys behind. In every run the burst took the UpdateAsync and StandardRead budgets to 0 and left StandardWrite as it was. Roblox queued most of it ("DataStore request was added to queue") and dropped 9 calls with "StandardReadGameServerThrottled: StandardRead request was throttled by game server limits or the request queue was full". The library's steps then run back to back, without the 8 second gap. That's one sample per run, four in all.

| Library        | Load (s)       | Save (s)     | Release (s)  | What the proxy saw during the load                                                                                                                                   |
| -------------- | -------------- | ------------ | ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Geode          | 33.79 to 34.11 | 0.18 to 1.20 | 0.20 to 0.28 | 1 UpdateAsync and 1 GetAsync, none failed. In the fourth run Geode's scheduler held the UpdateAsync back for 32.7 s until the budget allowed it, then it took 0.26 s |
| ProfileStore   | 31.19 to 31.47 | 0.12 to 0.27 | 0.22 to 0.32 | 2 UpdateAsync. The first was dropped at once, the retry a second later sat in Roblox's queue for about 30 s                                                          |
| ProfileService | 30.19 to 31.27 | 0.20 to 0.22 | 7.03 to 7.12 | 1 UpdateAsync, sent 5.5 s in (fourth run) and queued by Roblox until it went through. The release waits out the 7 second per key cooldown                            |
| DataStore2     | 31.05 to 31.10 | 1.12 to 1.20 | 0.12 to 0.20 | 61 to 63 GetAsync, all failed but the last: it retries at once until a request gets through                                                                          |

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

- Every library gets one DataStore, `GeodeStudioCheck_Bench_<Library>`, and fresh keys each run. Nothing else is allowed
- The data is the same everywhere: a few fields and a 50 item inventory
- Steps on one key are at least 8 seconds apart. That's longer than ProfileService's 7 second per key cooldown, so it doesn't show up in a timing. The throttling test is the exception, its steps run back to back
- Times are wall clock seconds from calling the library to the moment its DataStore request finished. ProfileStore and ProfileService start saves and releases on a separate thread and return right away, so for them the bench waits until the proxy sees the write finish
- A release always follows a change, so every library has something to write. A DataStore2 release is a player leaving, which is when it saves

### Counting requests

The libraries call DataStoreService themselves, so the bench gives each one a stand-in that forwards every call unchanged and logs it. That's an exact count of the requests a library sends for a key during a step, retries included. Requests Roblox might repeat inside the engine aren't visible to it. The bench also records the request budgets before and after each step, but budgets refill while a step runs, so those deltas only roughly agree with the counts and the counts are what's reported.

How each library gets the stand-in:

- Geode: through its `services` option, built with `Geode.Raw.fromRoblox`. Geode keeps mail in a second DataStore named `<name>_mailbox`, which the stand-in moves under a scope of the allowed name, so Geode reads the same number of keys it would otherwise
- Lapis: through `Lapis.setConfig({ dataStoreService = ... })`
- DataStore2: through the two modules its own tests patch (`DataStoreServiceRetriever` and `IsPlayer`). There are no players in a task, so it gets a stand-in player with a `UserId`, `AncestryChanged` and `IsDescendantOf`. Its default OrderedBackups method opens a DataStore and an OrderedDataStore per player, named after the player, which the one allowed name rules out, so it runs with the Standard method, one DataStore keyed by user id
- ProfileStore and ProfileService: both read `game:GetService("DataStoreService")` once when they're required. The runner swaps that one line for the stand-in after downloading them and refuses to run either if the line isn't there exactly once. Nothing else in them changes

## Running it yourself

The Benchmarks workflow runs on pull requests that change the bench and can be started by hand. It needs the same `ROBLOX_API_KEY` secret as the live checks and uploads `results.json` (every step, request and budget) and `summary.md` as an artifact. Locally, `lune run bench` does the same with the key in the environment, and `lune run bench Geode,ProfileStore` runs only some libraries. Every run uploads a new saved version of the test place, which still runs the Studio checks.
