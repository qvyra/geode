--!strict

-- Mail to a profile open somewhere: the mailbox write comes first, then a ping on the handoff
-- topic, and the holder applies it. The saved cursor makes it exactly once, pings are hints

local Fixture = require("../Quartz/Contracts/Fixture")
local Helpers = require("./Helpers")
local Mailbox = require("../../src/Sapphire/Mailbox")
local Profile = require("../../src/Sapphire/Profile")
local ProfileStore = require("../../src/Sapphire/ProfileStore")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")

local unwrap = Fixture.unwrap

type Any = any

local LATENCY = 0.2
local TOPIC = `geode_release_{Helpers.STORE}`

local function store(server: Helpers.Server, extra: { [string]: Any }?): ProfileStore.ProfileStore
	local options: { [string]: Any } =
		{ mailbox = true, handoff = true, stealAfter = 15, leaseTimeout = 120 }
	local given: { [string]: Any } = extra or {}
	for key, value in given do
		options[key] = value
	end
	return (Helpers.store(server, options))
end

local function load(
	universe: Universe.Universe,
	target: ProfileStore.ProfileStore,
	key: string
): Profile.Profile
	local result = universe.clock:run(function()
		return target:load(key)
	end)
	if not result.ok then
		error(`load failed: {result.error.kind} {result.error.message}`, 2)
	end
	return result.profile
end

local function release(universe: Universe.Universe, profile: Profile.Profile)
	local result = universe.clock:run(function()
		return profile:release()
	end)
	assert(result.ok, "release failed")
end

local function send(
	universe: Universe.Universe,
	sender: ProfileStore.ProfileStore,
	op: string,
	path: string,
	value: unknown
): number
	return universe.clock:run(function()
		return unwrap(sender:mail("p1", op, path, value))
	end)
end

local function mailbox(universe: Universe.Universe): Mailbox.Box
	local reader = universe:server({ jobId = "reader" })
	local found: Mailbox.Box? = nil
	universe.clock:spawn(function()
		local result = reader.dataStore(`{Helpers.STORE}_mailbox`):get("p1", { useCache = false })
		if result.ok then
			found = Mailbox.read(result.value.value)
		end
	end)
	return found :: Mailbox.Box
end

local function storedCoins(universe: Universe.Universe): number
	local record = Helpers.stored(universe, "p1") :: Any
	return record.data.coins
end

-- counts mail pings on the store's topic from now on
local function pings(universe: Universe.Universe): { count: number }
	local counter = { count = 0 }
	local watcher = universe:server({ jobId = "watcher" })
	universe.clock:run(function()
		watcher.messaging:subscribe(TOPIC, function(data: unknown)
			if type(data) == "table" and (data :: Any).kind == "mail" then
				counter.count += 1
			end
		end)
	end)
	return counter
end

