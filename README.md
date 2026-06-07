# Geode

A layered data framework for Roblox. Geode puts DataStoreService, MemoryStoreService and MessagingService behind one API, with guards, reactive data and replication on top.

> Geode is in early development and nothing is usable yet. The API will change without notice until 1.0.

## The idea

```
Polish       one call setup for player data, sensible defaults
Stores       Profile, Shared, Ephemeral, Ranked
Primitives   scheduler, retry, schema, transactions, leases, guards
Adapters     DataStore, MemoryStore, MessagingService, plus mocks
```

Each layer only uses the public API of the one below it. Start at the top and drop down a level whenever you need more control.

DataStore is always the source of truth. MemoryStore and MessagingService only make things faster or help servers coordinate, and correctness never depends on them.

## Development

You need [Rokit](https://github.com/rojo-rbx/rokit) and Node.js.

```sh
rokit install
npm ci
lune run check
```

`lune run check` runs formatting, linting, type checking and tests, the same as CI. `lune run fix` applies the formatters. `lune run test <filter>` runs only the spec files whose path contains the filter.

## License

MIT, see [LICENSE](LICENSE).
