--!strict

-- meta.format on profile records. Records saved by 0.4.0 to 0.5.0 have none and must keep loading

local Helpers = require("./Helpers")
local ProfileStore = require("../../src/Sapphire/ProfileStore")
local Record = require("../../src/Sapphire/Record")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")

type Any = any

-- A record the way 0.5.0 left it after a release
local function oldRecord(): { [string]: Any }
	return {
		data = { coins = 7, log = { "a" } },
		meta = {
			schemaVersion = 1,
			revision = 4,
			receipts = { "p1" },
			mailboxCursor = 2,
			createdAt = 10,
			updatedAt = 20,
			lastSession = { session = "old-session", revision = 4 },
		},
	}
end

local function seed(universe: Universe.Universe, key: string, value: unknown)
	local writer = universe:server({ jobId = "seed" })
	universe.clock:run(function()
		return writer.dataStore(Helpers.STORE):set(key, value)
	end)
end

local function loadResult(
	universe: Universe.Universe,
	store: ProfileStore.ProfileStore,
	key: string
): ProfileStore.LoadResult
	return universe.clock:run(function()
		return store:load(key)
	end)
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("profile record format", function()
		it("stores new profiles with the current format", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server())
			local result = loadResult(universe, store, "1")
			assert(result.ok, "expected a load")
			local record = Helpers.stored(universe, "1") :: Record.Record
			expect(record.meta.format).toBe(Record.FORMAT)
		end)

		it("loads a record saved before meta.format existed", function()
			local universe = Universe.new()
			seed(universe, "1", oldRecord())
			local store = Helpers.store(universe:server())
			local result = loadResult(universe, store, "1")
			assert(result.ok, "expected a load")
			expect(result.profile:get("coins")).toBe(7)
			expect(result.profile:revision()).toBe(4)
		end)

		it("adds the format on the next write and keeps the rest of meta", function()
			local universe = Universe.new()
			seed(universe, "1", oldRecord())
			local store = Helpers.store(universe:server())
			local result = loadResult(universe, store, "1")
			assert(result.ok, "expected a load")
			result.profile:increment("coins", 1)
			universe.clock:run(function()
				return result.profile:release()
			end)
			local record = Helpers.stored(universe, "1") :: Record.Record
			expect(record.meta.format).toBe(Record.FORMAT)
			expect(record.meta.revision).toBe(5)
			expect(record.meta.receipts).toEqual({ "p1" })
			expect(record.meta.mailboxCursor).toBe(2)
			expect(record.meta.createdAt).toBe(10)
			expect((record.data :: Any).coins).toBe(8)
		end)

		it("loads a record that already has the format", function()
			local universe = Universe.new()
			local value = oldRecord()
			value.meta.format = Record.FORMAT
			seed(universe, "1", value)
			local store = Helpers.store(universe:server())
			local result = loadResult(universe, store, "1")
			assert(result.ok, "expected a load")
			expect(result.profile:get("coins")).toBe(7)
		end)

		it("refuses a record whose format isn't a number", function()
			local universe = Universe.new()
			local value = oldRecord()
			value.meta.format = "1"
			seed(universe, "1", value)
			local store = Helpers.store(universe:server())
			local result = loadResult(universe, store, "1")
			expect(result.ok).toBe(false)
			if not result.ok then
				expect(result.error.kind).toBe("corrupt")
			end
		end)

		it("writes the format into erased records", function()
			local universe = Universe.new()
			seed(universe, "1", oldRecord())
			local store = Helpers.store(universe:server())
			universe.clock:run(function()
				return store:erase("1")
			end)
			local record = Helpers.stored(universe, "1") :: Record.Record
			expect(record.meta.format).toBe(Record.FORMAT)
			expect(record.meta.erasedAt).never.toBeNil()
		end)
	end)
end