-- the coins a fresh load finds once every server has let go
local function settled(universe: Universe.Universe, holder: Profile.Profile?): number
	if holder and holder:state() == "active" then
		release(universe, holder)
	end
	local profile = load(universe, store(universe:server({ jobId = "check" })), "p1")
	local coins = profile:get("coins") :: number
	release(universe, profile)
	return coins
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("mail to a profile open elsewhere", function()
		it("reaches the holder within moments and is saved once", function()
			local universe = Universe.new({ messagingLatency = LATENCY })
			local held = load(universe, store(universe:server({ jobId = "A" })), "p1")
			local sender = store(universe:server({ jobId = "B" }))
			send(universe, sender, "increment", "coins", 5)
			universe.clock:advance(1)
			expect(held:get("coins")).toBe(5)
			expect(held:mailboxCursor()).toBe(1)
			expect(settled(universe, held)).toBe(5)
		end)

		it("trims the mailbox only after a save carried the cursor", function()
			local universe = Universe.new({ messagingLatency = LATENCY })
			local held = load(universe, store(universe:server({ jobId = "A" })), "p1")
			send(universe, store(universe:server({ jobId = "B" })), "increment", "coins", 5)
			universe.clock:advance(1)
			expect(held:get("coins")).toBe(5)
			expect(#mailbox(universe).items).toBe(1)
			universe.clock:run(function()
				return held:save()
			end)
			universe.clock:advance(1)
			expect(#mailbox(universe).items).toBe(0)
		end)

		it("applies once when the ping arrives twice", function()
			local universe = Universe.new({ messagingLatency = LATENCY })
			local held = load(universe, store(universe:server({ jobId = "A" })), "p1")
			local sender = universe:server({ jobId = "B" })
			send(universe, store(sender), "increment", "coins", 5)
			-- the same ping again, and once more while the first read is still out
			universe.clock:run(function()
				sender.messaging:publish(TOPIC, { kind = "mail", key = "p1", from = "B", seq = 1 })
			end)
			universe.clock:advance(LATENCY + 0.01)
			universe.clock:run(function()
				sender.messaging:publish(TOPIC, { kind = "mail", key = "p1", from = "B", seq = 1 })
			end)
			universe.clock:advance(2)
			expect(held:get("coins")).toBe(5)
			expect(settled(universe, held)).toBe(5)
		end)

		it("waits for the next load when the ping is lost", function()
			local universe = Universe.new({ messagingLatency = LATENCY })
			local held = load(universe, store(universe:server({ jobId = "A" })), "p1")
			local sender = universe:server({ jobId = "B" })
			sender:inject({ service = "messaging", method = "publish", fault = { code = 500 } })
			send(universe, store(sender), "increment", "coins", 5)
			universe.clock:advance(2)
			expect(held:get("coins")).toBe(0)
			expect(settled(universe, held)).toBe(5)
		end)

		it("keeps mail that lands during a release for the next load", function()
			local universe = Universe.new({ messagingLatency = LATENCY })
			local serverA = universe:server({ jobId = "A" })
			local held = load(universe, store(serverA), "p1")
			-- the final save is slow, so the ping arrives while the profile is read only
			serverA:inject({
				store = Helpers.STORE,
				method = "update",
				fault = { latency = 2 },
				times = 1,
			})
			universe.clock:spawn(function()
				held:release()
			end)
			send(universe, store(universe:server({ jobId = "B" })), "increment", "coins", 5)
			universe.clock:advance(3)
			expect(held:state()).toBe("released")
			expect(storedCoins(universe)).toBe(0)
			expect(settled(universe, nil)).toBe(5)
		end)

		it("lands once when it's sent in the middle of a hop", function()
			local universe = Universe.new({ messagingLatency = LATENCY })
			local held = load(universe, store(universe:server({ jobId = "A" })), "p1")
			local sender = store(universe:server({ jobId = "C" }))
			universe.clock:delay(0.1, function()
				unwrap(sender:mail("p1", "increment", "coins", 5))
			end)
			local moved = load(universe, store(universe:server({ jobId = "B" })), "p1")
			universe.clock:advance(2)
			expect(held:state()).toBe("released")
			expect(moved:get("coins")).toBe(5)
			expect(settled(universe, moved)).toBe(5)
		end)

		it("reaches the profile on the server it moved to", function()
			local universe = Universe.new({ messagingLatency = LATENCY })
			local first = load(universe, store(universe:server({ jobId = "A" })), "p1")
			local moved = load(universe, store(universe:server({ jobId = "B" })), "p1")
			expect(first:state()).toBe("released")
			send(universe, store(universe:server({ jobId = "C" })), "increment", "coins", 5)
			universe.clock:advance(1)
			expect(moved:get("coins")).toBe(5)
			expect(settled(universe, moved)).toBe(5)
		end)

		it("applies racing mails once each, in the order they were stored", function()
			local universe = Universe.new({ messagingLatency = LATENCY })
			local held = load(universe, store(universe:server({ jobId = "A" })), "p1")
			local senders: { Any } = {
				store(universe:server({ jobId = "B" })),
				store(universe:server({ jobId = "C" })),
				store(universe:server({ jobId = "D" })),
			}
			local stored: { [string]: number } = {}
			for index, sender in senders do
				universe.clock:spawn(function()
					stored[`m{index}`] = unwrap(sender:mail("p1", "append", "log", `m{index}`))
					unwrap(sender:mail("p1", "increment", "coins", 1))
				end)
			end
			universe.clock:advance(3)
			local expected = { "m1", "m2", "m3" }
			table.sort(expected, function(a: string, b: string): boolean
				return stored[a] < stored[b]
			end)
			expect(held:get("log")).toEqual(expected)
			expect(held:get("coins")).toBe(3)
			expect(held:mailboxCursor()).toBe(6)
			expect(settled(universe, held)).toBe(3)
		end)

		it("sends no ping and changes nothing when the mailbox write fails", function()
			local universe = Universe.new({ messagingLatency = LATENCY })
			local held = load(universe, store(universe:server({ jobId = "A" })), "p1")
			local counter = pings(universe)
			local sender = universe:server({ jobId = "B" })
			sender:inject({
				store = `{Helpers.STORE}_mailbox`,
				method = "update",
				fault = { code = 105 },
			})
			local result = universe.clock:run(function()
				return store(sender):mail("p1", "increment", "coins", 5)
			end)
			universe.clock:advance(2)
			expect(result.ok).toBe(false)
			expect(counter.count).toBe(0)
			expect(held:get("coins")).toBe(0)
			expect(settled(universe, held)).toBe(0)
		end)

		it("picks up mail heard of while the profile was still loading", function()
			local universe = Universe.new({ messagingLatency = LATENCY })
			local serverB = universe:server({ jobId = "B" })
			-- the lease write is slow, so the mailbox read is long done when the mail lands
			serverB:inject({
				store = Helpers.STORE,
				method = "update",
				fault = { latency = 2 },
				times = 1,
			})
			local sender = store(universe:server({ jobId = "C" }))
			local target = store(serverB)
			universe.clock:delay(0.5, function()
				unwrap(sender:mail("p1", "increment", "coins", 5))
			end)
			local profile = load(universe, target, "p1")
			universe.clock:advance(1)
			expect(profile:get("coins")).toBe(5)
			expect(settled(universe, profile)).toBe(5)
		end)

		it("applies again on the next load when the holder dies before saving", function()
			local universe = Universe.new({ messagingLatency = LATENCY })
			local serverA = universe:server({ jobId = "A" })
			local held = load(universe, store(serverA), "p1")
			send(universe, store(universe:server({ jobId = "B" })), "increment", "coins", 5)
			universe.clock:advance(1)
			expect(held:get("coins")).toBe(5)
			serverA:crash()
			universe.clock:advance(121)
			expect(settled(universe, nil)).toBe(5)
		end)

		it("archives a message that fails once the save that passed it lands", function()
			local universe = Universe.new({ messagingLatency = LATENCY })
			local held, reported = nil :: Profile.Profile?, {}
			local holderStore: ProfileStore.ProfileStore
			holderStore, reported = Helpers.store(
				universe:server({ jobId = "A" }),
				{ mailbox = true, handoff = true, leaseTimeout = 120 }
			)
			held = load(universe, holderStore, "p1")
			local sender = store(universe:server({ jobId = "B" }))
			send(universe, sender, "increment", "log", 1)
			send(universe, sender, "increment", "coins", 2)
			universe.clock:advance(1)
			local profile = held :: Profile.Profile
			expect(profile:get("coins")).toBe(2)
			expect(#reported).toBe(1)
			universe.clock:run(function()
				return profile:save()
			end)
			universe.clock:advance(1)
			local box = mailbox(universe)
			expect(#box.items).toBe(0)
			expect(#box.failed).toBe(1)
			expect(box.failed[1].seq).toBe(1)
		end)
	end)

	describe("mail to a profile open on the same server", function()
		it("applies before mail returns, with no ping", function()
			local universe = Universe.new({ messagingLatency = LATENCY })
			local counter = pings(universe)
			local holder = store(universe:server({ jobId = "A" }))
			local held = load(universe, holder, "p1")
			send(universe, holder, "increment", "coins", 5)
			expect(held:get("coins")).toBe(5)
			universe.clock:advance(1)
			expect(counter.count).toBe(0)
			expect(settled(universe, held)).toBe(5)
		end)

		it("reads the mailbox first when earlier mail hasn't arrived yet", function()
			local universe = Universe.new({ messagingLatency = LATENCY })
			local holder = store(universe:server({ jobId = "A" }))
			local held = load(universe, holder, "p1")
			local far = universe:server({ jobId = "B" })
			far:inject({ service = "messaging", method = "publish", fault = { code = 500 } })
			send(universe, store(far), "append", "log", "first")
			send(universe, holder, "append", "log", "second")
			universe.clock:advance(1)
			expect(held:get("log")).toEqual({ "first", "second" })
			expect(held:mailboxCursor()).toBe(2)
		end)

		it("reaches a profile another store of the same name holds", function()
			local universe = Universe.new({ messagingLatency = LATENCY })
			local server = universe:server({ jobId = "A" })
			local held = load(universe, store(server), "p1")
			send(universe, store(server), "increment", "coins", 5)
			expect(held:get("coins")).toBe(5)
		end)
	end)
end
