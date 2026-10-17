--!strict

local Document = require("../../src/Matrix/Document")
local Guards = require("../../src/Obsidian/Guards")
local SharedStore = require("../../src/Opal/SharedStore")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")

type Any = any

local function setup(guards: { Guards.Guard }, data: unknown)
	local universe = Universe.new()
	local server = universe:server()
	local kicked = {}
	local players = table.clone(server.players) :: Any
	players.kick = function(_self: Any, userId: number)
		table.insert(kicked, userId)
	end
	local set = Guards.set({
		guards = guards,
		clock = server.clock,
		players = players,
		reportError = function() end,
	})
	local doc = Document.new({ data = data, clock = server.clock, reportError = function() end })
	set:attach(doc)
	local broken = {}
	set.broken:connect(function(violation: Guards.Violation)
		table.insert(broken, violation)
	end)
	return { doc = doc, broken = broken, kicked = kicked }
end

local DRY: Document.TransactOptions = { dryRun = true }

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("dry runs", function()
		it("run the body and stages, then commit nothing", function()
			local s = setup({}, { coins = 5, gems = 1 })
			local commits = 0
			s.doc:onCommit(function()
				commits += 1
			end)
			local result = s.doc:transact(function(tx)
				tx:increment("coins", 10)
				tx:set("gems", 2)
			end, DRY) :: Any
			expect(result.ok).toBe(true)
			expect(result.record).toBeNil()
			expect(result.dryRun.paths).toEqual({ "coins", "gems" })
			expect(s.doc:get("coins")).toBe(5)
			expect(s.doc:revision()).toBe(0)
			expect(commits).toBe(0)
		end)

		it("report every violation instead of rejecting at the first", function()
			local s = setup({
				Guards.range("coins", { max = 100 }, { name = "cap" }),
				Guards.range("gems", { max = 1 }, { name = "gemCap", action = "warn" }),
			}, { coins = 0, gems = 0 })
			local result = s.doc:transact(function(tx)
				tx:set("coins", 500)
				tx:set("gems", 9)
			end, DRY) :: Any
			expect(result.ok).toBe(true)
			local names = {}
			for _, violation in result.dryRun.findings do
				table.insert(names, `{violation.guard} {violation.action}`)
			end
			expect(names).toEqual({ "cap reject", "gemCap warn" })
			expect(#s.broken).toBe(0)
		end)

		it("never count toward rate guards", function()
			local s = setup({ Guards.rate("coins", { count = 1, window = 60 }) }, { coins = 0 })
			for _ = 1, 3 do
				local result = s.doc:transact(function(tx)
					tx:increment("coins")
				end, DRY) :: Any
				expect(#result.dryRun.findings).toBe(0)
			end
			expect(s.doc:increment("coins").ok).toBe(true)
			local again = s.doc:transact(function(tx)
				tx:increment("coins")
			end, DRY) :: Any
			expect(#again.dryRun.findings).toBe(1)
		end)

		it("never kick, even for a guard whose action is kick", function()
			local s = setup(
				{ Guards.range("coins", { max = 10 }, { action = "kick" }) },
				{ coins = 0 }
			)
			local result = s.doc:transact(function(tx)
				tx:set("coins", 50)
			end, { dryRun = true, source = { kind = "player", userId = 7 } }) :: Any
			expect(result.dryRun.findings[1].action).toBe("kick")
			expect(#s.kicked).toBe(0)
			expect(#s.broken).toBe(0)
		end)

		it("still fail when the body itself fails", function()
			local s = setup({}, { coins = 0 })
			local result = s.doc:transact(function(tx)
				tx:increment("coins", 0 / 0)
			end, DRY)
			expect(result.ok).toBe(false)
		end)

		it("aren't offered by shared stores", function()
			local universe = Universe.new()
			local store = SharedStore.new({
				name = "Guilds",
				template = { bank = 0 },
				services = universe:server(),
				reportError = function() end,
			} :: Any)
			expect(function()
				store:transact("g1", function(tx)
					tx:increment("bank")
				end, DRY)
			end).toThrow("shared stores don't do dry runs")
		end)
	end)
end
