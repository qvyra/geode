--!strict

local Errors = require("../../src/Quartz/Errors")
local Fixture = require("./Contracts/Fixture")
local MockClock = require("../../src/Quartz/Mock/Clock")
local Scheduler = require("../../src/Quartz/Scheduler")
local Spec = require("../_lib/Spec")
local Types = require("../../src/Quartz/Types")
local Universe = require("../../src/Quartz/Mock/Universe")

local unwrap, errorKind = Fixture.unwrap, Fixture.errorKind

-- MockClock is a Clock at runtime, Luau just won't accept its concrete method types
local function asClock(clock: MockClock.MockClock): Types.Clock
	return clock :: any
end

local function fixed(value: number): () -> number
	return function()
		return value
	end
end

-- A request that takes `seconds` of virtual time and records when it ran
local function timed(
	clock: MockClock.MockClock,
	log: { string },
	name: string,
	seconds: number
): () -> Types.Result<string>
	return function()
		table.insert(log, name)
		clock:wait(seconds)
		return Errors.ok(name)
	end
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Scheduler", function()
		it("runs a request and hands back its result", function()
			local clock = MockClock.new()
			local scheduler = Scheduler.new({ clock = asClock(clock) })
			local result = clock:run(function()
				return scheduler:submit({
					priority = "read",
					run = function()
						return Errors.ok(42)
					end,
				})
			end)
			expect(unwrap(result)).toBe(42)
		end)

		it("starts waiting requests in priority order", function()
			local clock = MockClock.new()
			local scheduler = Scheduler.new({ clock = asClock(clock), maxConcurrent = 1 })
			local log = {}

			clock:spawn(function()
				scheduler:submit({ priority = "read", run = timed(clock, log, "blocker", 5) })
			end)
			for _, priority in { "background", "read", "load", "save", "release" } do
				clock:spawn(function()
					scheduler:submit({
						priority = priority :: Scheduler.Priority,
						run = timed(clock, log, priority, 1),
					})
				end)
			end
			clock:advance(20)

			expect(log).toEqual({ "blocker", "release", "save", "load", "read", "background" })
		end)

		it("keeps priority order while the budget throttles", function()
			local universe = Universe.new()
			local server = universe:server()
			local store = server.dataStore("Players")
			local clock = universe.clock
			local scheduler = Scheduler.new({ clock = server.clock, budget = server.budget })
			server:setBudget("get", 0, 1)

			local finished = {}
			for _, priority in { "background", "read", "load", "save", "release" } do
				clock:spawn(function()
					local result = scheduler:submit({
						priority = priority :: Scheduler.Priority,
						budget = "get",
						run = function()
							return store:get("p1")
						end,
					})
					unwrap(result)
					table.insert(finished, priority)
				end)
			end
			clock:advance(10)

			expect(finished).toEqual({ "release", "save", "load", "read", "background" })
		end)

		it("retries throttled requests with jittered backoff", function()
			local universe = Universe.new()
			local server = universe:server()
			local store = server.dataStore("Players")
			server:inject({ method = "get", fault = "throttle", times = 2 })
			local scheduler = Scheduler.new({ clock = server.clock, random = fixed(0.5) })

			local attempts = 0
			local finishedAt = universe.clock:run(function()
				unwrap(scheduler:submit({
					priority = "load",
					run = function()
						attempts += 1
						return store:get("p1")
					end,
				}))
				return universe.clock:now()
			end)
			expect(attempts).toBe(3)
			expect(finishedAt).toBe(1.5)
		end)

		it("caps backoff at maxDelay", function()
			local clock = MockClock.new()
			local scheduler = Scheduler.new({
				clock = asClock(clock),
				random = fixed(0.999),
				maxAttempts = 8,
				maxDelay = 4,
			})
			local attempts = 0
			local finishedAt = clock:run(function()
				scheduler:submit({
					priority = "load",
					run = function()
						attempts += 1
						if attempts < 6 then
							return Errors.fail("throttled", "busy")
						end
						return Errors.ok(true)
					end,
				})
				return clock:now()
			end)
			-- Ceilings 1, 2, 4, 4, 4 for the five retries
			expect(finishedAt < 15).toBe(true)
			expect(finishedAt > 14.9).toBe(true)
		end)

		it("gives up after maxAttempts and returns the last error", function()
			local clock = MockClock.new()
			local scheduler =
				Scheduler.new({ clock = asClock(clock), maxAttempts = 3, random = fixed(0) })
			local attempts = 0
			local result = clock:run(function()
				return scheduler:submit({
					priority = "save",
					run = function(): Types.Result<nil>
						attempts += 1
						return Errors.fail("internal", "down")
					end,
				})
			end)
			expect(attempts).toBe(3)
			expect(errorKind(result)).toBe("internal")
		end)

		it("doesn't retry errors that won't go away", function()
			local clock = MockClock.new()
			local scheduler = Scheduler.new({ clock = asClock(clock) })
			local attempts = 0
			local result = clock:run(function()
				return scheduler:submit({
					priority = "save",
					run = function(): Types.Result<nil>
						attempts += 1
						return Errors.fail("tooLarge", "too big")
					end,
				})
			end)
			expect(attempts).toBe(1)
			expect(errorKind(result)).toBe("tooLarge")
		end)

		it("turns a request that throws into an unknown error", function()
			local clock = MockClock.new()
			local scheduler = Scheduler.new({ clock = asClock(clock) })
			local result = clock:run(function()
				return scheduler:submit({
					priority = "read",
					run = function(): Types.Result<nil>
						error("bug in run")
					end,
				})
			end)
			expect(errorKind(result)).toBe("unknown")
		end)

		it("spaces writes to the same key", function()
			local clock = MockClock.new()
			local scheduler = Scheduler.new({ clock = asClock(clock), writeSpacing = 6 })
			local startedAt = {}
			for index = 1, 2 do
				clock:spawn(function()
					scheduler:submit({
						priority = "save",
						key = "dataStore/Players/p1",
						write = true,
						run = function()
							startedAt[index] = clock:now()
							return Errors.ok(true)
						end,
					})
				end)
			end
			clock:spawn(function()
				scheduler:submit({
					priority = "save",
					key = "dataStore/Players/p2",
					write = true,
					run = function()
						startedAt[3] = clock:now()
						return Errors.ok(true)
					end,
				})
			end)
			clock:advance(20)

			expect(startedAt[1]).toBe(0)
			expect(startedAt[2]).toBe(6)
			expect(startedAt[3]).toBe(0)
		end)

		it("shares one call between identical concurrent reads", function()
			local clock = MockClock.new()
			local scheduler = Scheduler.new({ clock = asClock(clock) })
			local calls = 0
			local results = {}
			local function read()
				return scheduler:submit({
					priority = "read",
					coalesce = "dataStore/Players/p1/get",
					run = function()
						calls += 1
						clock:wait(1)
						return Errors.ok(calls)
					end,
				})
			end
			for index = 1, 3 do
				clock:spawn(function()
					results[index] = unwrap(read())
				end)
			end
			clock:advance(2)
			expect(calls).toBe(1)
			expect(results).toEqual({ 1, 1, 1 })

			clock:spawn(function()
				results[4] = unwrap(read())
			end)
			clock:advance(2)
			expect(calls).toBe(2)
			expect(results[4]).toBe(2)
		end)

		it("refuses to coalesce writes", function()
			local clock = MockClock.new()
			local scheduler = Scheduler.new({ clock = asClock(clock) })
			expect(function()
				clock:run(function()
					return scheduler:submit({
						priority = "save",
						write = true,
						coalesce = "x",
						run = function()
							return Errors.ok(true)
						end,
					})
				end)
			end).toThrow("can't be coalesced")
		end)

		it("lets other budgets through while one is empty", function()
			local universe = Universe.new()
			local server = universe:server()
			local store = server.dataStore("Players")
			local scheduler = Scheduler.new({ clock = server.clock, budget = server.budget })
			server:setBudget("update", 0)

			local order = {}
			universe.clock:spawn(function()
				scheduler:submit({
					priority = "release",
					budget = "update",
					run = function()
						table.insert(order, "update")
						return Errors.ok(true)
					end,
				})
			end)
			universe.clock:spawn(function()
				unwrap(scheduler:submit({
					priority = "background",
					budget = "get",
					run = function()
						table.insert(order, "get")
						return store:get("p1")
					end,
				}))
			end)
			universe.clock:advance(3)
			expect(order).toEqual({ "get" })

			server:setBudget("update", 1)
			universe.clock:advance(2)
			expect(order).toEqual({ "get", "update" })
		end)

		it("doesn't starve background work under a steady stream of releases", function()
			local clock = MockClock.new()
			local scheduler = Scheduler.new({
				clock = asClock(clock),
				maxConcurrent = 1,
				agingInterval = 10,
			})
			local log = {}
			local backgroundDoneAt: number? = nil

			-- The stream starts first so the background request always has releases ahead of it
			clock:delay(0.1, function()
				scheduler:submit({
					priority = "background",
					run = timed(clock, log, "background", 1),
				})
				backgroundDoneAt = clock:now()
			end)
			for index = 0, 200 do
				clock:delay(index * 0.5, function()
					scheduler:submit({ priority = "release", run = timed(clock, log, "release", 1) })
				end)
			end
			clock:advance(120)

			expect(backgroundDoneAt).never.toBeNil()
			-- Four promotions at ten seconds each bring it level with the releases
			expect((backgroundDoneAt :: number) > 40).toBe(true)
			expect((backgroundDoneAt :: number) <= 43).toBe(true)
		end)

		it("reports queue stats", function()
			local clock = MockClock.new()
			local scheduler = Scheduler.new({ clock = asClock(clock), maxConcurrent = 1 })
			local log = {}
			for _, priority in { "save", "save", "read" } do
				clock:spawn(function()
					scheduler:submit({
						priority = priority :: Scheduler.Priority,
						run = timed(clock, log, priority, 1),
					})
				end)
			end
			local stats = scheduler:stats()
			expect(stats.inFlight).toBe(1)
			expect(stats.queued).toBe(2)
			expect(stats.queuedByPriority.save).toBe(1)
			expect(stats.queuedByPriority.read).toBe(1)
			clock:advance(5)
			expect(scheduler:stats().queued).toBe(0)
		end)

		it("rejects bad options and priorities", function()
			local clock = MockClock.new()
			expect(function()
				Scheduler.new({ clock = asClock(clock), maxConcurrent = 0 })
			end).toThrow("maxConcurrent")
			local scheduler = Scheduler.new({ clock = asClock(clock) })
			expect(function()
				clock:run(function()
					return scheduler:submit({
						-- not a valid Priority, the way an untyped caller might send it
						priority = "urgent" :: any,
						run = function()
							return Errors.ok(true)
						end,
					})
				end)
			end).toThrow("unknown priority")
		end)
	end)
end
