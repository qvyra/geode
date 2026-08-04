--!strict

-- What happens to stored data on its way into a profile: migrations, reconcile, version check

local Helpers = require("./Helpers")
local ProfileStore = require("../../src/Sapphire/ProfileStore")
local Reconcile = require("../../src/Sapphire/Reconcile")
local Record = require("../../src/Sapphire/Record")
local Spec = require("../_lib/Spec")
local Transaction = require("../../src/Matrix/Transaction")
local Universe = require("../../src/Quartz/Mock/Universe")

type Any = any

local function seed(universe: Universe.Universe, key: string, data: unknown, version: number)
	local writer = universe:server({ jobId = "seed" })
	universe.clock:run(function()
		return writer.dataStore(Helpers.STORE):set(key, Record.new(data, 0, version))
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

	describe("Reconcile.fill", function()
		it("adds missing keys at any depth and keeps everything else", function()
			local filled = Reconcile.fill(
				{ coins = 5, settings = { music = false }, custom = "kept" },
				{ coins = 0, gems = 0, settings = { music = true, volume = 1 } }
			)
			expect(filled).toEqual({
				coins = 5,
				gems = 0,
				settings = { music = false, volume = 1 },
				custom = "kept",
			})
		end)

		it("leaves lists alone and fills missing data entirely", function()
			expect(Reconcile.fill({ items = { "sword" } }, { items = { "starter" } })).toEqual({
				items = { "sword" },
			})
			expect(Reconcile.fill({ items = {} }, { items = { "starter" } })).toEqual({ items = {} })
			expect(Reconcile.fill(nil, { coins = 0 })).toEqual({ coins = 0 })
		end)

		it("never replaces a value of another type", function()
			expect(Reconcile.fill({ settings = "legacy" }, { settings = { music = true } })).toEqual({
				settings = "legacy",
			})
		end)

		it("doesn't share tables with the template", function()
			local template = { nested = { a = 1 } }
			local filled = Reconcile.fill({}, template) :: Any
			expect(filled.nested == template.nested).toBe(false)
		end)
	end)

	describe("loading stored data", function()
		it("fills fields added to the template since the data was saved", function()
			local universe = Universe.new()
			seed(universe, "p1", { coins = 7 }, 1)
			local store =
				Helpers.store(universe:server(), { template = { coins = 0, gems = 3, log = {} } })
			local result = loadResult(universe, store, "p1")
			assert(result.ok, "expected a load")
			expect(result.profile:get("coins")).toBe(7)
			expect(result.profile:get("gems")).toBe(3)
		end)

		it(
			"runs migrations in order as migration transactions and saves the new version",
			function()
				local universe = Universe.new()
				seed(universe, "p1", { gold = 7 }, 1)
				local order = {}
				local store = Helpers.store(universe:server(), {
					schemaVersion = 3,
					migrations = {
						[3] = function(tx: Transaction.Transaction)
							table.insert(order, 3)
							tx:set("coins", (tx:get("coins") :: number) * 10)
						end,
						[2] = function(tx: Transaction.Transaction)
							table.insert(order, 2)
							tx:set("coins", tx:get("gold"))
							tx:remove("gold")
						end,
					},
				})
				local result = loadResult(universe, store, "p1")
				assert(result.ok, "expected a load")
				expect(order).toEqual({ 2, 3 })
				expect(result.profile:get("coins")).toBe(70)
				expect(result.profile:get("gold")).toBeNil()

				universe.clock:run(function()
					return result.profile:release()
				end)
				local record = Helpers.stored(universe, "p1") :: Record.Record
				expect(record.meta.schemaVersion).toBe(3)
				expect((record.data :: Any).coins).toBe(70)
			end
		)

		it("leaves data untouched and frees the lease when a migration fails", function()
			local universe = Universe.new()
			seed(universe, "p1", { gold = 7 }, 1)
			local store = Helpers.store(universe:server(), {
				schemaVersion = 2,
				migrations = {
					[2] = function()
						error("bad migration")
					end,
				},
			})
			local result = loadResult(universe, store, "p1")
			expect(result.ok).toBe(false)
			if not result.ok then
				expect(result.error.kind).toBe("migrationFailed")
			end
			universe.clock:advance(20)
			local record = Helpers.stored(universe, "p1") :: Record.Record
			expect(record.data).toEqual({ gold = 7 })
			expect(record.meta.schemaVersion).toBe(1)
			expect(record.meta.lease).toBeNil()
		end)

		it("refuses data saved by a newer schema version", function()
			local universe = Universe.new()
			seed(universe, "p1", { coins = 1 }, 5)
			local store = Helpers.store(universe:server(), { schemaVersion = 4 })
			local result = loadResult(universe, store, "p1")
			expect(result.ok).toBe(false)
			if not result.ok then
				expect(result.error.kind).toBe("newerData")
			end
			universe.clock:advance(20)
			expect((Helpers.stored(universe, "p1") :: Record.Record).meta.schemaVersion).toBe(5)
		end)

		it("refuses migration tables that don't fit the schema version", function()
			local universe = Universe.new()
			expect(function()
				Helpers.store(
					universe:server(),
					{ schemaVersion = 2, migrations = { [3] = function() end } }
				)
			end).toThrow("newer than schemaVersion")
			expect(function()
				Helpers.store(
					universe:server(),
					{ schemaVersion = 2, migrations = { [1] = function() end } }
				)
			end).toThrow("starting at 2")
		end)
	end)
end
