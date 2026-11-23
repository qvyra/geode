--!strict

-- One Studio setting for every store. The universe here stands in for live Roblox services, so
-- whatever a store opens on it is what it would have reached in a real Studio session

local Ephemeral = require("../../src/Moonstone/Ephemeral")
local Helpers = require("../Sapphire/Helpers")
local Matchmaker = require("../../src/Garnet/Matchmaker")
local Polish = require("../../src/Polish")
local Premades = require("../../src/Moonstone/Premades")
local Ranked = require("../../src/Topaz")
local SharedStore = require("../../src/Opal/SharedStore")
local Spec = require("../_lib/Spec")
local Studio = require("../../src/Quartz/Studio")
local Types = require("../../src/Quartz/Types")
local Universe = require("../../src/Quartz/Mock/Universe")
local Vein = require("../../src/Vein")
local VeinRegistry = require("../../src/Vein/Registry")

type Any = any

local PROBE = "geode_studio_access"

local function live(server: Universe.MockServer): Types.Services
	return server :: any
end

local function fresh()
	Polish._reset()
	VeinRegistry._reset()
	Vein.setBridgeEnabled(true)
end

-- Names opened on the universe, for one kind of storage
local function opened(universe: Universe.Universe, kind: string): { [string]: boolean }
	local found = {}
	for id in (universe :: Any)._shared[kind] do
		found[id] = true
	end
	return found
end

-- The server's services with the API access check counted
local function counting(server: Universe.MockServer): (Types.Services, () -> number)
	local probes = 0
	local services = table.clone(server) :: Any
	services.dataStore = function(name: string, scope: string?)
		if name == PROBE then
			probes += 1
		end
		return server.dataStore(name, scope)
	end
	return services, function()
		return probes
	end
end

local function shared(services: Any, extra: { [string]: any }?): SharedStore.SharedStore
	local options: { [string]: any } = {
		name = "Guilds",
		template = { bank = 0 },
		services = services,
		reportError = function() end,
	}
	local overrides: { [string]: any } = extra or {}
	for key, value in overrides do
		options[key] = value
	end
	return SharedStore.new(options :: any)
end

