--!strict

-- apply with dryRun through the mock bridge: what an edit would change and which guards it would
-- break, with nothing committed and nothing counted

local Guards = require("../../src/Obsidian/Guards")
local Helpers = require("../Sapphire/Helpers")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")
local Vein = require("../../src/Vein")
local VeinRegistry = require("../../src/Vein/Registry")

type Any = any

local function list(...: any): { any }
	return { ... }
end

local function fresh()
	VeinRegistry._reset()
	Vein.setBridgeEnabled(true)
end

local function request(
	universe: Universe.Universe,
	server: Universe.MockServer,
	body: { [string]: any }
): Any
	return universe.clock:run(function()
		return server.tooling:request(body)
	end)
end

local function opened(universe: Universe.Universe, store: Any, key: string): Any
	local result = universe.clock:run(function()
		return store:load(key)
	end)
	assert(result.ok, "load failed")
	return result.profile
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("bridge dry runs", function()
		it("lists dryRun among the bridge's features", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			Helpers.store(server)
			local hello = server.tooling:request({ kind = "hello" }) :: Any
			expect(table.find(hello.features, "dryRun")).never.toBeNil()
		end)

		it("reports every guard an edit would break and commits nothing", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			local store = Helpers.store(server, {
				guards = {
					Guards.range("coins", { max = 100 }, { name = "coinCap" }),
					Guards.custom(function()
						return false, "looks odd"
					end, { name = "odd", action = "flag" }),
				},
			}) :: Any
			local profile = opened(universe, store, "p1")
			local broken = 0
			store.guardBroken:connect(function()
				broken += 1
			end)
			local before = profile:revision()
			local answer = request(universe, server, {
				kind = "apply",
				store = Helpers.STORE,
				key = "p1",
				op = "set",
				args = list({ "coins" }, 5000),
				note = "",
				dryRun = true,
			})
			expect(answer.ok).toBe(true)
			expect(answer.dryRun).toBe(true)
			expect(answer.wouldCommit).toBe(false)
			expect(answer.paths).toEqual({ "coins" })
			expect(#answer.violations).toBe(2)
			local cap = answer.violations[1]
			expect(cap.guard).toBe("coinCap")
			expect(cap.action).toBe("reject")
			expect(cap.before).toBe(0)
			expect(cap.after).toBe(5000)
			expect(answer.violations[2].action).toBe("flag")
			expect(profile:get("coins")).toBe(0)
			expect(profile:revision()).toBe(before)
			expect(broken).toBe(0)
		end)

		it("says an edit would commit when only warnings break", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			local store = Helpers.store(server, {
				guards = { Guards.range("coins", { max = 10 }, { action = "warn" }) },
			})
			opened(universe, store, "p1")
			local answer = request(universe, server, {
				kind = "apply",
				store = Helpers.STORE,
				key = "p1",
				op = "increment",
				args = list({ "coins" }, 50),
				dryRun = true,
			})
			expect(answer.wouldCommit).toBe(true)
			expect(#answer.violations).toBe(1)
		end)

		it("leaves rate guard counts alone", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			local store = Helpers.store(server, {
				guards = {
					Guards.rate("coins", { count = 1, window = 60 }, { skipSources = {} }),
				},
			})
			opened(universe, store, "p1")
			local function edit(dryRun: boolean): Any
				return request(universe, server, {
					kind = "apply",
					store = Helpers.STORE,
					key = "p1",
					op = "increment",
					args = list({ "coins" }, 1),
					note = "test",
					dryRun = dryRun,
				})
			end
			for _ = 1, 3 do
				expect(#edit(true).violations).toBe(0)
			end
			expect(edit(false).ok).toBe(true)
			expect(edit(true).wouldCommit).toBe(false)
		end)

		it("needs the profile open on this server", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			Helpers.store(server)
			local answer = request(universe, server, {
				kind = "apply",
				store = Helpers.STORE,
				key = "nobody",
				op = "increment",
				args = list({ "coins" }, 1),
				dryRun = true,
			})
			expect(answer.ok).toBe(false)
			expect(answer.dryRun).toBe(true)
			expect(answer.error.kind).toBe("notOpen")
		end)

		it("reports an op that fails like a real edit would", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			local store = Helpers.store(server)
			opened(universe, store, "p1")
			local answer = request(universe, server, {
				kind = "apply",
				store = Helpers.STORE,
				key = "p1",
				op = "insert",
				args = list({ "log" }, 9, "x"),
				dryRun = true,
			})
			expect(answer.ok).toBe(false)
			expect(answer.error.kind).toBe("opFailed")
		end)
	end)
end
