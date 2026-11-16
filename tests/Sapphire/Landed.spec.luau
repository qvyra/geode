--!strict

-- Roblox doesn't promise that a failed UpdateAsync didn't write. Each scenario lets writes land and
-- then report failure, and checks that retries recognize their own earlier write instead of
-- losing the session, duplicating data or leaving a lease behind

local Helpers = require("./Helpers")
local Profile = require("../../src/Sapphire/Profile")
local ProfileStore = require("../../src/Sapphire/ProfileStore")
local Receipts = require("../../src/Sapphire/Receipts")
local Record = require("../../src/Sapphire/Record")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")

type Any = any

local function load(
	universe: Universe.Universe,
	store: ProfileStore.ProfileStore,
	key: string
): Profile.Profile
	local result = universe.clock:run(function()
		return store:load(key, { userId = tonumber(key) })
	end)
	if not result.ok then
		error(`load failed: {result.error.kind} {result.error.message}`, 2)
	end
	return result.profile
end

local function landOnce(server: Helpers.Server, code: number?)
	server:inject({
		store = Helpers.STORE,
		method = "update",
		fault = { landed = code or 304 },
		times = 1,
	})
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("writes that land but report failure", function()
		it("acquire: the retry finds its own lease and loads", function()
			local universe = Universe.new()
			local server = universe:server({ jobId = "A" })
			local store = Helpers.store(server)
			landOnce(server)
			local profile = load(universe, store, "1")
			expect(profile:isActive()).toBe(true)
			local record = Helpers.stored(universe, "1") :: Record.Record
			expect((record.meta.lease :: Record.Lease).jobId).toBe("A")
		end)

		it("acquire: a load that gives up hands back a lease that landed", function()
			local universe = Universe.new()
			local server = universe:server({ jobId = "A" })
			local store = Helpers.store(server, { loadTimeout = 0 })
			-- Every try lands and fails until the scheduler and the load both give up
			server:inject({
				store = Helpers.STORE,
				method = "update",
				fault = { landed = 501 },
				times = 5,
			})
			local result = universe.clock:run(function()
				return store:load("1")
			end)
			expect(result.ok).toBe(false)
			universe.clock:advance(60)
			local record = Helpers.stored(universe, "1") :: Record.Record
			expect(record.meta.lease).toBeNil()
		end)

		it("save: the retry continues instead of losing the session", function()
			local universe = Universe.new()
			local server = universe:server()
			local store = Helpers.store(server)
			local profile = load(universe, store, "1")
			profile:append("log", "a")
			landOnce(server, 501)
			local saved = universe.clock:run(function()
				return profile:save()
			end)
			expect(saved.ok).toBe(true)
			expect(profile:isActive()).toBe(true)
			expect(profile:isSaved()).toBe(true)
			expect(Helpers.storedLog(universe, "1")).toEqual({ "a" })

			profile:append("log", "b")
			universe.clock:run(function()
				return profile:save()
			end)
			local record = Helpers.stored(universe, "1") :: Record.Record
			expect(record.meta.revision).toBe(profile:revision())
			expect(Helpers.storedLog(universe, "1")).toEqual({ "a", "b" })
		end)

		it("autosave: renewals that land keep the session", function()
			local universe = Universe.new()
			local server = universe:server()
			local store = Helpers.store(server, { autosaveInterval = 10 })
			local profile = load(universe, store, "1")
			for index = 1, 4 do
				profile:append("log", `e{index}`)
				landOnce(server)
				universe.clock:advance(10)
			end
			expect(profile:isActive()).toBe(true)
			expect(Helpers.storedLog(universe, "1")).toEqual({ "e1", "e2", "e3", "e4" })
		end)

		it("release: a release that landed finishes cleanly when retried", function()
			local universe = Universe.new()
			local server = universe:server()
			local store = Helpers.store(server)
			local profile = load(universe, store, "1")
			profile:append("log", "a")
			-- Every try lands and fails, so the release reports failure with the lease already gone
			server:inject({
				store = Helpers.STORE,
				method = "update",
				fault = { landed = 501 },
				times = 5,
			})
			local first = universe.clock:run(function()
				return profile:release()
			end)
			expect(first.ok).toBe(false)
			expect(profile:isActive()).toBe(true)
			expect((Helpers.stored(universe, "1") :: Record.Record).meta.lease).toBeNil()

			local retry = universe.clock:run(function()
				return profile:release()
			end)
			expect(retry.ok).toBe(true)
			expect(profile:state()).toBe("released")
			local record = Helpers.stored(universe, "1") :: Record.Record
			expect(record.meta.lease).toBeNil()
			expect(Helpers.storedLog(universe, "1")).toEqual({ "a" })
		end)

		it("release: an autosave after a landed release takes the lease back", function()
			local universe = Universe.new()
			local server = universe:server()
			local store = Helpers.store(server, { autosaveInterval = 10 })
			local profile = load(universe, store, "1")
			server:inject({
				store = Helpers.STORE,
				method = "update",
				fault = { landed = 501 },
				times = 5,
			})
			universe.clock:run(function()
				return profile:release()
			end)
			profile:append("log", "after")
			universe.clock:advance(10)
			expect(profile:isActive()).toBe(true)
			expect(Helpers.storedLog(universe, "1")).toEqual({ "after" })
			local record = Helpers.stored(universe, "1") :: Record.Record
			expect(record.meta.lease).never.toBeNil()
		end)

		it("release: another server loading in between still wins", function()
			local universe = Universe.new()
			local serverA = universe:server({ jobId = "A" })
			local storeA = Helpers.store(serverA)
			local profileA = load(universe, storeA, "1")
			serverA:inject({
				store = Helpers.STORE,
				method = "update",
				fault = { landed = 501 },
				times = 5,
			})
			universe.clock:run(function()
				return profileA:release()
			end)
			local storeB = Helpers.store(universe:server({ jobId = "B" }))
			load(universe, storeB, "1")

			profileA:append("log", "stale")
			local saved = universe.clock:run(function()
				return profileA:save()
			end)
			expect(saved.ok).toBe(false)
			expect(profileA:state()).toBe("lost")
			expect(Helpers.storedLog(universe, "1")).toEqual({})
		end)

		it("erase: a retried erase leaves one erased record", function()
			local universe = Universe.new()
			local server = universe:server()
			local store = Helpers.store(server)
			local profile = load(universe, store, "1")
			profile:append("log", "a")
			universe.clock:run(function()
				return profile:release()
			end)
			landOnce(server)
			local erased = universe.clock:run(function()
				return store:erase("1")
			end)
			expect(erased.ok).toBe(true)
			local record = Helpers.stored(universe, "1") :: Record.Record
			expect(record.data).toBeNil()
			expect(record.meta.erasedAt).never.toBeNil()
			expect(record.meta.lastSession).toBeNil()
		end)

		it("receipts: a grant whose save landed is granted once", function()
			local universe = Universe.new()
			local server = universe:server()
			local store = Helpers.store(server, { autosaveInterval = 1000, leaseTimeout = 2000 })
			local process = Receipts.build(store, {
				[1] = function(tx)
					tx:increment("coins", 100)
				end,
			}, {
				decisions = { granted = "granted", notProcessed = "notProcessed" },
				reportError = function() end,
			})
			load(universe, store, "5")
			server:inject({
				store = Helpers.STORE,
				method = "update",
				fault = { landed = 501 },
				times = 5,
			})
			local first = universe.clock:run(function()
				return process({ PlayerId = 5, ProductId = 1, PurchaseId = "p-1" })
			end)
			expect(first).toBe("notProcessed")
			local again = universe.clock:run(function()
				return process({ PlayerId = 5, ProductId = 1, PurchaseId = "p-1" })
			end)
			expect(again).toBe("granted")
			local record = Helpers.stored(universe, "5") :: Record.Record
			expect((record.data :: Any).coins).toBe(100)
			expect(record.meta.receipts).toEqual({ "p-1" })
		end)

		it("mailbox: a send that landed is queued once", function()
			local universe = Universe.new()
			local server = universe:server()
			local store = Helpers.store(server, { mailbox = true })
			server:inject({
				store = `{Helpers.STORE}_mailbox`,
				method = "update",
				fault = { landed = 304 },
				times = 1,
			})
			local sent = universe.clock:run(function()
				return store:mail("1", "increment", "coins", 5)
			end)
			expect(sent.ok).toBe(true)
			local profile = load(universe, store, "1")
			expect(profile:get("coins")).toBe(5)
		end)
	end)
end
