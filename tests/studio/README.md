# Studio checks

The Lune tests run Geode against in-memory mocks. This place runs the parts that only live Roblox services can answer, and checks that the real adapters behave like the mocks.

## Running it

1. Publish an empty place you own, or open one, and turn on **Enable Studio Access to API Services** in Game Settings > Security.
2. From the repo root, run `rojo serve tests/studio/studio.project.json` and connect from the Rojo plugin in Studio.
3. Press **Run** (server only is enough). The output window lists one line per check, then a total.

Each line starts with one of three labels:

- `[PASS]` the behavior matched what Geode expects
- `[FAIL]` it didn't, with what was seen instead
- `[OBSERVED]` the behavior is undocumented, and the line records what Roblox did so the mocks can be matched to it

## What it touches

Every DataStore uses the name `GeodeStudioCheck` or starts with `GeodeStudioCheck_`, under scopes starting with `geode-check`. MemoryStore structures and topics start with `GeodeStudioCheck-`. Each run adds a fresh id to all of them, so a run never reads what an earlier one wrote and never touches real game data. MemoryStore entries expire within a few minutes. DataStore keys stay behind and count toward the experience's storage, so run it in a test experience.

## The checks

| Check                                                | What it settles                                                                                                              |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| UpdateAsync contention from two threads on one key   | Whether concurrent transforms on one key are rerun on fresh data so no increment is lost. The lease protocol depends on this |
| GetVersionAsync with a version id that never existed | Whether it returns nil or throws. The mock returns nil                                                                       |
| Sorted map bound holding only a key                  | What a range bound with a key and no sort key compares against. The mock compares the key alone                              |
| Sorted map bound holding only a sort key             | The same for a bound with only a sort key                                                                                    |
| Queue RemoveAsync with an old id after a second read | Whether an old read id still removes items that were read again. The mock ignores it                                         |
| Adapter contracts                                    | The same contract suites the mocks pass, run against live DataStore, OrderedDataStore, MemoryStore and MessagingService      |
| Profile cycle                                        | A full load, change, save, release and reload of a profile against live DataStores                                           |

When an observed result differs from the mock, update the mock and its contract test to match, then drop the matching `TODO(verify)` note in the source.
