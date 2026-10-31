# Bench runs

Every run of the bench in `tests/bench` that the docs draw on, one file per run in `runs/`, named after the run id. A file holds what `lune run bench` saved in `results.json`, with every step, request, timeline and budget as measured, plus:

- `build`: which Geode it measured. `0.5.0` and `0.6.0` had the same `src` as those releases (0.6.0 apart from its version stamp), `0.5.0+format` is 0.5.0 with the record format field on every write, and `0.6.0-pre` differs from 0.6.0 only in comments, mock-only code and the version stamp
- `geodeSourceTree` and `benchTree`: git's ids for `src` and `tests/bench` at the commit the bench ran on. Runs with the same `benchTree` ran the same steps
- `workflowRun`: the Benchmarks workflow run that produced it
- `environment.ownServer` on each task: whether no other task in the run reported the same JobId

Anything that only identifies the test place, a server or a key is left out: place ids, place versions, JobIds, profile keys and messaging topics. Ids inside log lines read `<job>` and `<id>`.

To add a run, download the `bench-results` artifact of a Benchmarks run and import it:

```sh
lune run benchdata import results.json --build 0.6.1
```

The bench records the tree ids and the workflow run in `results.json`. Runs from before it did need them given with `--source-tree`, `--bench-tree` and `--workflow-run`, where the tree ids come from `git rev-parse <commit>:src` and `git rev-parse <commit>:tests/bench`.
