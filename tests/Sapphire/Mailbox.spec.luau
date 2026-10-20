--!strict

local Fixture = require("../Quartz/Contracts/Fixture")
local Helpers = require("./Helpers")
local Mailbox = require("../../src/Sapphire/Mailbox")
local Profile = require("../../src/Sapphire/Profile")
local ProfileStore = require("../../src/Sapphire/ProfileStore")
local Spec = require("../_lib/Spec")
local Transaction = require("../../src/Matrix/Transaction")
local Universe = require("../../src/Quartz/Mock/Universe")

local unwrap = Fixture.unwrap

local MAIL = { mailbox = true }

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

local opCount = 0
local function uniqueOp(handler: Transaction.OpHandler): string
	opCount += 1
	local name = `mailTestOp{opCount}`
	Transaction.register(name, handler)
	return name
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("mailbox", function()
		it("applies mail sent while the player was away, as mailbox transactions", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server(), MAIL)
			local seq = universe.clock:run(function()
				return unwrap(store:mail("p1", "increment", "coins", 25))
			end)
			expect(seq).toBe(1)
			universe.clock:run(function()
				return unwrap(store:mail("p1", "append", "log", "gift"))
			end)

			local profile = load(universe, store, "p1")
			expect(profile:get("coins")).toBe(25)
			expect(profile:get("log")).toEqual({ "gift" })
			expect(profile:mailboxCursor()).toBe(2)
			expect(profile:isSaved()).toBe(false)
		end)

		it("applies each message exactly once across loads and trims applied ones", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server(), MAIL)
			universe.clock:run(function()
				return unwrap(store:mail("p1", "increment", "coins", 10))
			end)
			release(universe, load(universe, store, "p1"))
			local again = load(universe, store, "p1")
			expect(again:get("coins")).toBe(10)
			universe.clock:advance(30)
			expect(#(mailbox(universe, "p1") :: Mailbox.Box).items).toBe(0)

			universe.clock:run(function()
				return unwrap(store:mail("p1", "increment", "coins", 5))
			end)
			release(universe, again)
			expect(load(universe, store, "p1"):get("coins")).toBe(15)
		end)

		it("reapplies mail when the session that applied it never saved", function()
			local universe = Universe.new()
			local dead = universe:server({ jobId = "A" })
			local storeA = Helpers.store(dead, MAIL)
			universe.clock:run(function()
				return unwrap(storeA:mail("p1", "increment", "coins", 10))
			end)
			load(universe, storeA, "p1")
			dead:crash()
			universe.clock:advance(61)

			local storeB = Helpers.store(universe:server({ jobId = "B" }), MAIL)
			local profile = load(universe, storeB, "p1")
			expect(profile:get("coins")).toBe(10)
		end)

		it("archives messages that fail instead of dropping them", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server(), MAIL)
			universe.clock:run(function()
				unwrap(store:mail("p1", "increment", "log", 1))
				return unwrap(store:mail("p1", "increment", "coins", 1))
			end)
			local profile = load(universe, store, "p1")
			expect(profile:get("coins")).toBe(1)
			universe.clock:advance(30)
			local box = mailbox(universe, "p1") :: Mailbox.Box
			expect(#box.failed).toBe(1)
			expect(box.failed[1].seq).toBe(1)
		end)

		it("carries custom ops the store enables", function()
			local universe = Universe.new()
			local grant = uniqueOp(function(tx, amount: number)
				tx:increment("coins", amount)
			end)
			local store = Helpers.store(universe:server(), { mailbox = true, ops = { grant } })
			universe.clock:run(function()
				return unwrap(store:mail("p1", grant, 40))
			end)
			expect(load(universe, store, "p1"):get("coins")).toBe(40)
		end)

		it("refuses ops that can't be mailed and arguments that can't be stored", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server(), MAIL)
			universe.clock:run(function()
				expect(store:mail("p1", "update", "coins").ok).toBe(false)
				expect(store:mail("p1", "notAnOp").ok).toBe(false)
				expect(store:mail("p1", "set", "coins", print).ok).toBe(false)
			end)
		end)
	end)

	describe("stores without a mailbox", function()
		it("never read one on load", function()
			local universe = Universe.new()
			local server = universe:server()
			local store, reported = Helpers.store(server)
			-- any mailbox request would hold the load up for a minute
			server:inject({ store = `{Helpers.STORE}_mailbox`, fault = { latency = 60 } })
			local started = universe.clock:now()
			load(universe, store, "p1")
			expect(universe.clock:now() - started < 1).toBe(true)
			expect(reported).toEqual({})
		end)

		it("refuse to send mail", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server())
			local sent = universe.clock:run(function()
				return store:mail("p1", "increment", "coins", 5)
			end)
			expect(sent.ok).toBe(false)
			expect(mailbox(universe, "p1")).toEqual({ nextSeq = 1, items = {}, failed = {} })
		end)

		it("leave mail they don't read for a store that does", function()
			local universe = Universe.new()
			local sender = Helpers.store(universe:server({ jobId = "A" }), MAIL)
			universe.clock:run(function()
				return unwrap(sender:mail("p1", "increment", "coins", 5))
			end)
			local plain = Helpers.store(universe:server({ jobId = "B" }))
			local first = load(universe, plain, "p1")
			expect(first:get("coins")).toBe(0)
			release(universe, first)
			expect(#(mailbox(universe, "p1") :: Mailbox.Box).items).toBe(1)

			local reader = Helpers.store(universe:server({ jobId = "C" }), MAIL)
			expect(load(universe, reader, "p1"):get("coins")).toBe(5)
		end)
	end)
end
