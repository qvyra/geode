# Bench data

Every run of the bench in `tests/bench` that the docs draw on, and what the docs site publishes from them.

## Runs

`runs/` has one file per run, named after the run id. A file holds what `lune run bench` saved in `results.json`, with every step, request, timeline and budget as measured, plus:

- `build`: which Geode it measured, one of the builds in `catalog.json`
- `geodeSourceTree` and `benchTree`: git's ids for `src` and `tests/bench` at the commit the bench ran on. Runs with the same `benchTree` ran the same steps
- `workflowRun`: the Benchmarks workflow run that produced it
- `environment.ownServer` on each task: whether no other task in the run reported the same JobId

Anything that only identifies the test place, a server or a key is left out: place ids, place versions, JobIds, profile keys and messaging topics. Ids inside log lines read `<job>` and `<id>`.

## Catalog

`catalog.json` holds what the runs themselves don't say:

- the suites, their scenarios and metrics, and each suite's timing step (`timingResolution`). The bench checks for a finished request once a frame, so its times move in steps of 1/60 s. A suite marked `recordedOnly` stays in the run files but out of `latest.json`, for numbers that don't hold steady between runs
- the request methods, with a stable id for each (`GetAsync:noCache` for a GetAsync past the cache) and a label to show
- Geode's builds and build lines. A line groups builds that behave the same in what the bench measures, and each build lists the `src` trees it covers
- the subjects: one library with one config. Geode with `mailbox = true` is its own subject, and so is Geode from before mail became opt-in, marked historical
- what isn't measured, and why
- how many runs the current results take (`currentRuns`)

## Published files

`lune run benchdata build` writes them to `.moonwave/static/data/benchmarks`, which the docs site serves at `https://qvyra.github.io/geode/data/benchmarks/`:

- `latest.json`: the catalog and the current results. Current subjects all take the same runs, the last ones in which the current Geode line ran. A historical subject keeps the last runs of its own line
- `index.json`: every run
- `runs/<run>.json`: one run's results in the same shape, and its raw tasks
- `schema/v1.json`: the JSON Schema for all three, a copy of `schema.json`

The same command writes the tables in `docs/benchmarks.md` that sit between `bench:table` markers, from `latest.json`. Notes columns are kept by hand, matched by the row's label.

`lune run check` fails when the published files or those tables don't match the runs and the catalog, and checks the files against the schema.

## Adding a run

The Benchmarks workflow does this itself after a run on a release tag, by hand or once a month, and opens a pull request with the result. By hand, download the `bench-results` artifact of a run and:

```sh
lune run benchdata import results.json
lune run benchdata build
```

The import names the build after the catalog's build for the run's `src`, or the release whose `src` matches, or `unreleased-<tree>`. A build the catalog doesn't know yet is added on the line of the build before it, which is worth checking in review. Runs from before the bench recorded its tree ids and workflow run need them given with `--source-tree`, `--bench-tree` and `--workflow-run`, where the tree ids come from `git rev-parse <commit>:src` and `git rev-parse <commit>:tests/bench`.
