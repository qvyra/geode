--!strict

local GeodeClient = require("../../src/Client")
local Guards = require("../../src/Obsidian/Guards")
local Helpers = require("../Sapphire/Helpers")
local Profile = require("../../src/Sapphire/Profile")
local ProfileStore = require("../../src/Sapphire/ProfileStore")
local RemoteOps = require("../../src/Prism/RemoteOps")
local Replicator = require("../../src/Prism/Replicator")
local Schema = require("../../src/Obsidian/Schema")
local Spec = require("../_lib/Spec")
local Transaction = require("../../src/Matrix/Transaction")
local Types = require("../../src/Quartz/Types")
local Universe = require("../../src/Quartz/Mock/Universe")

local VISIBILITY = { coins = "owner", level = "public", secret = "private" }

local function load(
	universe: Universe.Universe,
	store: ProfileStore.ProfileStore,
	userId: number
): Profile.Profile
	local result = universe.clock:run(function()
		return store:load(tostring(userId), { userId = userId })
	end)
	if not result.ok then
		error(`load failed: {result.error.message}`, 2)
	end
	return result.profile
end

local function services(server: Universe.MockServer): Types.Services
	return server :: any
end

type World = {
	universe: Universe.Universe,
	server: Universe.MockServer,
	store: ProfileStore.ProfileStore,
	replicator: Replicator.Replicator,
}

local function world(): World
	local universe = Universe.new()
	local server = universe:server()
	local store = Helpers.store(server, {
		template = { coins = 0, level = 1, secret = "hidden", log = {} },
		ops = { "addCoins" },
	})
	return {
		universe = universe,
		server = server,
		store = store,
		replicator = Replicator.new(services(server), function() end),
	}
end

