# Contributing

Thanks for helping with Geode. This page covers setup, the checks every change has to pass, and how commits and branches are written.

## Setup

You need [Rokit](https://github.com/rojo-rbx/rokit) and Node.js.

```sh
rokit install
npm ci
lune run check
```

`lune run check` runs everything CI runs: StyLua, Selene, luau-lsp, the Lune tests, Prettier, ESLint, TypeScript and cspell. `lune run fix` applies the formatters. `lune run test <filter>` runs only the spec files whose path contains the filter.

Tests run in Lune against in-memory mocks of every Roblox service, with virtual time and fault injection. Behavior only live services can settle is checked by the Studio place in `tests/studio`, see its README.

## Code

- Every Luau file starts with `--!strict`. Every `any` has a comment saying why
- Core modules never call `game:GetService`. Roblox services come in through the Quartz adapters, so everything runs against mocks
- A layer only uses the public API of the layer below it
- Reads never hand out mutable data, and every write goes through the transaction pipeline
- Nothing truncates or drops user data automatically
- Every new public function has a test and a Moonwave doc comment
- If you aren't sure how a Roblox API behaves, don't guess. Leave a `TODO(verify)` comment saying what's unknown

Names follow one table: PascalCase for modules, classes and types, camelCase for functions, methods and fields, SCREAMING_SNAKE for constants, and a leading underscore for private members.

## Comments

Comment the why when the code doesn't make it obvious, and keep it short.

## Commits and branches

Commits follow Conventional Commits:

```
<type>(<scope>): <subject>

<body: why the change exists, what it trades off, anything surprising>
```

- Types: `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `chore`, `build`, `ci`
- Scopes are module names, like `sapphire`, `quartz` or `prism`, or `repo` for the repository itself
- The subject is imperative, starts lowercase, has no closing period and stays under 72 characters
- One logical change per commit, and every commit builds and passes the checks on its own

Branches are named `<type>/<short-slug>`, like `feat/shared-stores`. Changes are rebased and merged fast forward, so history stays linear.

## Decisions

When a change makes a real design choice, add an entry to [DECISIONS.md](DECISIONS.md) with the date, the context, the options considered, what was chosen and the commits that show it. Don't rewrite old entries. A new entry says which one it revises.
