--!strict

-- leaderstats on Geode.players: a value per stat, kept in step with the data, gone on release

local Helpers = require("../Sapphire/Helpers")
local Polish = require("../../src/Polish")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")

type Any = any

local TEMPLATE = { coins = 0, stats = { kills = 0, ratio = 0.5 }, rank = "Rookie", inventory = {} }

local function make(
	server: Universe.MockServer,
	leaderstats: { Any },
	extra: { [string]: Any }?
): (Any, { string })
	local reported = {}
	local options: { [string]: Any } = {
		name = Helpers.STORE,
		template = TEMPLATE,
		services = server,
		autosaveInterval = 30,
		leaderstats = leaderstats,
		reportError = function(message: string)
			table.insert(reported, message)
		end,
	}
	local overrides: { [string]: Any } = extra or {}
	for key, value in overrides do
		options[key] = value
	end
	return Polish.players(options :: any), reported
end

-- name = value for each value in the player's leaderstats, and the names in order
local function shown(server: Universe.MockServer, player: unknown): ({ [string]: Any }?, { string })
	local values = server.playerList:read(player)
	if values == nil then
		return nil, {}
	end
	local byName: { [string]: Any } = {}
	local order = {}
	for _, entry in values do
		byName[entry.name] = entry.value
		table.insert(order, entry.name)
	end
	return byName, order
end

