# Studio checks

The Lune tests run Geode against in-memory mocks. This place runs the parts that only live Roblox services can answer, and checks that the real adapters behave like the mocks.

## Running it

1. Publish an empty place you own, or open one, and turn on **Enable Studio Access to API Services** in Game Settings > Security.
2. From the repo root, run `rojo serve tests/studio/studio.project.json` and connect from the Rojo plugin in Studio.
3. Press **Run** (server only is enough). The output window lists one line per check, then a total.

The checks live in the `Checks` module. `Run` calls it when a playtest starts, prints one `GEODE_CHECK_RESULTS` line of JSON with every result and keeps the same JSON in its `Results` attribute, so tools can read the outcome without parsing the whole output.

Each line starts with one of three labels:

- `[PASS]` the behavior matched what Geode expects
- `[FAIL]` it didn't, with what was seen instead
- `[OBSERVED]` the line records what Roblox did, for behavior the code depends on or that can't run here

## Running it without Studio

`lune run live` runs the same checks headlessly through Open Cloud, locally or in CI. It builds this place with Rojo, uploads it to the test place as a **saved** version, runs each group of checks (services, contracts, profile) as a Luau Execution task against that version, and prints every result. It exits non-zero when a check fails, when a task fails, or when a task doesn't finish in time. Observed results are listed apart and never fail the run.

Uploading a saved version doesn't publish it, so the live game never changes. DataStore, MemoryStore and MessagingService all work inside an execution task. ReserveServer doesn't, so the teleport contract shows as observed there too.

### Setup

1. In the Creator Dashboard, create an API key with these permissions, restricted to the test experience only:
   - **universe-places**: `write`, to upload the place version
   - **universe.place.luau-execution-session**: `read` and `write`, to run tasks and read their results and logs
2. Put the key in the `ROBLOX_API_KEY` environment variable. Locally that's your shell, in GitHub it's a repository secret with the same name. The runner never prints it.
3. The test experience's ids live in `tests/studio/live.json`: universe `10771072774`, place `125801576807131`. Change them there to point at another test place.

The `Live checks` workflow runs it on pull requests from this repository and on demand. Pull requests from forks skip it, since a fork could read the secret.

## What it touches

Every DataStore uses the name `GeodeStudioCheck` or starts with `GeodeStudioCheck_`, under scopes starting with `geode-check`. MemoryStore structures and topics start with `GeodeStudioCheck-`. Each run, and each contract test inside it, adds a fresh id to all of them, so no check reads what another one wrote and none touches real game data. MemoryStore entries expire within a few minutes. DataStore keys stay behind and count toward the experience's storage, so run it in a test experience.

## The checks

| Check                                                | What it settles                                                                                                         |
| ---------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| UpdateAsync contention from two threads on one key   | Concurrent transforms on one key are rerun on fresh data, so no increment is lost. The lease protocol depends on this   |
| GetVersionAsync with a version id that never existed | It throws a 502 saying the version isn't valid. Geode treats that as not found and doesn't retry it                     |
| Sorted map bounds holding only a key or a sort key   | A key alone sits where that key with no sort key would. A sort key alone leaves out every item with that sort key       |
| Queue RemoveAsync with an old id after a second read | The old id does nothing once the items were read again                                                                  |
| JSONEncode next to Geode's own encoder               | Floats and non-ASCII text come out the same. Only control characters below 32 are escaped                               |
| UpdateAsync returning no metadata                    | Roblox clears the key's metadata, so the adapter carries it forward itself                                              |
| Adapter contracts                                    | The same contract suites the mocks pass, run against live DataStore, OrderedDataStore, MemoryStore and MessagingService |
| Teleport contract                                    | Reported as observed: ReserveServer is refused in Studio and only works from a live game server                         |
| Profile cycle                                        | A full load, change, save, release and reload of a profile against live DataStores                                      |

When an observed result differs from the mock, update the mock and its contract test to match, then drop the matching `TODO(verify)` note in the source.
