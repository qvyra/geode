--!strict

local Fixture = require("../Quartz/Contracts/Fixture")
local Helpers = require("./Helpers")
local Mailbox = require("../../src/Sapphire/Mailbox")
local Profile = require("../../src/Sapphire/Profile")
local ProfileStore = require("../../src/Sapphire/ProfileStore")
local Record = require("../../src/Sapphire/Record")
local Registry = require("../../src/Sapphire/Registry")
local Schema = require("../../src/Obsidian/Schema")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")

type Any = any

local unwrap = Fixture.unwrap

local function load(
	universe: Universe.Universe,
	store: ProfileStore.ProfileStore,
	key: string
): Profile.Profile
	local result = universe.clock:run(function()
		return store:load(key)
	end)
	if not result.ok then
		error(`load failed: {result.error.message}`, 2)
	end
	return result.profile
end

local function release(universe: Universe.Universe, profile: Profile.Profile)
	local result = universe.clock:run(function()
		return profile:release()
	end)
	assert(result.ok, "release failed")
end

local function mailbox(universe: Universe.Universe, key: string): Mailbox.Box?
	local reader = universe:server({ jobId = "reader" })
	local found: Mailbox.Box? = nil
	universe.clock:spawn(function()
		local result = reader.dataStore(`{Helpers.STORE}_mailbox`):get(key)
		if result.ok then
			found = Mailbox.read(result.value.value)
		end
	end)
	return found
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("wipe", function()
		it("resets data to the template and keeps receipts", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server())
			local profile = load(universe, store, "p1")
			profile:increment("coins", 50)
			profile:recordReceipt("p-1")
			local result = profile:wipe()
			expect(result.ok).toBe(true)
			expect(profile:get("coins")).toBe(0)
			expect(profile:hasReceipt("p-1")).toBe(true)
		end)
	end)

	describe("erasure", function()
		it("erases stored data and the mailbox, leaving a marker", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server())
			local profile = load(universe, store, "p1")
			profile:increment("coins", 5)
			release(universe, profile)
			universe.clock:run(function()
				return unwrap(store:mail("p1", "increment", "coins", 1))
			end)

			local result = universe.clock:run(function()
				return store:erase("p1")
			end)
			expect(result.ok).toBe(true)
			local record = Helpers.stored(universe, "p1") :: Record.Record
			expect(record.data).toBeNil()
			expect(type(record.meta.erasedAt)).toBe("number")
			expect(mailbox(universe, "p1") :: Any).toEqual({ nextSeq = 1, items = {}, failed = {} })
		end)

		it(
			"makes a server still holding the profile lose its session instead of writing back",
			function()
				local universe = Universe.new()
				local holder = Helpers.store(universe:server({ jobId = "A" }))
				local eraser = Helpers.store(universe:server({ jobId = "B" }))
				local profile = load(universe, holder, "p1")
				profile:increment("coins", 99)
				universe.clock:run(function()
					return eraser:erase("p1")
				end)
				local lostReason: string? = nil
				profile.sessionLost:connect(function(reason)
					lostReason = reason
				end)
				universe.clock:advance(15)
				expect(lostReason).toBe("the profile was erased")
				expect((Helpers.stored(universe, "p1") :: Record.Record).data).toBeNil()
			end
		)

		it("starts fresh from the template when the player comes back", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server())
			local profile = load(universe, store, "p1")
			profile:increment("coins", 5)
			release(universe, profile)
			universe.clock:run(function()
				return store:erase("p1")
			end)
			expect(load(universe, store, "p1"):get("coins")).toBe(0)
		end)

		it("reports the erasure on the load that starts over, and only that one", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server())
			local profile = load(universe, store, "p1")
			release(universe, profile)
			universe.clock:advance(7)
			universe.clock:run(function()
				return store:erase("p1")
			end)
			local heard: { { unknown } } = {}
			store.erasedProfileLoaded:connect(function(key: string, erasedAt: number)
				table.insert(heard, { key :: unknown, erasedAt })
			end)

			local first = universe.clock:run(function()
				return store:load("p1")
			end)
			expect(first.ok).toBe(true)
			if not first.ok then
				return
			end
			expect(first.erasedAt).toBe(7)
			local expected: { { unknown } } = { { "p1" :: unknown, 7 } }
			expect(heard).toEqual(expected)
			release(universe, first.profile)
			local record = Helpers.stored(universe, "p1") :: Record.Record
			expect(record.meta.erasedAt).toBe(7)
			expect((record.data :: Any).coins).toBe(0)

			local second = universe.clock:run(function()
				return store:load("p1")
			end)
			expect(second.ok).toBe(true)
			if second.ok then
				expect(second.erasedAt).toBeNil()
			end
			expect(#heard).toBe(1)
		end)

		it("starts over with a schema too", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server(), {
				schema = Schema.struct({
					coins = Schema.integer(),
					log = Schema.array(Schema.string()),
				}),
			})
			local profile = load(universe, store, "p1")
			release(universe, profile)
			universe.clock:run(function()
				return store:erase("p1")
			end)
			expect(load(universe, store, "p1"):get("coins")).toBe(0)
		end)

		it("closes a profile open on this server right away", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server())
			local profile = load(universe, store, "p1")
			universe.clock:run(function()
				return store:erase("p1")
			end)
			expect(profile:state()).toBe("lost")
			expect(store:get("p1")).toBeNil()
		end)

		it("reaches every store made with the same services through Geode.erase", function()
			local universe = Universe.new()
			local server = universe:server()
			local first = Helpers.store(server, {
				userKey = function(userId: number)
					return `player_{userId}`
				end,
			})
			local second = Helpers.store(server, { name = "Settings" })
			expect(first:keyForUser(12)).toBe("player_12")
			expect(second:keyForUser(12)).toBe("12")
			release(universe, load(universe, first, "player_12"))
			release(universe, load(universe, second, "12"))

			local report = universe.clock:run(function()
				return Registry.erase(12, server)
			end)
			expect(report.erased).toBe(2)
			expect(#report.failures).toBe(0)
			expect((Helpers.stored(universe, "player_12") :: Record.Record).data).toBeNil()
		end)
	end)
end
