--!strict

-- Fast server hop acceptance tests. A hop should be bounded by the handoff path (release
-- request, the holder's release and its announcement), not by retries and the steal window.
-- With messaging and MS down, hops get slower but never lose or duplicate a write

local Helpers = require("./Helpers")
local Profile = require("../../src/Sapphire/Profile")
local ProfileStore = require("../../src/Sapphire/ProfileStore")
local Record = require("../../src/Sapphire/Record")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")

local LATENCY = 0.2

local function store(server: Helpers.Server, extra: { [string]: any }?): ProfileStore.ProfileStore
	local options: { [string]: any } = { handoff = true, stealAfter = 15, leaseTimeout = 120 }
	local overrides: { [string]: any } = extra or {}
	for key, value in overrides do
		options[key] = value
	end
	return (Helpers.store(server, options))
end

local function load(
	universe: Universe.Universe,
	target: ProfileStore.ProfileStore,
	key: string,
	userId: number?
): (Profile.Profile, number)
	local started = universe.clock:now()
	local result = universe.clock:run(function()
		return target:load(key, { userId = userId })
	end)
	if not result.ok then
		error(`load failed: {result.error.kind} {result.error.message}`, 2)
	end
	return result.profile, universe.clock:now() - started
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("server hops", function()
		it("hop when the new server asks: the holder releases and kicks the player", function()
			local universe = Universe.new({ messagingLatency = LATENCY })
			local serverA = universe:server({ jobId = "A" })
			local serverB = universe:server({ jobId = "B" })
			serverA:join(1)
			local profileA = load(universe, store(serverA), "1", 1)
			profileA:append("log", "from A")

			local profileB, took = load(universe, store(serverB), "1", 1)
			expect(took <= 3).toBe(true)
			expect(profileA:state()).toBe("released")
			expect(serverA.players:isPresent(1)).toBe(false)
			expect(profileB:get("log")).toEqual({ "from A" })
		end)

		it("is bounded by the handoff path across many hops", function()
			local universe = Universe.new({ messagingLatency = LATENCY })
			local servers = {}
			local stores = {}
			for index = 1, 4 do
				servers[index] = universe:server({ jobId = `S{index}` })
				stores[index] = store(servers[index])
			end
			local worst = 0
			local profile = load(universe, stores[1], "1")
			for hop = 1, 20 do
				profile:append("log", `hop {hop}`)
				local target = stores[hop % 4 + 1]
				local took
				profile, took = load(universe, target, "1")
				worst = math.max(worst, took)
			end
			expect(worst <= 3).toBe(true)
			universe.clock:run(function()
				return profile:release()
			end)
			universe.clock:advance(1)
			local log = Helpers.storedLog(universe, "1")
			expect(#log).toBe(20)
			for _, count in Helpers.counts(log) do
				expect(count).toBe(1)
			end
		end)

		it("wakes on the release announcement when the holder is already letting go", function()
			local universe = Universe.new({ messagingLatency = LATENCY })
			local serverA = universe:server({ jobId = "A" })
			local storeA = store(serverA)
			local profileA = load(universe, storeA, "1")
			-- A's final save is slow, so B finds the lease still held
			serverA:inject({ method = "update", fault = { latency = 4 }, times = 1 })
			universe.clock:spawn(function()
				profileA:release()
			end)
			local _, took = load(universe, store(universe:server({ jobId = "B" })), "1")
			expect(took >= 4).toBe(true)
			expect(took <= 4 + 2 * LATENCY + 0.5).toBe(true)
		end)

		it("falls back to the handoff key when messages don't arrive", function()
			local universe = Universe.new({ messagingLatency = LATENCY })
			local serverA = universe:server({ jobId = "A" })
			local serverB = universe:server({ jobId = "B" })
			local profileA = load(universe, store(serverA), "1")
			-- B can't hear anything, so only the handoff key can tell it A let go
			serverB:inject({ service = "messaging", method = "subscribe", fault = { code = 500 } })
			serverA:inject({ method = "update", fault = { latency = 4 }, times = 1 })
			universe.clock:spawn(function()
				profileA:release()
			end)
			local _, took = load(universe, store(serverB), "1")
			expect(took <= 4 + 2 + 0.5).toBe(true)
		end)

		it("stays correct with messaging and MemoryStore down", function()
			local universe = Universe.new({ messagingLatency = LATENCY })
			local serverA = universe:server({ jobId = "A" })
			local serverB = universe:server({ jobId = "B" })
			for _, server in { serverA, serverB } do
				server:inject({ service = "messaging", fault = { code = 500 } })
				server:inject({ service = "hashMap", fault = { code = 500 } })
			end
			local storeA = store(serverA, { autosaveInterval = 10 })
			local profileA = load(universe, storeA, "1")
			profileA:append("log", "saved by A")
			universe.clock:run(function()
				return profileA:save()
			end)
			-- Saved by A's autosave while B waits, so it survives
			profileA:append("log", "autosaved by A")

			local profileB, took = load(universe, store(serverB, { stealPolicy = "steal" }), "1")
			-- Nothing told B to hurry, so it waited out the steal window
			expect(took >= 15).toBe(true)
			-- A doesn't know yet. This write must never reach the DataStore
			profileA:append("log", "after the steal on A")
			universe.clock:advance(11)
			expect(profileA:state()).toBe("lost")

			profileB:append("log", "from B")
			universe.clock:run(function()
				return profileB:release()
			end)
			expect(Helpers.storedLog(universe, "1")).toEqual({
				"saved by A",
				"autosaved by A",
				"from B",
			})
			local record = Helpers.stored(universe, "1") :: Record.Record
			expect(record.meta.lease).toBeNil()
		end)

		it("ignores a late request about a session that was already replaced", function()
			local universe = Universe.new({ messagingLatency = 5 })
			local serverA = universe:server({ jobId = "A" })
			local storeA = store(serverA)
			local first = load(universe, storeA, "1")
			local storeB =
				store(universe:server({ jobId = "B" }), { stealAfter = 1, stealPolicy = "fail" })
			universe.clock:spawn(function()
				storeB:load("1")
			end)
			universe.clock:advance(0.5)
			universe.clock:run(function()
				return first:release()
			end)
			local second = load(universe, storeA, "1")
			universe.clock:advance(10)
			expect(second:isActive()).toBe(true)
		end)

		it("costs nothing until a store loads", function()
			local universe = Universe.new()
			local server = universe:server()
			server:inject({ service = "messaging", fault = { code = 500 } })
			local _, reported = Helpers.store(server, { handoff = true })
			universe.clock:advance(1)
			expect(#reported).toBe(0)
		end)
	end)
end
