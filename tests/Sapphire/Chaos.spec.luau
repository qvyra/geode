--!strict

-- Lease protocol acceptance tests. Each scenario appends uniquely named events to a log, then
-- checks the DataStore: every acknowledged event is there exactly once, and nothing a server
-- wrote after losing the session shows up at all

local Helpers = require("./Helpers")
local Profile = require("../../src/Sapphire/Profile")
local ProfileStore = require("../../src/Sapphire/ProfileStore")
local Record = require("../../src/Sapphire/Record")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")

local function load(
	universe: Universe.Universe,
	store: ProfileStore.ProfileStore,
	key: string,
	userId: number?
): Profile.Profile
	local result = universe.clock:run(function()
		return store:load(key, { userId = userId })
	end)
	if not result.ok then
		error(`load failed: {result.error.kind} {result.error.message}`, 2)
	end
	return result.profile
end

local function save(universe: Universe.Universe, profile: Profile.Profile): boolean
	return universe.clock:run(function()
		return profile:save()
	end).ok
end

local function releaseUntilDone(universe: Universe.Universe, profile: Profile.Profile)
	for _ = 1, 20 do
		local result = universe.clock:run(function()
			return profile:release()
		end)
		if result.ok then
			return
		end
	end
	error("release never succeeded")
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("chaos", function()
		it("survives a foreign steal while a save is in flight", function()
			local universe = Universe.new()
			local serverA = universe:server({ jobId = "A" })
			local serverB = universe:server({ jobId = "B" })
			local storeA = Helpers.store(serverA, { autosaveInterval = 1000, leaseTimeout = 2000 })
			local storeB = Helpers.store(serverB, { autosaveInterval = 1000, leaseTimeout = 2000 })

			local a = load(universe, storeA, "p1", 7)
			a:append("log", "a1")
			expect(save(universe, a)).toBe(true)
			a:append("log", "a2")

			-- A's next save sits in flight for 20 seconds while B steals the session
			serverA:inject({ method = "update", fault = { latency = 20 }, times = 1 })
			local aSave: Profile.SaveResult? = nil
			universe.clock:spawn(function()
				aSave = a:save()
			end)
			local b: Profile.Profile? = nil
			universe.clock:spawn(function()
				local result = storeB:load("p1")
				if result.ok then
					b = result.profile
				end
			end)
			universe.clock:advance(14)

			local thief = b :: Profile.Profile
			expect(thief).never.toBeNil()
			expect(thief:get("log")).toEqual({ "a1" })
			thief:append("log", "b1")
			expect(save(universe, thief)).toBe(true)

			universe.clock:advance(40)
			local result = aSave :: Profile.SaveResult
			expect(result.ok).toBe(false)
			if not result.ok then
				expect(result.error.kind).toBe("lost")
			end
			expect(a:state()).toBe("lost")
			expect(a:append("log", "a3").ok).toBe(false)
			expect(universe.kicks[1].userId).toBe(7)

			thief:append("log", "b2")
			releaseUntilDone(universe, thief)
			expect(Helpers.storedLog(universe, "p1")).toEqual({ "a1", "b1", "b2" })
		end)

		it("loses nothing and repeats nothing through a throttle storm", function()
			local universe = Universe.new()
			local server = universe:server({ jobId = "A" })
			server:setBudget("update", 0, 0.2)
			local store = Helpers.store(server)

			local profile = load(universe, store, "p1")
			server:inject({ method = "update", fault = "throttle", times = 12 })
			local expected = {}
			for index = 1, 40 do
				local id = `e{index}`
				universe.clock:delay(index * 3, function()
					profile:append("log", id)
				end)
				table.insert(expected, id)
			end
			universe.clock:advance(130)
			releaseUntilDone(universe, profile)

			local log = Helpers.storedLog(universe, "p1")
			expect(log).toEqual(expected)
			for id, count in Helpers.counts(log) do
				expect(`{id} x{count}`).toBe(`{id} x1`)
			end
			local record = Helpers.stored(universe, "p1") :: Record.Record
			expect(record.meta.revision).toBe(profile:revision())
			expect(record.meta.lease).toBeNil()
		end)

		it("recovers after a server crash with only acknowledged writes", function()
			local universe = Universe.new()
			local serverA = universe:server({ jobId = "A" })
			local storeA = Helpers.store(serverA)
			local storeB = Helpers.store(universe:server({ jobId = "B" }), { stealPolicy = "wait" })

			local a = load(universe, storeA, "p1")
			a:append("log", "a1")
			expect(save(universe, a)).toBe(true)
			a:append("log", "a2")
			serverA:crash()

			-- A never renews again, so its lease goes stale and B takes over without stealing
			local b = load(universe, storeB, "p1")
			expect(b:get("log")).toEqual({ "a1" })
			expect(universe.clock:now() > 60).toBe(true)

			b:append("log", "b1")
			releaseUntilDone(universe, b)
			universe.clock:advance(100)
			expect(Helpers.storedLog(universe, "p1")).toEqual({ "a1", "b1" })
		end)

		it("lands a save that was already sent before a crash exactly once", function()
			local universe = Universe.new()
			local serverA = universe:server({ jobId = "A" })
			local storeA = Helpers.store(serverA, { autosaveInterval = 1000, leaseTimeout = 2000 })
			local storeB = Helpers.store(
				universe:server({ jobId = "B" }),
				{ stealPolicy = "steal", leaseTimeout = 2000, autosaveInterval = 1000 }
			)

			local a = load(universe, storeA, "p1")
			a:append("log", "a1")
			serverA:inject({ method = "update", fault = { latency = 3 }, times = 1 })
			universe.clock:spawn(function()
				a:save()
			end)
			universe.clock:advance(7)
			serverA:crash()
			universe.clock:advance(10)

			local b = load(universe, storeB, "p1")
			b:append("log", "b1")
			releaseUntilDone(universe, b)
			local log = Helpers.storedLog(universe, "p1")
			expect(log).toEqual({ "a1", "b1" })
		end)

		it("lets only one of two servers racing for a new key hold it", function()
			local universe = Universe.new()
			local storeA = Helpers.store(universe:server({ jobId = "A" }), { stealPolicy = "fail" })
			local storeB = Helpers.store(universe:server({ jobId = "B" }), { stealPolicy = "fail" })
			local results: { ProfileStore.LoadResult } = {}
			universe.clock:spawn(function()
				results[1] = storeA:load("p1")
			end)
			universe.clock:spawn(function()
				results[2] = storeB:load("p1")
			end)
			universe.clock:advance(30)

			local winners = 0
			for _, result in results do
				if result.ok then
					winners += 1
				end
			end
			expect(#results).toBe(2)
			expect(winners).toBe(1)
		end)
	end)
end
