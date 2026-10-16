---
sidebar_position: 2
---

# How it works

This page follows one player's data from join to leave. If you have used a session-locking library before, most of the words will be familiar. Where Geode's name for something differs, the usual term is in brackets once.

## A profile per player

Each player's data is a **profile**: one DataStore key holding the data plus a little bookkeeping. Profiles live in a profile store, made with `Geode.Profile.store`, or for you by `Geode.players`.

New players start from the store's **template**. When an existing profile loads, any field the template has and the saved data lacks is filled in (reconciling). Values already saved are never changed, keys the template doesn't know are kept, and lists are left as they are. Removing or renaming a field takes a migration.

## Only one server holds a profile

While a server has a profile loaded, it holds a **session lease** on it (the session lock). The lease is stored inside the profile's own DataStore record, and every save is a single UpdateAsync that writes the data and renews the lease together, and only if the lease is still this server's. So two servers can't both save the same profile.

When a player joins a new server while the old one still holds their profile:

1. The new server sees the lease is taken and asks the holder to let go, over MessagingService
2. The old server saves one last time and gives up the lease (a release)
3. The new server takes the lease and loads the data

That usually costs only the old server's final save. If the holder doesn't let go within `stealAfter` seconds (15 by default), the store's `stealPolicy` decides: `"steal"` takes the lease anyway (the default, often called force loading), `"wait"` keeps waiting and `"fail"` gives up with a `leaseHeld` error.

A server that stopped renewing its lease, for example because it froze, can't do harm afterwards. Its next save sees the lease belongs to someone else and refuses to write. The profile's `sessionLost` signal fires, and by default the player on that server is kicked.

## Saving

Loaded profiles **autosave** every `autosaveInterval` seconds, 60 by default. With `Geode.players`, a profile is also saved and released when its player leaves. When the server shuts down, Geode releases every profile it holds and waits for those saves, up to `closeTimeout` seconds (25 by default, since Roblox gives a closing server about 30). `profile:save()` saves right away when you need it to.

A lease that hasn't been renewed for `leaseTimeout` seconds (300 by default) counts as abandoned, so data held by a server that crashed becomes free again on its own.

## Changing data

Profile data is not a table you edit in place. Writes go through ops such as `profile:increment("coins", 10)`, or several ops at once in `profile:transact`, and reads return frozen values. Every write runs through one pipeline where guards can refuse it, and listeners, replication and history all see it. [Concepts](concepts) goes through that pipeline step by step.

## When things go wrong

- A load that fails for a reason that might pass, such as throttling, is retried until `loadTimeout`. `Geode.players` kicks a player whose data can't load rather than let them play on the template
- Data that doesn't decode as a profile is left untouched and reported, never overwritten
- Data over the size budget is never trimmed. The save keeps what was stored, renews the lease and reports the problem
- In Studio, data stays in memory by default, so a playtest can't touch real players' data
