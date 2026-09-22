--!strict

-- The example game's server: player data with replication, a shop op clients can ask for, a
-- developer product and a daily leaderboard

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local t = Geode.t

Geode.op("buyItem", function(tx, item: string)
	local prices: { [string]: number } = { sword = 100, shield = 75 }
	local price = prices[item]
	assert(price, `unknown item {item}`)
	tx:decrement("coins", price)
	tx:append("inventory", item)
end)

local PlayerData = Geode.players({
	name = "ExamplePlayerData",
	template = { coins = 0, inventory = {}, wins = 0 },
	replicate = { coins = "owner", inventory = "owner", wins = "public" },
	ops = { "buyItem" },
	guards = { Geode.guard.range("coins", { min = 0 }) },
	products = {
		[0] = function(tx)
			tx:increment("coins", 500)
		end,
	},
})

Geode.remoteOp("buyItem", {
	store = PlayerData.store,
	args = { t.enum({ "sword", "shield" }) },
	rateLimit = { count = 5, window = 10 },
})

local Daily = Geode.Ranked.windowed("ExampleDailyWins", { window = "daily", mode = "sum" })

PlayerData:onLoaded(function(player, profile)
	profile:increment("coins", 100)
	print(`{player.Name} loaded with {profile:get("coins")} coins`)
end)

-- stand-in for winning a round, once a minute
task.spawn(function()
	while true do
		task.wait(60)
		for _, player in game:GetService("Players"):GetPlayers() do
			local data = PlayerData:get(player)
			if data and data:isLoaded() then
				data:increment("wins")
				Daily:submit(player.UserId, 1)
			end
		end
	end
end)
