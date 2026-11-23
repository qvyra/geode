--!strict

-- prune: keys the template dropped go on load, archived first, never inside lists or kept paths,
-- and never when another server's template wrote the record

local Bus = require("../../src/Vein/Bus")
local Guards = require("../../src/Obsidian/Guards")
local Helpers = require("./Helpers")
local Profile = require("../../src/Sapphire/Profile")
local ProfileStore = require("../../src/Sapphire/ProfileStore")
local Prune = require("../../src/Sapphire/Prune")
local Record = require("../../src/Sapphire/Record")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")
local VeinBridge = require("../../src/Vein/Bridge")

type Any = any

local TEMPLATE = { coins = 0, log = {}, settings = { music = true } }

-- Writes a record holding `data` straight into the store's DataStore, as an older template left it
local function seed(universe: Universe.Universe, key: string, data: Any, meta: { [string]: Any }?)
	local writer = universe:server({ jobId = "seeder" })
	universe.clock:run(function()
		writer.dataStore(Helpers.STORE):update(key, function()
			local record = Record.new(data, universe.clock:now(), 1)
			local fields: { [string]: Any } = meta or {}
			for field, value in fields do
				(record.meta :: Any)[field] = value
			end
			return record
		end)
	end)
end

local function load(
	universe: Universe.Universe,
	store: ProfileStore.ProfileStore,
	key: string
): Profile.Profile
	local result = universe.clock:run(function()
		return store:load(key, { userId = 1001 })
	end)
	if not result.ok then
		error(`load failed: {result.error.kind} {result.error.message}`, 2)
	end
	return result.profile
end

local function release(universe: Universe.Universe, profile: Profile.Profile)
	local released = universe.clock:run(function()
		return profile:release()
	end)
	assert(released.ok, "the release failed")
end

local function archive(universe: Universe.Universe, key: string): Any
	local reader = universe:server({ jobId = "reader" })
	local found: Any = nil
	universe.clock:spawn(function()
		local result = reader.dataStore(`{Helpers.STORE}_pruned`):get(key)
		if result.ok then
			found = result.value.value
		end
	end)
	return found
end

local function stored(universe: Universe.Universe, key: string): Record.Record
	return Helpers.stored(universe, key) :: Record.Record
end

-- every pruned message while `body` runs
local function heard(body: () -> ()): { Any }
	local messages = {}
	local connection = Bus.subscribe(function(message)
		if message.type == "pruned" then
			table.insert(messages, message)
		end
	end)
	body()
	connection:disconnect()
	return messages
end

