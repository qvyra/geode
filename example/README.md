# Example place

A small game that uses most of Geode the way a real one would: player data with replication, a shop op clients ask for through a rate limited remote op, a developer product and a daily leaderboard.

Run it with `rojo serve example/example.project.json`, connect from Studio and press Play. In Studio, player data stays in memory, so nothing touches your live DataStores. Set the product id in `server/Main.server.luau` to one of your own developer products to try a purchase.
