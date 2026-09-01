--!strict

local Fixture = require("../Quartz/Contracts/Fixture")
local Geode = require("../../src")
local Registry = require("../../src/Vein/Registry")
local Spec = require("../_lib/Spec")
local Types = require("../../src/Quartz/Types")
local Universe = require("../../src/Quartz/Mock/Universe")
local t = require("../../src/Obsidian/Schema")

local unwrap, errorKind = Fixture.unwrap, Fixture.errorKind

local function services(server: Universe.MockServer): Types.Services
	return server :: any
end

type Any = any

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Ephemeral wrappers", function()
		it("validate values against the schema before writing", function()
			local universe = Universe.new()
			local server = universe:server()
			local map = Geode.Ephemeral.hashMap(
				"Scores",
				{ services = services(server), schema = t.integer() }
			)
			universe.clock:run(function()
				expect(errorKind(map:set("a", 3, 60))).toBeNil()
				expect(errorKind(map:set("b", "three", 60))).toBe("invalidValue")
				expect(errorKind(map:update("a", function()
					return "nope"
				end, 60))).toBe("invalidValue")
				expect(unwrap(map:get("a"))).toBe(3)
			end)
		end)

		it("retry throttled calls", function()
			local universe = Universe.new()
			local server = universe:server()
			server:inject({ service = "sortedMap", fault = "throttle", times = 2 })
			local map = Geode.Ephemeral.sortedMap("Ladder", { services = services(server) })
			universe.clock:run(function()
				unwrap(map:set("a", 1, 60, 5))
				expect((unwrap(map:get("a")) :: Any).sortKey).toBe(5)
			end)
		end)

		it("wrap queues", function()
			local universe = Universe.new()
			local server = universe:server()
			local queue =
				Geode.Ephemeral.queue("Jobs", { services = services(server), schema = t.string() })
			universe.clock:run(function()
				unwrap(queue:add("job", 60))
				expect(errorKind(queue:add(5, 60))).toBe("invalidValue")
				local read = unwrap(queue:read({ count = 1 }))
				expect(read.items).toEqual({ "job" })
				unwrap(queue:remove(read.id :: string))
			end)
		end)

		it("register while they exist", function()
			Registry._reset()
			local universe = Universe.new()
			local map =
				Geode.Ephemeral.hashMap("Scores", { services = services(universe:server()) })
			expect(#Registry.list()).toBe(1)
			expect(Registry.list()[1].kind).toBe("hashMap")
			map:destroy()
			expect(#Registry.list()).toBe(0)
		end)
	end)

	describe("Presence", function()
		it("tells other servers where a player is and keeps the entry alive", function()
			local universe = Universe.new()
			local serverA = universe:server({ jobId = "A", placeId = 7 })
			local serverB = universe:server({ jobId = "B" })
			local presenceA =
				Geode.Presence.new({ services = services(serverA), ttl = 30, heartbeat = 10 })
			local presenceB =
				Geode.Presence.new({ services = services(serverB), ttl = 30, heartbeat = 10 })
			universe.clock:run(function()
				unwrap(presenceA:set(1))
			end)
			universe.clock:advance(100)
			universe.clock:run(function()
				local location = unwrap(presenceB:where(1)) :: Any
				expect(location.jobId).toBe("A")
				expect(location.placeId).toBe(7)
				unwrap(presenceA:clear(1))
				expect(unwrap(presenceB:where(1))).toBeNil()
			end)
			presenceA:destroy()
			presenceB:destroy()
		end)

		it("estimates heartbeats per minute", function()
			local universe = Universe.new()
			local presence =
				Geode.Presence.new({ services = services(universe:server()), heartbeat = 20 })
			universe.clock:run(function()
				presence:set(1)
				presence:set(2)
			end)
			expect(presence:estimatedCost() >= 6).toBe(true)
			presence:destroy()
		end)
	end)

	describe("Mutex", function()
		it("lets one server hold a lock at a time", function()
			local universe = Universe.new()
			local mutexA =
				Geode.Mutex.new("Boss", { services = services(universe:server()), lease = 10 })
			local mutexB =
				Geode.Mutex.new("Boss", { services = services(universe:server()), lease = 10 })
			universe.clock:run(function()
				local lockA = unwrap(mutexA:acquire("spawn")) :: Any
				expect(lockA).never.toBeNil()
				expect(unwrap(mutexB:acquire("spawn"))).toBeNil()
				expect(lockA:release()).toBe(true)
				local lockB = unwrap(mutexB:acquire("spawn")) :: Any
				expect(lockB.token > lockA.token).toBe(true)
			end)
		end)

		it("waits for a holder to let go", function()
			local universe = Universe.new()
			local mutexA =
				Geode.Mutex.new("Boss", { services = services(universe:server()), lease = 10 })
			local mutexB =
				Geode.Mutex.new("Boss", { services = services(universe:server()), lease = 10 })
			local lockA: Any = nil
			universe.clock:run(function()
				lockA = unwrap(mutexA:acquire("spawn"))
			end)
			universe.clock:delay(3, function()
				lockA:release()
			end)
			universe.clock:run(function()
				expect(unwrap(mutexB:acquire("spawn", 5))).never.toBeNil()
			end)
		end)

		it("fences off a holder whose lease ran out", function()
			local universe = Universe.new()
			local mutexA =
				Geode.Mutex.new("Boss", { services = services(universe:server()), lease = 5 })
			local mutexB =
				Geode.Mutex.new("Boss", { services = services(universe:server()), lease = 5 })
			local lockA: Any = nil
			universe.clock:run(function()
				lockA = unwrap(mutexA:acquire("spawn"))
			end)
			universe.clock:advance(6)
			universe.clock:run(function()
				local lockB = unwrap(mutexB:acquire("spawn")) :: Any
				expect(lockB.token > lockA.token).toBe(true)
				expect(lockA:renew()).toBe(false)
				expect(lockA:isHeld()).toBe(false)
				expect(lockB:renew()).toBe(true)
			end)
		end)
	end)

	describe("Counter", function()
		it("adds up increments from every server", function()
			local universe = Universe.new()
			local counters = {}
			for index = 1, 3 do
				counters[index] =
					Geode.Counter.new("Kills", { services = services(universe:server()) })
			end
			for index = 1, #counters do
				for _ = 1, 4 do
					universe.clock:spawn(function()
						counters[index]:increment("global", 2)
					end)
				end
			end
			universe.clock:advance(1)
			universe.clock:run(function()
				expect(unwrap(counters[1]:get("global"))).toBe(24)
				expect(unwrap(counters[1]:get("other"))).toBe(0)
			end)
		end)
	end)

	describe("RateLimiter", function()
		it("allows up to the limit per window, across servers", function()
			local universe = Universe.new()
			local limiterA = Geode.RateLimiter.new(
				"Trades",
				{ services = services(universe:server()), limit = 3, window = 60 }
			)
			local limiterB = Geode.RateLimiter.new(
				"Trades",
				{ services = services(universe:server()), limit = 3, window = 60 }
			)
			universe.clock:run(function()
				expect(unwrap(limiterA:allow("p1"))).toBe(true)
				expect(unwrap(limiterB:allow("p1", 2))).toBe(true)
				expect(unwrap(limiterA:allow("p1"))).toBe(false)
				expect(unwrap(limiterB:allow("p2"))).toBe(true)
			end)
			universe.clock:advance(60)
			universe.clock:run(function()
				expect(unwrap(limiterA:allow("p1"))).toBe(true)
			end)
			expect(limiterA:estimatedCost()).toBe(1)
		end)
	end)

	describe("JobQueue", function()
		it("gives each job to one server and keeps jobs nobody acknowledged", function()
			local universe = Universe.new()
			local jobsA = Geode.JobQueue.new(
				"Rewards",
				{ services = services(universe:server()), invisibilityTimeout = 10 }
			)
			local jobsB = Geode.JobQueue.new(
				"Rewards",
				{ services = services(universe:server()), invisibilityTimeout = 10 }
			)
			universe.clock:run(function()
				unwrap(jobsA:push({ userId = 1 }))
				local claim = unwrap(jobsA:claim()) :: Any
				expect(claim.jobs).toEqual({ { userId = 1 } })
				expect(unwrap(jobsB:claim())).toBeNil()
				claim:nack()
			end)
			universe.clock:advance(11)
			universe.clock:run(function()
				local claim = unwrap(jobsB:claim()) :: Any
				expect(claim).never.toBeNil()
				unwrap(claim:ack())
			end)
			universe.clock:advance(11)
			universe.clock:run(function()
				expect(unwrap(jobsA:claim())).toBeNil()
			end)
		end)
	end)
end
