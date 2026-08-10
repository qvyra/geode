--!strict

local Helpers = require("./Helpers")
local Profile = require("../../src/Sapphire/Profile")
local ProfileStore = require("../../src/Sapphire/ProfileStore")
local Receipts = require("../../src/Sapphire/Receipts")
local Record = require("../../src/Sapphire/Record")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")

type Any = any

local PRODUCT = 1001
local DECISIONS = { granted = "granted", notProcessed = "notProcessed" }

local function receiptFor(userId: number, purchaseId: string): Receipts.ReceiptInfo
	return { PlayerId = userId, ProductId = PRODUCT, PurchaseId = purchaseId }
end

local function build(store: ProfileStore.ProfileStore): (info: Receipts.ReceiptInfo) -> unknown
	return Receipts.build(store, {
		[PRODUCT] = function(tx)
			tx:increment("coins", 100)
		end,
	}, { decisions = DECISIONS, reportError = function() end })
end

local function load(
	universe: Universe.Universe,
	store: ProfileStore.ProfileStore,
	userId: number
): Profile.Profile
	local result = universe.clock:run(function()
		return store:load(tostring(userId), { userId = userId })
	end)
	if not result.ok then
		error(`load failed: {result.error.message}`, 2)
	end
	return result.profile
end

local function storedCoins(universe: Universe.Universe, userId: number): number
	local record = Helpers.stored(universe, tostring(userId)) :: Record.Record
	return (record.data :: Any).coins
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Geode.receipts", function()
		it("grants, saves and only then reports the purchase as granted", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server())
			local process = build(store)
			local profile = load(universe, store, 5)

			local decision = universe.clock:run(function()
				return process(receiptFor(5, "p-1"))
			end)
			expect(decision).toBe("granted")
			expect(profile:get("coins")).toBe(100)
			expect(storedCoins(universe, 5)).toBe(100)
			local record = Helpers.stored(universe, "5") :: Record.Record
			expect(record.meta.receipts).toEqual({ "p-1" })
		end)

		it("never grants the same purchase twice", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server())
			local process = build(store)
			local profile = load(universe, store, 5)
			for _ = 1, 4 do
				local decision = universe.clock:run(function()
					return process(receiptFor(5, "p-1"))
				end)
				expect(decision).toBe("granted")
			end
			expect(profile:get("coins")).toBe(100)
		end)

		it("waits while the player isn't loaded here or the product is unknown", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server())
			local process = build(store)
			local missing = universe.clock:run(function()
				return process(receiptFor(9, "p-1"))
			end)
			expect(missing).toBe("notProcessed")

			load(universe, store, 9)
			local unknown = universe.clock:run(function()
				return process({ PlayerId = 9, ProductId = 42, PurchaseId = "p-2" })
			end)
			expect(unknown).toBe("notProcessed")
		end)

		it("refuses a purchase whose handler throws, without granting anything", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server())
			local process = Receipts.build(store, {
				[PRODUCT] = function(tx)
					tx:increment("coins", 100)
					error("out of stock")
				end,
			}, { decisions = DECISIONS, reportError = function() end })
			local profile = load(universe, store, 5)
			local decision = universe.clock:run(function()
				return process(receiptFor(5, "p-1"))
			end)
			expect(decision).toBe("notProcessed")
			expect(profile:get("coins")).toBe(0)
			expect(profile:hasReceipt("p-1")).toBe(false)
		end)

		it("reports not processed when the save fails, then grants once on the retry", function()
			local universe = Universe.new()
			local server = universe:server()
			-- autosave out of the way so it can't eat the injected throttles
			local store = Helpers.store(server, { autosaveInterval = 1000, leaseTimeout = 2000 })
			local process = build(store)
			local profile = load(universe, store, 5)

			server:inject({ method = "update", fault = "throttle", times = 5 })
			local first = universe.clock:run(function()
				return process(receiptFor(5, "p-1"))
			end)
			expect(first).toBe("notProcessed")
			expect(profile:get("coins")).toBe(100)

			local retry = universe.clock:run(function()
				return process(receiptFor(5, "p-1"))
			end)
			expect(retry).toBe("granted")
			expect(profile:get("coins")).toBe(100)
			expect(storedCoins(universe, 5)).toBe(100)
		end)

		it("grants once when the server crashes before saving the grant", function()
			local universe = Universe.new()
			local serverA = universe:server({ jobId = "A" })
			local storeA = Helpers.store(serverA, { autosaveInterval = 1000, leaseTimeout = 2000 })
			local processA = build(storeA)
			load(universe, storeA, 5)

			-- The save hangs on the dead server, so the grant only ever existed in A's memory
			serverA:inject({ method = "update", fault = { latency = 1000 }, times = 1 })
			universe.clock:spawn(function()
				processA(receiptFor(5, "p-1"))
			end)
			serverA:crash()
			universe.clock:advance(10)
			expect(storedCoins(universe, 5)).toBe(0)

			local storeB = Helpers.store(
				universe:server({ jobId = "B" }),
				{ leaseTimeout = 2000, autosaveInterval = 1000 }
			)
			local processB = build(storeB)
			local profileB = load(universe, storeB, 5)
			local decision = universe.clock:run(function()
				return processB(receiptFor(5, "p-1"))
			end)
			expect(decision).toBe("granted")
			expect(profileB:get("coins")).toBe(100)
			expect(storedCoins(universe, 5)).toBe(100)
		end)

		it("grants once when the server crashes after saving but before answering", function()
			local universe = Universe.new()
			local serverA = universe:server({ jobId = "A" })
			local storeA = Helpers.store(serverA, { autosaveInterval = 1000, leaseTimeout = 2000 })
			local processA = build(storeA)
			load(universe, storeA, 5)
			local first = universe.clock:run(function()
				return processA(receiptFor(5, "p-1"))
			end)
			expect(first).toBe("granted")
			-- Roblox never heard the answer and will ask again, on whichever server the player is
			serverA:crash()

			local storeB = Helpers.store(
				universe:server({ jobId = "B" }),
				{ leaseTimeout = 2000, autosaveInterval = 1000 }
			)
			local processB = build(storeB)
			local profileB = load(universe, storeB, 5)
			for _ = 1, 3 do
				local decision = universe.clock:run(function()
					return processB(receiptFor(5, "p-1"))
				end)
				expect(decision).toBe("granted")
			end
			expect(profileB:get("coins")).toBe(100)
			expect(storedCoins(universe, 5)).toBe(100)
		end)

		it("keeps only the most recent purchase ids", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server(), { receiptHistory = 3 })
			local process = build(store)
			local profile = load(universe, store, 5)
			for index = 1, 5 do
				universe.clock:run(function()
					return process(receiptFor(5, `p-{index}`))
				end)
			end
			expect(profile:get("coins")).toBe(500)
			local record = Helpers.stored(universe, "5") :: Record.Record
			expect(record.meta.receipts).toEqual({ "p-3", "p-4", "p-5" })
		end)
	end)
end