local function studioOf(server: Universe.MockServer): string
	local answer = server.tooling:request({ kind = "profiles" }) :: Any
	return answer.stores[1].studio
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Studio modes", function()
		it("uses the services it's given outside Studio, whatever the mode", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server()
			local services, probes = counting(server)
			Polish.setup({ studio = "auto" })
			local store = Helpers.store(services :: Any, { studio = "mock" })
			universe.clock:run(function()
				local loaded = store:load("p1")
				assert(loaded.ok, "load failed")
				loaded.profile:release()
			end)
			expect(Helpers.stored(universe, "p1")).never.toBeNil()
			Ephemeral.hashMap("cache", { services = services })
			expect(opened(universe, "hashMaps").cache).toBe(true)
			expect(probes()).toBe(0)
			fresh()
		end)

		it("keeps every store's data on one memory server in mock mode", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			Polish.setup({ studio = "mock" })
			local first = shared(server)
			local second = shared(server)
			universe.clock:run(function()
				expect(first:increment("guild_1", "bank", 5).ok).toBe(true)
				local read = second:get("guild_1", "bank")
				expect(read.ok and read.value).toBe(5)
			end)
			Ephemeral.hashMap("cache", { services = live(server) })
			Premades.counter("visits", { services = live(server) })
			local board = Ranked.allTime("Coins", { services = live(server) })
			Matchmaker.new({ name = "duel", placeId = 1, matchSize = 2, services = live(server) })
			universe.clock:run(function()
				expect(board:submit(1, 10).ok).toBe(true)
			end)
			expect((next(opened(universe, "dataStores")))).toBeNil()
			expect((next(opened(universe, "orderedDataStores")))).toBeNil()
			expect((next(opened(universe, "hashMaps")))).toBeNil()
			expect((next(opened(universe, "sortedMaps")))).toBeNil()
			fresh()
		end)

		it("keeps Studio apart from live servers in scope mode", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			Polish.setup({ studio = "scope" })
			local store = shared(server)
			expect(store.scope).toBe("studio_global")
			Ephemeral.hashMap("cache", { services = live(server) })
			local profiles = Helpers.store(server, { handoff = true })
			expect(profiles.scope).toBe("studio_global")
			universe.clock:run(function()
				expect(store:increment("guild_1", "bank", 1).ok).toBe(true)
				expect(profiles:load("p1").ok).toBe(true)
			end)
			local daily = Ranked.windowed("Daily", { services = live(server), window = "daily" })
			local coins = Ranked.allTime("Coins", { services = live(server) })
			universe.clock:run(function()
				expect(daily:submit(1, 10).ok).toBe(true)
				expect(coins:submit(1, 10).ok).toBe(true)
			end)
			local dataStores = opened(universe, "dataStores")
			expect(dataStores["Guilds\0studio_global"]).toBe(true)
			expect(dataStores["Guilds\0global"]).toBeNil()
			expect(opened(universe, "orderedDataStores")["Coins\0studio_global"]).toBe(true)
			expect(opened(universe, "hashMaps").studio_cache).toBe(true)
			expect(opened(universe, "hashMaps").cache).toBeNil()
			local index = daily:windowIndex()
			expect(opened(universe, "sortedMaps")[`studio_geode_rank_Daily_{index}`]).toBe(true)
			local topics = opened(universe, "topics")
			expect(topics[`studio_geode_release_{Helpers.STORE}`]).toBe(true)
			expect(topics[`geode_release_{Helpers.STORE}`]).toBeNil()
			fresh()
		end)

		it("lets a store's own mode win over Geode.setup's", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			Polish.setup({ studio = "mock" })
			Ephemeral.hashMap("live", { services = live(server), studio = "real" })
			local store = shared(server, { studio = "scope" })
			expect(opened(universe, "hashMaps").live).toBe(true)
			expect(store.scope).toBe("studio_global")
			fresh()
		end)

		it("defaults every store to mock in Studio when nothing sets a mode", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			local store = Helpers.store(server, { handoff = true })
			expect(studioOf(server)).toBe("mock")
			expect(store.scope).toBe("global")
			local guilds = shared(server)
			Ephemeral.hashMap("cache", { services = live(server) })
			Ephemeral.sortedMap("ranks", { services = live(server) })
			Ephemeral.queue("jobs", { services = live(server) })
			Premades.counter("visits", { services = live(server) })
			local board = Ranked.allTime("Coins", { services = live(server) })
			local daily = Ranked.windowed("Daily", { services = live(server), window = "daily" })
			Matchmaker.new({ name = "duel", placeId = 1, matchSize = 2, services = live(server) })
			universe.clock:run(function()
				expect(store:load("p1").ok).toBe(true)
				expect(guilds:increment("guild_1", "bank", 5).ok).toBe(true)
				expect(board:submit(1, 10).ok).toBe(true)
				expect(daily:submit(1, 10).ok).toBe(true)
			end)
			for _, kind in { "dataStores", "orderedDataStores", "hashMaps", "sortedMaps", "queues" } do
				expect((next(opened(universe, kind)))).toBeNil()
			end
			expect((next(opened(universe, "topics")))).toBeNil()
			fresh()
		end)

		it("keeps live servers on live data when nothing sets a mode", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server()
			local guilds = shared(server)
			Ephemeral.hashMap("cache", { services = live(server) })
			local board = Ranked.allTime("Coins", { services = live(server) })
			universe.clock:run(function()
				expect(guilds:increment("guild_1", "bank", 5).ok).toBe(true)
				expect(board:submit(1, 10).ok).toBe(true)
			end)
			expect(opened(universe, "dataStores")["Guilds\0global"]).toBe(true)
			expect(opened(universe, "orderedDataStores")["Coins\0global"]).toBe(true)
			expect(opened(universe, "hashMaps").cache).toBe(true)
			fresh()
		end)

		it("refuses a mode it doesn't know", function()
			fresh()
			local server = Universe.new():server({ studio = true })
			expect(function()
				Helpers.store(server, { studio = "memory" })
			end).toThrow("studio must be")
			expect(function()
				Polish.setup({ studio = "memory" :: any })
			end).toThrow("studio must be")
			expect(function()
				shared(server, { scope = "" })
			end).toThrow("scope must be")
			fresh()
		end)

		it("gives Geode.setup's scope to profile stores, shared stores and boards", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			Polish.setup({ scope = "test", studio = "scope" })
			expect(Helpers.store(server).scope).toBe("studio_test")
			expect(shared(server).scope).toBe("studio_test")
			expect(shared(server, { scope = "own" }).scope).toBe("studio_own")
			local board = Ranked.allTime("Coins", { services = live(server) })
			expect(board.scope).toBe("test")
			universe.clock:run(function()
				expect(board:submit(1, 1).ok).toBe(true)
			end)
			expect(opened(universe, "orderedDataStores")["Coins\0studio_test"]).toBe(true)
			fresh()
			local liveServer = Universe.new():server()
			Polish.setup({ scope = "test" })
			expect(Helpers.store(liveServer).scope).toBe("test")
			fresh()
		end)

		it("hands its own services back untouched, so nested stores share them", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			local report = function() end
			local memory, mode = Studio.resolve(server, "mock", report)
			expect(mode).toBe("mock")
			local again, againMode = Studio.resolve(memory, "real", report)
			expect(again).toBe(memory)
			expect(againMode).toBe("mock")
			local same = Studio.resolve(server, "mock", report)
			expect(same).toBe(memory)
			fresh()
		end)
	end)

	describe("auto", function()
		it("keeps data in memory when Studio has no API access", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			server:inject({ service = "dataStore", store = PROBE, fault = { code = 403 } })
			local services, probes = counting(server)
			local reported = {}
			universe.clock:run(function()
				Helpers.store(services :: Any, {
					studio = "auto",
					reportError = function(message: string)
						table.insert(reported, message)
					end,
				})
			end)
			expect(probes()).toBe(1)
			expect(studioOf(server)).toBe("mock")
			expect(#reported).toBe(0)
			fresh()
		end)

		it("uses a studio scope with API access, checking once for every store", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			local services, probes = counting(server)
			Polish.setup({ studio = "auto" })
			local store, guilds
			universe.clock:run(function()
				store = Helpers.store(services :: Any)
				guilds = shared(services)
				Ephemeral.hashMap("cache", { services = services })
			end)
			expect(probes()).toBe(1)
			expect(studioOf(server)).toBe("scope")
			expect(store.scope).toBe("studio_global")
			expect(guilds.scope).toBe("studio_global")
			expect(opened(universe, "hashMaps").studio_cache).toBe(true)
			fresh()
		end)

		it("makes stores created during the check wait for its answer", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			server:inject({
				service = "dataStore",
				store = PROBE,
				fault = { latency = 2 },
				times = 1,
			})
			local services, probes = counting(server)
			local scopes = {}
			for _ = 1, 3 do
				universe.clock:spawn(function()
					table.insert(scopes, shared(services, { studio = "auto" }).scope)
				end)
			end
			expect(#scopes).toBe(0)
			universe.clock:advance(3)
			expect(scopes).toEqual({ "studio_global", "studio_global", "studio_global" })
			expect(probes()).toBe(1)
			fresh()
		end)

		it("keeps data in memory when the check fails some other way, and says so", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			server:inject({ service = "dataStore", store = PROBE, fault = { code = 502 } })
			local reported = {}
			universe.clock:run(function()
				Helpers.store(server, {
					studio = "auto",
					reportError = function(message: string)
						table.insert(reported, message)
					end,
				})
			end)
			expect(studioOf(server)).toBe("mock")
			expect(string.find(reported[1], "couldn't tell", 1, true) ~= nil).toBe(true)
			fresh()
		end)

		it("doesn't check a place that was never published", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true, placeId = 0 })
			local services, probes = counting(server)
			universe.clock:run(function()
				Helpers.store(services :: Any, { studio = "auto" })
			end)
			expect(probes()).toBe(0)
			expect(studioOf(server)).toBe("mock")
			fresh()
		end)

		it("does nothing on a live server", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server()
			local services, probes = counting(server)
			local store = Helpers.store(services :: Any, { studio = "auto" })
			expect(probes()).toBe(0)
			expect(store.scope).toBe("global")
			fresh()
		end)
	end)
end
