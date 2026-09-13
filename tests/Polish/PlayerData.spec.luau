--!strict

local Helpers = require("../Sapphire/Helpers")
local Polish = require("../../src/Polish")
local Profile = require("../../src/Sapphire/Profile")
local Record = require("../../src/Sapphire/Record")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")

type Any = any

local TEMPLATE = { coins = 0, inventory = {} }

local function make(server: Universe.MockServer, extra: { [string]: any }?): (any, { string })
	local reported = {}
	local options: { [string]: any } = {
		name = Helpers.STORE,
		template = TEMPLATE,
		services = server,
		autosaveInterval = 30,
		reportError = function(message: string)
			table.insert(reported, message)
		end,
	}
	local overrides: { [string]: any } = extra or {}
	for key, value in overrides do
		options[key] = value
	end
	return Polish.players(options :: any), reported
end

local function playerOf(server: Universe.MockServer, userId: number): unknown
	for _, entry in server.players:list() do
		if entry.userId == userId then
			return entry.player
		end
	end
	error(`player {userId} isn't on the server`)
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Geode.players before data loads", function()
		it("reads the template and refuses writes", function()
			Polish._reset()
			local universe = Universe.new()
			local server = universe:server()
			-- The first load hangs, so the data stays unloaded while the test looks
			server:inject({ method = "update", fault = { latency = 10 }, times = 1 })
			local PlayerData = make(server)
			server:join(1)
			local player = playerOf(server, 1)
			local handle = PlayerData:get(player)
			expect(handle:isLoaded()).toBe(false)
			expect(PlayerData:isLoaded(player)).toBe(false)
			expect(handle:get("coins")).toBe(0)
			local write = handle:increment("coins", 5)
			expect(write.ok).toBe(false)
			if not write.ok then
				expect((string.find(write.error.message, "isn't loaded yet", 1, true))).never.toBeNil()
			end

			universe.clock:advance(11)
			expect(handle:isLoaded()).toBe(true)
			expect(handle:increment("coins", 5).ok).toBe(true)
			expect(handle:get("coins")).toBe(5)
		end)

		it("starts observers added early once the data loads", function()
			Polish._reset()
			local universe = Universe.new()
			local server = universe:server()
			server:inject({ method = "update", fault = { latency = 10 }, times = 1 })
			local PlayerData = make(server)
			server:join(1)
			local seen = {}
			PlayerData:get(playerOf(server, 1)):observe("coins", function(new: unknown)
				table.insert(seen, new)
			end)
			universe.clock:advance(11)
			PlayerData:get(playerOf(server, 1)):increment("coins", 3)
			expect(seen).toEqual({ 3 })
		end)

		it("is nil for players who aren't here", function()
			Polish._reset()
			local universe = Universe.new()
			local PlayerData = make(universe:server())
			expect(PlayerData:get({ UserId = 99 })).toBeNil()
			expect(PlayerData:isLoaded({ UserId = 99 })).toBe(false)
		end)
	end)

	describe("Geode.players lifecycle", function()
		it("loads on join, fires onLoaded and releases on leave", function()
			Polish._reset()
			local universe = Universe.new()
			local server = universe:server()
			local PlayerData = make(server)
			local loaded, released = {}, {}
			PlayerData:onLoaded(function(player: any, profile: Profile.Profile)
				table.insert(loaded, player.UserId)
				profile:increment("coins", 10)
			end)
			PlayerData:onReleased(function(player: any)
				table.insert(released, player.UserId)
			end)
			server:join(1)
			universe.clock:advance(1)
			expect(loaded).toEqual({ 1 })

			server:leave(1)
			universe.clock:advance(1)
			expect(released).toEqual({ 1 })
			local record = Helpers.stored(universe, "1") :: Record.Record
			expect((record.data :: Any).coins).toBe(10)
			expect(record.meta.lease).toBeNil()
		end)

		it("picks up players already on the server and calls late onLoaded handlers", function()
			Polish._reset()
			local universe = Universe.new()
			local server = universe:server()
			server:join(5)
			local PlayerData = make(server)
			universe.clock:advance(1)
			local calls = 0
			PlayerData:onLoaded(function()
				calls += 1
			end)
			universe.clock:advance(0)
			expect(calls).toBe(1)
		end)

		it("waitFor yields until the data loads, or gives up at the timeout", function()
			Polish._reset()
			local universe = Universe.new()
			local server = universe:server()
			server:inject({ method = "update", fault = { latency = 10 }, times = 1 })
			local PlayerData = make(server)
			server:join(1)
			local player = playerOf(server, 1)
			local early = universe.clock:run(function()
				return PlayerData:waitFor(player, 2) or false
			end)
			expect(early).toBe(false)
			local profile = universe.clock:run(function()
				return PlayerData:waitFor(player)
			end)
			expect(profile).never.toBeNil()
		end)

		it("retries a failed load, then kicks with a clear message", function()
			Polish._reset()
			local universe = Universe.new()
			local server = universe:server()
			server:inject({ method = "update", fault = { code = 403 } })
			local PlayerData, reported = make(server, { loadRetries = 2 })
			server:join(1)
			local player = playerOf(server, 1)
			local profile = universe.clock:run(function()
				return PlayerData:waitFor(player) or false
			end)
			expect(profile).toBe(false)
			universe.clock:advance(30)
			expect(#universe.kicks).toBe(1)
			expect(universe.kicks[1].reason).toBe("Couldn't load your data, please rejoin")
			expect(#reported > 0).toBe(true)
		end)

		it("retries loads that can pass on their own", function()
			Polish._reset()
			local universe = Universe.new()
			local server = universe:server()
			local PlayerData = make(server, { loadTimeout = 0 })
			-- Enough throttles to fail the first load, not the retry
			server:inject({ method = "update", fault = "throttle", times = 5 })
			server:join(1)
			universe.clock:advance(60)
			expect(PlayerData:isLoaded(playerOf(server, 1))).toBe(true)
			expect(#universe.kicks).toBe(0)
		end)

		it("releases data that finishes loading after the player left", function()
			Polish._reset()
			local universe = Universe.new()
			local server = universe:server()
			server:inject({ method = "update", fault = { latency = 5 }, times = 1 })
			local PlayerData = make(server)
			local loaded = 0
			PlayerData:onLoaded(function()
				loaded += 1
			end)
			server:join(1)
			server:leave(1)
			universe.clock:advance(10)
			expect(loaded).toBe(0)
			local record = Helpers.stored(universe, "1") :: Record.Record
			expect(record.meta.lease).toBeNil()
			expect(PlayerData.store:openCount()).toBe(0)
		end)

		it("reports a lost session through onReleased", function()
			Polish._reset()
			local universe = Universe.new()
			local server = universe:server({ jobId = "A" })
			local PlayerData = make(server, { stealAfter = 0, stealPolicy = "steal" })
			local released = 0
			PlayerData:onReleased(function()
				released += 1
			end)
			server:join(1)
			universe.clock:advance(1)
			local player = playerOf(server, 1)

			local thief = Helpers.store(universe:server({ jobId = "B" }), { stealAfter = 0 })
			universe.clock:run(function()
				return thief:load("1")
			end)
			universe.clock:advance(31)
			expect(released).toBe(1)
			expect(PlayerData:isLoaded(player)).toBe(false)
			expect(server.players:isPresent(1)).toBe(false)
		end)
	end)

	describe("Geode.players purchases", function()
		it("grants products once and answers granted after saving", function()
			Polish._reset()
			local universe = Universe.new()
			local server = universe:server()
			local PlayerData = make(server, {
				decisions = { granted = "granted", notProcessed = "notProcessed" },
				products = {
					[77] = function(tx: any)
						tx:increment("coins", 500)
					end,
				},
			})
			server:join(1)
			universe.clock:advance(1)
			local receipt = { PlayerId = 1, ProductId = 77, PurchaseId = "buy-1" }
			for _ = 1, 2 do
				local decision = universe.clock:run(function()
					return server:purchase(receipt)
				end)
				expect(decision).toBe("granted")
			end
			expect(PlayerData:get(playerOf(server, 1)):get("coins")).toBe(500)
		end)

		it("lets only one store take products", function()
			Polish._reset()
			local universe = Universe.new()
			local server = universe:server()
			make(server, { products = {} })
			expect(function()
				make(server, { name = "Other", products = {} })
			end).toThrow("only one")
		end)
	end)

	describe("Geode.setup", function()
		it("gives later stores its services and Studio mode", function()
			Polish._reset()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			Polish.setup({ services = server, studio = "scope" })
			local PlayerData = Polish.players({ name = Helpers.STORE, template = TEMPLATE } :: any)
			expect(PlayerData.store.scope).toBe("studio_global")
			Polish._reset()
		end)

		it("warns once when stores already exist", function()
			Polish._reset()
			local universe = Universe.new()
			local warnings = {}
			local report = function(message: string)
				table.insert(warnings, message)
			end
			Polish.setup({ services = universe:server(), reportError = report })
			Polish.players({ name = Helpers.STORE, template = TEMPLATE } :: any)
			Polish.setup({ services = universe:server(), reportError = report })
			Polish.setup({ services = universe:server(), reportError = report })
			expect(#warnings).toBe(1)
			Polish._reset()
		end)
	end)

	describe("Geode.players options", function()
		it("checks replicate values when the store is made", function()
			Polish._reset()
			local universe = Universe.new()
			local server = universe:server()
			expect(function()
				make(server, { replicate = { coins = "everyone" } })
			end).toThrow("must be")
			local _, reported = make(server, { name = "Other", replicate = { coins = "owner" } })
			expect(#reported).toBe(0)
		end)
	end)
end