local function kinds(server: Universe.MockServer, player: unknown): { [string]: string }
	local result = {}
	local values: { Any } = server.playerList:read(player) or {}
	for _, entry in values do
		result[entry.name] = entry.kind
	end
	return result
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("leaderstats", function()
		it("shows each stat with a value kind picked from the template", function()
			Polish._reset()
			local universe = Universe.new()
			local server = universe:server()
			local PlayerData = make(server, {
				{ path = "coins", name = "Coins" },
				{ path = { "stats", "ratio" }, name = "Ratio" },
				{ path = "rank", name = "Rank" },
				{
					path = "stats.kills",
					name = "Kills",
					format = function(value: unknown): string
						return `{value} KOs`
					end,
				},
			})
			local player = server:join(1)
			universe.clock:advance(1)
			expect(PlayerData:isLoaded(player)).toBe(true)
			local values = shown(server, player)
			expect(values).toEqual({ Coins = 0, Ratio = 0.5, Rank = "Rookie", Kills = "0 KOs" })
			expect(kinds(server, player)).toEqual({
				Coins = "IntValue",
				Ratio = "NumberValue",
				Rank = "StringValue",
				Kills = "StringValue",
			})
		end)

		it("follows the data through every write", function()
			Polish._reset()
			local universe = Universe.new()
			local server = universe:server()
			local PlayerData = make(server, {
				{ path = "coins", name = "Coins" },
				{ path = "stats.kills", name = "Kills" },
			})
			local player = server:join(1)
			universe.clock:advance(1)
			local handle = PlayerData:get(player)
			handle:increment("coins", 25)
			handle:set("stats", { kills = 3, ratio = 1 })
			local values = shown(server, player) :: { [string]: Any }
			expect(values.Coins).toBe(25)
			expect(values.Kills).toBe(3)
		end)

		it("puts stats with an order first, lowest first, then the rest as listed", function()
			Polish._reset()
			local universe = Universe.new()
			local server = universe:server()
			make(server, {
				{ path = "rank", name = "Rank" },
				{ path = "coins", name = "Coins", order = 2 },
				{ path = "stats.kills", name = "Kills", order = 1 },
				{ path = "stats.ratio", name = "Ratio" },
			})
			local player = server:join(1)
			universe.clock:advance(1)
			local _, order = shown(server, player)
			expect(order).toEqual({ "Kills", "Coins", "Rank", "Ratio" })
		end)

		it("goes away when the player leaves and the profile is released", function()
			Polish._reset()
			local universe = Universe.new()
			local server = universe:server()
			local PlayerData = make(server, { { path = "coins", name = "Coins" } })
			local player = server:join(1)
			universe.clock:advance(1)
			local profile = PlayerData.store:get(PlayerData.store:keyForUser(1))
			expect(server.playerList:count()).toBe(1)
			server:leave(1)
			universe.clock:advance(5)
			expect(server.playerList:read(player)).toBeNil()
			expect(server.playerList:count()).toBe(0)
			-- the observer went with it
			expect(profile:state()).toBe("released")
		end)

		it("is never made for a player who left while their data loaded", function()
			Polish._reset()
			local universe = Universe.new()
			local server = universe:server()
			-- the load hangs long enough for the player to leave first
			server:inject({ method = "update", fault = { latency = 10 }, times = 1 })
			local PlayerData = make(server, { { path = "coins", name = "Coins" } })
			local player = server:join(1)
			universe.clock:advance(1)
			server:leave(1)
			universe.clock:advance(30)
			expect(PlayerData:isLoaded(player)).toBe(false)
			expect(server.playerList:count()).toBe(0)
			expect(PlayerData.store:openCount()).toBe(0)
		end)

		it("goes away when the session is lost", function()
			Polish._reset()
			local universe = Universe.new()
			local server = universe:server()
			local PlayerData = make(
				server,
				{ { path = "coins", name = "Coins" } },
				{ onSessionLost = "none" }
			)
			local player = server:join(1)
			universe.clock:advance(1)
			local profile = PlayerData.store:get(PlayerData.store:keyForUser(1))
			profile:_lose("another server took the session")
			expect(server.playerList:read(player)).toBeNil()
		end)

		it("adds to a folder the game made and leaves the folder", function()
			Polish._reset()
			local universe = Universe.new()
			local server = universe:server()
			make(server, { { path = "coins", name = "Coins" } })
			-- a stat of the game's own, made while the data still loads
			server:inject({ method = "update", fault = { latency = 0.5 }, times = 1 })
			local player = server:join(1)
			local own = server.playerList:attach(player, { { name = "Wins", kind = "IntValue" } })
			universe.clock:advance(1)
			local _, order = shown(server, player)
			expect(order).toEqual({ "Wins", "Coins" })
			server:leave(1)
			universe.clock:advance(5)
			local _, after = shown(server, player)
			expect(after).toEqual({ "Wins" })
			own:destroy()
		end)

		it("reports a value it can't show once, and shows 0 or empty text", function()
			Polish._reset()
			local universe = Universe.new()
			local server = universe:server()
			local PlayerData, reported = make(server, {
				{ path = "coins", name = "Coins" },
				{ path = "rank", name = "Rank" },
				{
					path = "stats.kills",
					name = "Kills",
					format = function(): string
						error("no")
					end,
				},
			})
			local first = server:join(1)
			local second = server:join(2)
			universe.clock:advance(1)
			for _, userId in { 1, 2 } do
				local handle = PlayerData:get(if userId == 1 then first else second)
				handle:set("coins", 2.5)
				handle:set("rank", 7)
			end
			local values = shown(server, first) :: { [string]: Any }
			expect(values.Coins).toBe(2)
			expect(values.Rank).toBe("")
			expect(values.Kills).toBe("")
			local count = 0
			for _, message in reported do
				if string.find(message, "leaderstat", 1, true) then
					count += 1
				end
			end
			-- one for each stat, however many players hit it
			expect(count).toBe(3)
		end)

		it("refuses stats it can't show at setup", function()
			Polish._reset()
			local server = Universe.new():server()
			expect(function()
				make(server, { { path = "inventory", name = "Items" } })
			end).toThrow("needs a format")
			expect(function()
				make(server, { { path = "gems", name = "Gems" } })
			end).toThrow("needs a format")
			expect(function()
				make(
					server,
					{ { path = "coins", name = "Coins" }, { path = "rank", name = "Coins" } }
				)
			end).toThrow("two leaderstats")
			expect(function()
				make(server, { { path = "coins" } })
			end).toThrow("needs a name")
			-- a format takes anything
			make(server, {
				{
					path = "inventory",
					name = "Items",
					format = function(value: unknown): string
						return tostring(#(value :: { unknown }))
					end,
				},
			})
		end)

		it("needs services that can make leaderstats", function()
			Polish._reset()
			local server = Universe.new():server()
			local services: { [string]: Any } = table.clone(server :: Any)
			services.leaderstats = nil
			expect(function()
				make(services :: Any, { { path = "coins", name = "Coins" } })
			end).toThrow("can't make leaderstats")
		end)
	end)
end