local function pruning(server: Helpers.Server, prune: { [string]: Any }, extra: { [string]: Any }?)
	local options: { [string]: Any } = { template = TEMPLATE, prune = prune }
	local given: { [string]: Any } = extra or {}
	for key, value in given do
		options[key] = value
	end
	return Helpers.store(server, options)
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("prune", function()
		it(
			"removes keys the template dropped in one system commit, after archiving them",
			function()
				local universe = Universe.new()
				seed(universe, "p1", {
					coins = 5,
					log = {},
					gems = 12,
					settings = { music = false, theme = "dark" },
				})
				local store = pruning(universe:server(), { version = 1 })
				local profile: Profile.Profile
				local messages = heard(function()
					profile = load(universe, store, "p1")
				end)

				expect(profile:get("gems")).toBeNil()
				expect(profile:get("settings.theme")).toBeNil()
				expect(profile:get("coins")).toBe(5)
				expect(profile:get("settings.music")).toBe(false)
				expect(#messages).toBe(1)
				expect(messages[1].paths).toEqual({ "gems", "settings.theme" })
				expect(messages[1].dryRun).toBe(false)
				expect(messages[1].version).toBe(1)
				expect(messages[1].store).toBe(Helpers.STORE)

				local kept = archive(universe, "p1")
				expect(#kept.entries).toBe(1)
				expect(kept.entries[1].version).toBe(1)
				local values: { Any } = {
					{ path = { "gems" }, value = 12 },
					{ path = { "settings", "theme" }, value = "dark" },
				}
				expect(kept.entries[1].values).toEqual(values)

				release(universe, profile)
				local record = stored(universe, "p1")
				expect((record.data :: Any).gems).toBeNil()
				expect(record.meta.templateVersion).toBe(1)
				expect(record.meta.templateShape).toBe(Prune.shape(TEMPLATE, {}))
			end
		)

		it("commits as the system with a prune note", function()
			local universe = Universe.new()
			seed(universe, "p1", { coins = 1, log = {}, settings = { music = true }, old = true })
			local store = pruning(universe:server(), { version = 1 })
			local commits = {}
			local connection = Bus.subscribe(function(message)
				if message.type == "profileCommitted" then
					table.insert(commits, message)
				end
			end)
			load(universe, store, "p1")
			connection:disconnect()
			expect(#commits).toBe(1)
			expect(commits[1].source).toBe("system")
			expect(commits[1].note).toBe("prune")
			expect(commits[1].paths).toEqual({ "old" })
		end)

		it("leaves lists, empty template tables, kept paths and number keys alone", function()
			local universe = Universe.new()
			seed(universe, "p1", {
				coins = 0,
				log = { "a", "b" },
				settings = { music = true, [7] = "seven" },
				bag = { sword = 1 },
				inventory = { { id = "a", stale = true } },
				legacy = { keepMe = 1, dropMe = 2 },
				notes = "hi",
			})
			local template = {
				coins = 0,
				log = {},
				settings = { music = true },
				bag = {},
				inventory = { { id = "" } },
			}
			local store = Helpers.store(universe:server(), {
				template = template,
				prune = { version = 1, keep = { "notes", { "legacy", "keepMe" } } :: { Any } },
			})
			local profile = load(universe, store, "p1")
			expect(profile:get("log")).toEqual({ "a", "b" })
			expect(profile:get("bag.sword")).toBe(1)
			expect(profile:get({ "inventory", 1, "stale" } :: { Any })).toBe(true)
			expect(profile:get({ "settings", 7 } :: { Any })).toBe("seven")
			expect(profile:get("notes")).toBe("hi")
			expect(profile:get("legacy.keepMe")).toBe(1)
			expect(profile:get("legacy.dropMe")).toBeNil()
		end)

		it("touches nothing when there's nothing to prune", function()
			local universe = Universe.new()
			local store = pruning(universe:server(), { version = 1 })
			local messages = heard(function()
				load(universe, store, "p1")
			end)
			expect(#messages).toBe(0)
			expect(archive(universe, "p1")).toBeNil()
		end)

		it("only reports on a dry run", function()
			local universe = Universe.new()
			seed(universe, "p1", { coins = 1, log = {}, settings = { music = true }, old = 3 })
			local store = pruning(universe:server(), { version = 1, dryRun = true })
			local profile: Profile.Profile
			local messages = heard(function()
				profile = load(universe, store, "p1")
			end)
			expect(profile:get("old")).toBe(3)
			expect(#messages).toBe(1)
			expect(messages[1].dryRun).toBe(true)
			expect(messages[1].paths).toEqual({ "old" })
			expect(archive(universe, "p1")).toBeNil()
		end)

		it("leaves a record alone once a server with a higher version wrote it", function()
			local universe = Universe.new()
			-- the new template added `gems`, and a new server wrote it
			local newer = { coins = 0, log = {}, settings = { music = true }, gems = 0 }
			seed(universe, "p1", { coins = 1, log = {}, settings = { music = true }, gems = 40 }, {
				templateVersion = 2,
				templateShape = Prune.shape(newer, {}),
			})
			local store = pruning(universe:server(), { version = 1 })
			local profile: Profile.Profile
			local messages = heard(function()
				profile = load(universe, store, "p1")
			end)
			expect(profile:get("gems")).toBe(40)
			expect(#messages).toBe(0)
			release(universe, profile)
			-- the older server keeps the higher mark, so the next one still holds back
			local record = stored(universe, "p1")
			expect(record.meta.templateVersion).toBe(2)
			expect(record.meta.templateShape).toBe(Prune.shape(newer, {}))
			expect((record.data :: Any).gems).toBe(40)
		end)

		it("prunes a record an older version wrote and leaves its own mark", function()
			local universe = Universe.new()
			local older = { coins = 0, log = {}, settings = { music = true }, old = 0 }
			seed(universe, "p1", { coins = 1, log = {}, settings = { music = true }, old = 9 }, {
				templateVersion = 1,
				templateShape = Prune.shape(older, {}),
			})
			local store = pruning(universe:server(), { version = 2 })
			local profile = load(universe, store, "p1")
			expect(profile:get("old")).toBeNil()
			local record = stored(universe, "p1")
			expect(record.meta.templateVersion).toBe(2)
			expect(record.meta.templateShape).toBe(Prune.shape(TEMPLATE, {}))
		end)

		it(
			"holds back and reports every load when the template changed under the same version",
			function()
				local universe = Universe.new()
				local other = { coins = 0, log = {}, settings = { music = true }, gems = 0 }
				local meta = { templateVersion = 1, templateShape = Prune.shape(other, {}) }
				local data = { coins = 1, log = {}, settings = { music = true }, gems = 40 }
				seed(universe, "p1", data, meta)
				seed(universe, "p2", data, meta)
				local store, reported = pruning(universe:server(), { version = 1 })
				local first = load(universe, store, "p1")
				local second = load(universe, store, "p2")
				expect(first:get("gems")).toBe(40)
				expect(second:get("gems")).toBe(40)
				expect(#reported).toBe(2)
				release(universe, first)
				local again = load(universe, store, "p1")
				expect(again:get("gems")).toBe(40)
				expect(#reported).toBe(3)
				for _, message in reported do
					expect((string.find(message, "same prune.version 1", 1, true))).never.toBeNil()
					expect((string.find(message, "It kept gems.", 1, true))).never.toBeNil()
				end
			end
		)

		it("keeps a newer server's version through an older server's session", function()
			local universe = Universe.new()
			local v4 = { coins = 0, log = {}, settings = { music = true }, legacy = 0 }
			local v5 = { coins = 0, log = {}, settings = { music = true }, gems = 0 }
			local newShape = Prune.shape(v5, {})
			local newer = pruning(
				universe:server({ jobId = "v5" }),
				{ version = 5 },
				{ template = v5 }
			)
			local first = load(universe, newer, "p1")
			first:increment("gems", 10)
			release(universe, first)

			-- a server still on the old template takes the profile and saves twice
			local older = pruning(
				universe:server({ jobId = "v4" }),
				{ version = 4 },
				{ template = v4 }
			)
			local middle: Profile.Profile
			local during = heard(function()
				middle = load(universe, older, "p1")
			end)
			expect(#during).toBe(0)
			expect(middle:get("gems")).toBe(10)
			middle:increment("coins", 2)
			middle:set("legacy", 7)
			universe.clock:run(function()
				return middle:save()
			end)
			expect(stored(universe, "p1").meta.templateVersion).toBe(5)
			release(universe, middle)
			local record = stored(universe, "p1")
			expect(record.meta.templateVersion).toBe(5)
			expect(record.meta.templateShape).toBe(newShape)
			expect((record.data :: Any).gems).toBe(10)
			expect((record.data :: Any).legacy).toBe(7)

			-- back on the new template, the old key goes and everything else stays
			local again = pruning(
				universe:server({ jobId = "v5b" }),
				{ version = 5 },
				{ template = v5 }
			)
			local last: Profile.Profile
			local messages = heard(function()
				last = load(universe, again, "p1")
			end)
			expect(#messages).toBe(1)
			expect(messages[1].paths).toEqual({ "legacy" })
			expect(last:get("legacy")).toBeNil()
			expect(last:get("gems")).toBe(10)
			expect(last:get("coins")).toBe(2)
			local kept = archive(universe, "p1")
			local values: { Any } = { { path = { "legacy" }, value = 7 } }
			expect(kept.entries[1].values).toEqual(values)
			release(universe, last)
			expect(stored(universe, "p1").meta.templateVersion).toBe(5)
		end)

		it(
			"prunes nothing at a version two templates both claim, however loads alternate",
			function()
				local universe = Universe.new()
				-- the new template added `gems` but kept version 1
				local added = { coins = 0, log = {}, settings = { music = true }, gems = 0 }
				local newer = pruning(
					universe:server({ jobId = "new" }),
					{ version = 1 },
					{ template = added }
				)
				local older, reported = pruning(universe:server({ jobId = "old" }), { version = 1 })
				local profile = load(universe, newer, "p1")
				profile:increment("gems", 40)
				release(universe, profile)
				local order: { Any } = { older, older, newer, newer, older }
				for _, store in order do
					local held = load(universe, store, "p1")
					expect(held:get("gems")).toBe(40)
					release(universe, held)
				end
				expect((stored(universe, "p1").data :: Any).gems).toBe(40)
				-- one report for each of the old server's three loads
				expect(#reported).toBe(3)
				-- raising the version settles it
				local fixed = pruning(
					universe:server({ jobId = "fixed" }),
					{ version = 2 },
					{ template = added }
				)
				local settled = load(universe, fixed, "p1")
				expect(settled:get("gems")).toBe(40)
				release(universe, settled)
				local record = stored(universe, "p1")
				expect(record.meta.templateVersion).toBe(2)
				expect(record.meta.templateShape).toBe(Prune.shape(added, {}))
			end
		)

		it("prunes again once a higher version saves a record that clashed", function()
			local universe = Universe.new()
			local added = { coins = 0, log = {}, settings = { music = true }, gems = 0 }
			local newer = pruning(
				universe:server({ jobId = "new" }),
				{ version = 1 },
				{ template = added }
			)
			local older = pruning(universe:server({ jobId = "old" }), { version = 1 })
			local first = load(universe, newer, "p1")
			first:increment("gems", 40)
			release(universe, first)
			release(universe, load(universe, older, "p1"))
			expect(stored(universe, "p1").meta.templateShape).toBe("clash")

			-- version 2 drops `log`, and the clash no longer holds anything back
			local v2 = { coins = 0, settings = { music = true }, gems = 0 }
			local raised, reported = pruning(
				universe:server({ jobId = "v2" }),
				{ version = 2 },
				{ template = v2 }
			)
			local profile: Profile.Profile
			local messages = heard(function()
				profile = load(universe, raised, "p1")
			end)
			expect(#messages).toBe(1)
			expect(messages[1].paths).toEqual({ "log" })
			expect(profile:get("gems")).toBe(40)
			expect(#reported).toBe(0)
			profile:set("log", {})
			release(universe, profile)
			local record = stored(universe, "p1")
			expect(record.meta.templateVersion).toBe(2)
			expect(record.meta.templateShape).toBe(Prune.shape(v2, {}))

			-- and it keeps pruning on the next load
			local again = heard(function()
				release(universe, load(universe, raised, "p1"))
			end)
			expect(#again).toBe(1)
			expect(again[1].paths).toEqual({ "log" })
			expect(#reported).toBe(0)
		end)

		it("never lowers a mark, and leaves one written by hand", function()
			local mark = { version = 3, shape = "aaaaaaaa" }
			local higher: Any = { templateVersion = 4, templateShape = "bbbbbbbb" }
			Prune.mark(higher, mark)
			expect(higher).toEqual({ templateVersion = 4, templateShape = "bbbbbbbb" })
			local byHand: Any = { templateVersion = "3", templateShape = "bbbbbbbb" }
			Prune.mark(byHand, mark)
			expect(byHand).toEqual({ templateVersion = "3", templateShape = "bbbbbbbb" })
			local lower: Any = { templateVersion = 2, templateShape = "bbbbbbbb" }
			Prune.mark(lower, mark)
			expect(lower).toEqual({ templateVersion = 3, templateShape = "aaaaaaaa" })
			local none: Any = {}
			Prune.mark(none, mark)
			expect(none).toEqual({ templateVersion = 3, templateShape = "aaaaaaaa" })
			local clash: Any = { templateVersion = 3, templateShape = "bbbbbbbb" }
			Prune.mark(clash, mark)
			expect(clash).toEqual({ templateVersion = 3, templateShape = "clash" })
			expect(Prune.verdict(clash, mark)).toBe("mismatch")
			Prune.mark(clash, { version = 4, shape = "aaaaaaaa" })
			expect(clash).toEqual({ templateVersion = 4, templateShape = "aaaaaaaa" })
		end)

		it(
			"removes nothing when the archive can't be written, and tries again next load",
			function()
				local universe = Universe.new()
				seed(universe, "p1", { coins = 1, log = {}, settings = { music = true }, old = 3 })
				local server = universe:server()
				server:inject({
					service = "dataStore",
					store = `{Helpers.STORE}_pruned`,
					method = "update",
					fault = { code = 105 },
					times = 1,
				})
				local store, reported = pruning(server, { version = 1 })
				local profile = load(universe, store, "p1")
				expect(profile:get("old")).toBe(3)
				expect(#reported).toBe(1)
				expect((string.find(reported[1], "nothing was removed", 1, true))).never.toBeNil()
				release(universe, profile)
				expect((stored(universe, "p1").data :: Any).old).toBe(3)

				local again = load(universe, store, "p1")
				expect(again:get("old")).toBeNil()
				expect(#archive(universe, "p1").entries).toBe(1)
			end
		)

		it("keeps the archive when a guard rejects the removal", function()
			local universe = Universe.new()
			seed(universe, "p1", { coins = 1, log = {}, settings = { music = true }, old = 3 })
			local store, reported = pruning(universe:server(), { version = 1 }, {
				-- old may only change along with coins, which prune never touches
				guards = { Guards.requires("old", "coins") },
			})
			local profile = load(universe, store, "p1")
			expect(profile:get("old")).toBe(3)
			expect(#reported >= 1).toBe(true)
			expect(archive(universe, "p1")).never.toBeNil()
		end)

		it("never runs when the migration fails", function()
			local universe = Universe.new()
			seed(universe, "p1", { coins = 1, log = {}, settings = { music = true }, old = 3 })
			local store = pruning(universe:server(), { version = 1 }, {
				schemaVersion = 2,
				migrations = {
					[2] = function()
						error("broken migration")
					end,
				},
			})
			local result = universe.clock:run(function()
				return store:load("p1")
			end)
			expect(result.ok).toBe(false)
			expect(archive(universe, "p1")).toBeNil()
			expect((stored(universe, "p1").data :: Any).old).toBe(3)
		end)

		it("only reports from Studio on live data, and leaves no mark", function()
			local universe = Universe.new()
			seed(universe, "p1", { coins = 1, log = {}, settings = { music = true }, old = 3 })
			local server = universe:server({ studio = true })
			local store = pruning(server, { version = 3 }, { studio = "real" })
			local profile: Profile.Profile
			local messages = heard(function()
				profile = load(universe, store, "p1")
			end)
			expect(profile:get("old")).toBe(3)
			expect(#messages).toBe(1)
			expect(messages[1].dryRun).toBe(true)
			release(universe, profile)
			expect(stored(universe, "p1").meta.templateVersion).toBeNil()
		end)

		it("erases the archive with the profile", function()
			local universe = Universe.new()
			seed(universe, "p1", { coins = 1, log = {}, settings = { music = true }, old = 3 })
			local store = pruning(universe:server(), { version = 1 })
			local profile = load(universe, store, "p1")
			release(universe, profile)
			expect(archive(universe, "p1")).never.toBeNil()
			local erased = universe.clock:run(function()
				return store:erase("p1")
			end)
			expect(erased.ok).toBe(true)
			expect(archive(universe, "p1")).toBeNil()
		end)

		it("refuses a prune option without a version or with the root kept", function()
			local server = Universe.new():server()
			expect(function()
				pruning(server, {})
			end).toThrow("prune needs a version")
			expect(function()
				pruning(server, { version = 1.5 })
			end).toThrow("prune needs a version")
			expect(function()
				pruning(server, { version = 1, keep = { "" } })
			end).toThrow("root")
			expect(function()
				pruning(server, { version = 1, dryRun = "yes" })
			end).toThrow("dryRun")
		end)

		it("is listed among the bridge's features", function()
			expect(table.find(VeinBridge.FEATURES, "prune")).never.toBeNil()
		end)
	end)

	describe("Prune.shape", function()
		it("changes with the fields and the kept paths, not the defaults", function()
			local base = Prune.shape({ coins = 0, bag = { sword = 1 } }, {})
			expect(Prune.shape({ coins = 100, bag = { sword = 5 } }, {})).toBe(base)
			expect(Prune.shape({ coins = 0, bag = { sword = 1, shield = 1 } }, {})).never.toBe(base)
			expect(Prune.shape({ coins = 0, bag = {} }, {})).never.toBe(base)
			expect(Prune.shape({ coins = 0, bag = { sword = 1 } }, { { "old" } })).never.toBe(base)
			expect(#base).toBe(8)
		end)
	end)
end
