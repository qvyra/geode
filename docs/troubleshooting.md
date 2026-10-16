---
sidebar_position: 6
---

# Troubleshooting

## Data doesn't save between Studio playtests

That's the default. In Studio, player data lives in memory so a playtest can't touch real data. To keep data between playtests, set the Studio mode to `"scope"` (a separate scope of the real DataStore) or `"real"` (live data) with `Geode.setup` or the store's `studio` option, and turn on Studio access to API Services in the experience's settings. See [Profiles](profiles).

## Reads return the template and writes fail with `readOnly`

The player's profile hasn't loaded yet. `PlayerData:get(player)` works from the moment a player joins, but until the load finishes it reads the template and refuses writes. Check `isLoaded`, wait with `waitFor`, or put the code in `onLoaded`.

## A player was kicked with "Couldn't load your data, please rejoin"

The load kept failing. Loads that might pass on their own are retried a few times first, and only then is the player kicked, so they never play on data that wasn't loaded. Watch the error reporting set through `Geode.setup` to see why the loads failed.

## A player was kicked after joining another server

Their profile's session was taken by another server, and the default `onSessionLost` policy is `"kick"`. This usually means the old server stopped renewing its lease, for example because it froze. Set `onSessionLost` to `"none"` or to a function to handle it yourself. The server that lost the session never writes over the new holder's data either way.

## A save keeps reporting that the data is too large

The profile went over its hard size budget. Geode never trims data to make it fit, so the save keeps what was stored before, renews the lease and reports the problem, while the changes stay in memory. The soft budget warns before that happens. Both can be set with the store's `sizeBudget` option. Find what grew, usually a list that only ever gets longer, and cap it in your own code or with a guard.

## A write returns `ok = false` and nothing changed

A guard most likely rejected it, and a rejection undoes the whole transaction, including anything bundles and reactions wrote. The result says why, and every violation also fires the store's `guardBroken` signal. See [Guards](guards).

## A client change doesn't reach the server

Clients never write state. A client asks for a change through a remote op the server declared, and that op runs through the same guards as any other write. See [Replication and remote ops](replication).

## A client doesn't see a value

Only paths listed in `replicate` reach clients: `owner` paths reach their player, `public` paths reach everyone, and everything else stays on the server.

## Requests seem slow under load

Every DataStore request goes through a scheduler that keeps inside Roblox's request budgets. Releases go before saves, saves before loads and loads before background work, and throttled calls retry with backoff. Background work waits first when budgets run low, so a busy server can make it slower without losing anything.

## Testing without Studio

`Geode.Testing` gives you in-memory services with a virtual clock and fault injection, so the same code runs in Lune. See [Testing with Geode.Testing](testing).
