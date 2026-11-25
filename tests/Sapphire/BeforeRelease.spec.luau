--!strict

-- beforeRelease: one system transaction before the final save, on every way a profile is
-- released while its session is still this server's, and never in the way of the release

local Guards = require("../../src/Obsidian/Guards")
local Helpers = require("./Helpers")
local MockClock = require("../../src/Quartz/Mock/Clock")
local Polish = require("../../src/Polish")
local Profile = require("../../src/Sapphire/Profile")
local ProfileStore = require("../../src/Sapphire/ProfileStore")
local Record = require("../../src/Sapphire/Record")
local Spec = require("../_lib/Spec")
local Transaction = require("../../src/Matrix/Transaction")
local Universe = require("../../src/Quartz/Mock/Universe")

type Any = any

type Heard = { reason: Profile.ReleaseReason, key: string, at: number }

-- A hook that stamps the reason into the data and remembers each call
local function stamping(heard: { Heard }, clock: MockClock.MockClock)
	return function(tx: Transaction.Transaction, profile: Any, reason: Profile.ReleaseReason)
		table.insert(heard, { reason = reason, key = profile.key, at = clock:now() })
		tx:set("closedBy", reason)
	end
end

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

local function storedData(universe: Universe.Universe, key: string): Any
	local record = Helpers.stored(universe, key) :: Record.Record
	return record.data
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("beforeRelease", function()
		it("writes once before the final save of an explicit release", function()
			local universe = Universe.new()
			local server = universe:server()
			local heard: { Heard } = {}
			local store = Helpers.store(server, { beforeRelease = stamping(heard, universe.clock) })
			local profile = load(universe, store, "p1")
			local sources = {}
			profile:onCommit(function(record)
				table.insert(sources, record.source.kind)
			end)
			local released = universe.clock:run(function()
				return profile:release()
			end)
			expect(released.ok).toBe(true)
			expect(#heard).toBe(1)
			expect(heard[1].reason).toBe("release")
			expect(sources).toEqual({ "system" })
			expect(storedData(universe, "p1").closedBy).toBe("release")
			-- a second release finds it released and doesn't run it again
			universe.clock:run(function()
				profile:release()
			end)
			expect(#heard).toBe(1)
		end)

		it("hears leave when a Geode.players player leaves", function()
			Polish._reset()
			local universe = Universe.new()
			local server = universe:server()
			local heard: { Heard } = {}
			local PlayerData = Polish.players({
				name = Helpers.STORE,
				template = { coins = 0 },
				services = server,
				beforeRelease = stamping(heard, universe.clock),
				reportError = function() end,
			})
			server:join(1)
			universe.clock:advance(5)
			expect(PlayerData.store:openCount()).toBe(1)
			server:leave(1)
			universe.clock:advance(5)
			expect(PlayerData.store:openCount()).toBe(0)
			expect(#heard).toBe(1)
			expect(heard[1].reason).toBe("leave")
			expect(storedData(universe, "1").closedBy).toBe("leave")
		end)

		it("hears shutdown for every profile, inside the close timeout", function()
			local universe = Universe.new()
			local server = universe:server()
			local heard: { Heard } = {}
			local store = Helpers.store(server, {
				beforeRelease = stamping(heard, universe.clock),
				closeTimeout = 25,
			})
			local count = 60
			for index = 1, count do
				load(universe, store, `p{index}`)
			end
			local started = universe.clock:now()
			server:shutdown()
			universe.clock:advance(25)
			expect(store:openCount()).toBe(0)
			expect(#heard).toBe(count)
			local latest = 0
			for _, entry in heard do
				expect(entry.reason).toBe("shutdown")
				latest = math.max(latest, entry.at - started)
			end
			expect(latest < 25).toBe(true)
			for index = 1, count do
				expect(storedData(universe, `p{index}`).closedBy).toBe("shutdown")
			end
		end)

		it("hears handoff before the kick and the final save when another server asks", function()
			local universe = Universe.new({ messagingLatency = 0.2 })
			local serverA = universe:server({ jobId = "A" })
			local serverB = universe:server({ jobId = "B" })
			serverA:join(1)
			local presentWhenHeard: boolean? = nil
			local storeA = Helpers.store(serverA, {
				handoff = true,
				stealAfter = 15,
				beforeRelease = function(
					tx: Transaction.Transaction,
					_profile: Any,
					reason: Profile.ReleaseReason
				)
					presentWhenHeard = serverA.players:isPresent(1)
					tx:set("closedBy", reason)
				end,
			})
			local storeB = Helpers.store(serverB, { handoff = true, stealAfter = 15 })
			load(universe, storeA, "1", 1)
			local profileB = load(universe, storeB, "1", 1)
			expect(presentWhenHeard).toBe(true)
			expect(serverA.players:isPresent(1)).toBe(false)
			expect(universe.kicks[1].reason).toBe(
				"Your data was opened on another server. Please rejoin."
			)
			expect(profileB:get("closedBy")).toBe("handoff")
		end)

		it("hears destroy, and the destroyed store refuses loads", function()
			local universe = Universe.new()
			local server = universe:server()
			local heard: { Heard } = {}
			local store = Helpers.store(server, { beforeRelease = stamping(heard, universe.clock) })
			load(universe, store, "p1")
			local finished = universe.clock:run(function()
				return store:destroy()
			end)
			expect(finished).toBe(1)
			expect(heard[1].reason).toBe("destroy")
			expect(storedData(universe, "p1").closedBy).toBe("destroy")
			local again = universe.clock:run(function()
				return store:load("p2")
			end)
			expect(again.ok).toBe(false)
			if not again.ok then
				expect(again.error.kind).toBe("destroyed")
			end
		end)

		it("stops listening for other servers' requests once destroyed", function()
			local universe = Universe.new()
			local server = universe:server()
			local store = Helpers.store(server, { handoff = true })
			load(universe, store, "p1")
			local function listening(): number
				local count = 0
				local topics = (universe :: Any)._shared.topics
				for _, subscription in topics[`geode_release_{Helpers.STORE}`] or {} do
					if subscription.connected then
						count += 1
					end
				end
				return count
			end
			expect(listening()).toBe(1)
			universe.clock:run(function()
				store:destroy()
			end)
			expect(listening()).toBe(0)
		end)

		it("is reported and skipped when it errors, and the release still saves", function()
			local universe = Universe.new()
			local server = universe:server()
			local store, reported = Helpers.store(server, {
				beforeRelease = function(tx: Transaction.Transaction)
					tx:set("closedBy", "half")
					error("closing values broke")
				end,
			})
			local profile = load(universe, store, "p1")
			profile:increment("coins", 3)
			local released = universe.clock:run(function()
				return profile:release()
			end)
			expect(released.ok).toBe(true)
			local data = storedData(universe, "p1")
			expect(data.coins).toBe(3)
			expect(data.closedBy).toBeNil()
			expect(string.find(reported[1], "closing values broke", 1, true) ~= nil).toBe(true)
		end)

		it("fails when it yields, without holding the release or the document", function()
			local universe = Universe.new()
			local server = universe:server()
			local resumedLater = false
			local store, reported = Helpers.store(server, {
				beforeRelease = function(tx: Transaction.Transaction)
					tx:set("closedBy", "never")
					coroutine.yield()
					resumedLater = true
				end,
			})
			local profile = load(universe, store, "p1")
			profile:increment("coins")
			local released = universe.clock:run(function()
				return profile:release()
			end)
			expect(released.ok).toBe(true)
			expect(resumedLater).toBe(false)
			expect(storedData(universe, "p1").closedBy).toBeNil()
			expect(storedData(universe, "p1").coins).toBe(1)
			expect(string.find(reported[1], "yielded", 1, true) ~= nil).toBe(true)
		end)

		it("goes through the guards, and a rejection doesn't stop the release", function()
			local universe = Universe.new()
			local server = universe:server()
			local store, reported = Helpers.store(server, {
				guards = { Guards.range("coins", { min = 0 }) },
				beforeRelease = function(tx: Transaction.Transaction)
					tx:decrement("coins", 100)
				end,
			})
			local profile = load(universe, store, "p1")
			local released = universe.clock:run(function()
				return profile:release()
			end)
			expect(released.ok).toBe(true)
			expect(storedData(universe, "p1").coins).toBe(0)
			expect(string.find(reported[1], "guard range coins", 1, true) ~= nil).toBe(true)
		end)

		it("never runs once the session is lost", function()
			local universe = Universe.new()
			local server = universe:server()
			local heard: { Heard } = {}
			local store = Helpers.store(server, { beforeRelease = stamping(heard, universe.clock) })
			local profile = load(universe, store, "p1")
			profile:_lose("taken by another server")
			local released = universe.clock:run(function()
				return profile:release()
			end)
			expect(released.ok).toBe(false)
			expect(#heard).toBe(0)
		end)

		it("runs once when a failed release is tried again", function()
			local universe = Universe.new()
			local server = universe:server()
			local heard: { Heard } = {}
			local store = Helpers.store(server, { beforeRelease = stamping(heard, universe.clock) })
			local profile = load(universe, store, "p1")
			server:inject({ method = "update", fault = { code = 500 }, times = 1 })
			local first = universe.clock:run(function()
				return profile:release()
			end)
			expect(first.ok).toBe(false)
			expect(profile:state()).toBe("active")
			local second = universe.clock:run(function()
				return profile:release("shutdown")
			end)
			expect(second.ok).toBe(true)
			expect(#heard).toBe(1)
			expect(storedData(universe, "p1").closedBy).toBe("release")
		end)

		it("refuses a beforeRelease that isn't a function, and an unknown reason", function()
			local server = Universe.new():server()
			expect(function()
				Helpers.store(server, { beforeRelease = "later" })
			end).toThrow("beforeRelease")
			local universe = Universe.new()
			local store = Helpers.store(universe:server())
			local profile = load(universe, store, "p1")
			expect(function()
				profile:release("whenever" :: any)
			end).toThrow("unknown release reason")
		end)
	end)
end
