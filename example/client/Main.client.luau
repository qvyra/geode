--!strict

-- The example game's client: shows replicated coins and buys a sword through a remote op

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Geode = require(ReplicatedStorage.Packages.Geode)

local client = Geode.Client.start()
client:waitUntilReady()

local coins = client:atom("coins")
print(`you have {coins:get()} coins`)
coins:subscribe(function(new: number)
	print(`coins: {new}`)
end)

local wealth = client:computed(function()
	local inventory = client:atom("inventory"):get() :: { string }?
	return (coins:get() or 0) + #(inventory or {}) * 50
end)
wealth:subscribe(function(new: number)
	print(`total worth: {new}`)
end)

client:op("buyItem", "sword")