local opsRegistered = false
local function registerOps()
	if opsRegistered then
		return
	end
	opsRegistered = true
	Transaction.register("addCoins", function(tx: Transaction.Transaction, amount: number)
		tx:increment("coins", amount)
	end)
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("replication", function()
		it("shows owners their owner paths and everyone the public ones", function()
			local w = world()
			w.server:join(1)
			w.server:join(2)
			local mine = GeodeClient.start(w.server:client(1))
			local theirs = GeodeClient.start(w.server:client(2))
			w.replicator:track(1, load(w.universe, w.store, 1), VISIBILITY)
			w.universe.clock:advance(0.1)

			expect(mine:atom("coins"):get()).toBe(0)
			expect(mine:atom("level"):get()).toBe(1)
			expect(mine:atom("secret"):get()).toBeNil()
			expect(theirs:atom("level", 1):get()).toBe(1)
			expect(theirs:atom("coins", 1):get()).toBeNil()
		end)

		it("sends only what changed, batched once per frame", function()
			local w = world()
			w.server:join(1)
			local batches = 0
			w.server:client(1).remote(Replicator.REMOTE):onEvent(function()
				batches += 1
			end)
			local client = GeodeClient.start(w.server:client(1))
			local profile = load(w.universe, w.store, 1)
			w.replicator:track(1, profile, VISIBILITY)
			w.universe.clock:advance(0.1)
			local before = batches

			profile:increment("coins", 5)
			profile:increment("coins", 5)
			profile:set("secret", "still hidden")
			w.universe.clock:advance(0.1)
			expect(batches - before).toBe(1)
			expect(client:atom("coins"):get()).toBe(10)
		end)

		it("sends a fresh snapshot on resync and forgets untracked players", function()
			local w = world()
			w.server:join(1)
			local client = GeodeClient.start(w.server:client(1))
			w.replicator:track(1, load(w.universe, w.store, 1), VISIBILITY)
			w.universe.clock:advance(0.1)
			client:resync()
			w.universe.clock:advance(0.1)
			expect(client:atom("coins"):get()).toBe(0)

			w.replicator:untrack(1)
			w.universe.clock:advance(0.1)
			expect(client:atom("coins"):get()).toBeNil()
		end)

		it("refuses unknown visibility", function()
			expect(function()
				Replicator.parseVisibility({ coins = "friends" })
			end).toThrow("must be")
		end)
	end)

	describe("client atoms", function()
		it("notify subscribers and recompute computed atoms", function()
			local w = world()
			w.server:join(1)
			local client = GeodeClient.start(w.server:client(1))
			local profile = load(w.universe, w.store, 1)
			w.replicator:track(1, profile, VISIBILITY)
			w.universe.clock:advance(0.1)

			local seen = {}
			client:observe("coins", function(new: any)
				table.insert(seen, new)
			end)
			local coins = client:atom("coins")
			local level = client:atom("level")
			local worth = client:computed(function()
				return (coins:get() or 0) * (level:get() or 0)
			end)
			local worths = {}
			worth:subscribe(function(new: number)
				table.insert(worths, new)
			end)

			profile:increment("coins", 3)
			w.universe.clock:advance(0.1)
			profile:set("level", 2)
			w.universe.clock:advance(0.1)
			expect(seen).toEqual({ 3 })
			expect(worth:get()).toBe(6)
			expect(worths).toEqual({ 3, 6 })
		end)

		it("drive Charm atoms through the adapter", function()
			local w = world()
			w.server:join(1)
			local client = GeodeClient.start(w.server:client(1))
			local profile = load(w.universe, w.store, 1)
			w.replicator:track(1, profile, VISIBILITY)
			w.universe.clock:advance(0.1)

			-- A stand-in with Charm's shape: call with nothing to read, with a value to write
			local fakeCharm = {
				atom = function(initial: any)
					local value = initial
					return function(...: any)
						if select("#", ...) > 0 then
							value = ...
						end
						return value
					end
				end,
			}
			local coins = client:charm(fakeCharm).atom("coins")
			expect(coins()).toBe(0)
			profile:increment("coins", 9)
			w.universe.clock:advance(0.1)
			expect(coins()).toBe(9)
		end)
	end)

	describe("remote ops", function()
		it("run on the asking player's profile with a player source", function()
			registerOps()
			local w = world()
			w.server:join(1)
			local profile = load(w.universe, w.store, 1)
			local sources = {}
			profile:onCommit(function(record: any)
				table.insert(sources, record.source.userId)
			end)
			RemoteOps.define("addCoins", {
				store = w.store,
				args = { Schema.integer({ min = 1, max = 100 }) },
				services = services(w.server),
			})
			local client = GeodeClient.start(w.server:client(1))
			client:op("addCoins", 5)
			client:op("addCoins", "lots")
			client:op("addCoins", 5, "extra")
			client:op("unknownOp")
			w.universe.clock:advance(0.1)
			expect(profile:get("coins")).toBe(5)
			expect(sources).toEqual({ 1 })
		end)

		it("check the attempt limit before the arguments", function()
			registerOps()
			local w = world()
			w.server:join(1)
			local profile = load(w.universe, w.store, 1)
			RemoteOps.define("addCoins", {
				store = w.store,
				args = { Schema.integer() },
				rateLimit = { count = 3, window = 10 },
				services = services(w.server),
			})
			local outcomes = {}
			RemoteOps.onRequest(
				services(w.server),
				function(_userId: number, _name: string, outcome: string)
					table.insert(outcomes, outcome)
				end
			)
			local client = GeodeClient.start(w.server:client(1))
			client:op("addCoins", "bad")
			client:op("addCoins", "bad")
			client:op("addCoins", "bad")
			client:op("addCoins", 1)
			w.universe.clock:advance(0.1)
			expect(outcomes).toEqual({ "invalid", "invalid", "invalid", "limited" })
			expect(profile:get("coins")).toBe(0)

			w.universe.clock:advance(10)
			client:op("addCoins", 1)
			w.universe.clock:advance(0.1)
			expect(profile:get("coins")).toBe(1)
		end)

		it("kick past the limit when asked to", function()
			registerOps()
			local w = world()
			w.server:join(1)
			load(w.universe, w.store, 1)
			RemoteOps.define("addCoins", {
				store = w.store,
				args = { Schema.integer() },
				rateLimit = { count = 1, window = 10, action = "kick" },
				services = services(w.server),
			})
			local client = GeodeClient.start(w.server:client(1))
			client:op("addCoins", 1)
			client:op("addCoins", 1)
			w.universe.clock:advance(0.1)
			expect(w.server.players:isPresent(1)).toBe(false)
		end)

		it("go through the store's guards like any other write", function()
			registerOps()
			local universe = Universe.new()
			local server = universe:server()
			local store = Helpers.store(server, {
				template = { coins = 0, log = {} },
				ops = { "addCoins" },
				guards = { Guards.range("coins", { max = 10 }) },
			})
			server:join(1)
			local profile = load(universe, store, 1)
			RemoteOps.define("addCoins", {
				store = store,
				args = { Schema.integer() },
				services = services(server),
			})
			local client = GeodeClient.start(server:client(1))
			client:op("addCoins", 50)
			universe.clock:advance(0.1)
			expect(profile:get("coins")).toBe(0)
		end)
	end)
end
