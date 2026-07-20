--!strict

local Document = require("../../src/Matrix/Document")
local Guards = require("../../src/Obsidian/Guards")
local Spec = require("../_lib/Spec")
local Transaction = require("../../src/Matrix/Transaction")
local Universe = require("../../src/Quartz/Mock/Universe")
local t = require("../../src/Obsidian/Schema")

type Setup = {
	doc: Document.Document,
	set: Guards.GuardSet,
	universe: Universe.Universe,
	broken: { Guards.Violation },
	reported: { string },
}

local function setup(guards: { Guards.Guard }, data: unknown): Setup
	local universe = Universe.new()
	local server = universe:server()
	local reported = {}
	local function report(message: string)
		table.insert(reported, message)
	end
	local set = Guards.set({
		guards = guards,
		clock = server.clock,
		players = server.players,
		reportError = report,
	})
	local doc = Document.new({ data = data, clock = server.clock, reportError = report })
	set:attach(doc)
	local broken = {}
	set.broken:connect(function(violation: Guards.Violation)
		table.insert(broken, violation)
	end)
	return { doc = doc, set = set, universe = universe, broken = broken, reported = reported }
end

local function player(userId: number): Document.TransactOptions
	return { source = { kind = "player", userId = userId } }
end

local function rejected(result: Document.TxResult): boolean
	return not result.ok and result.error.kind == "rejected"
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("range guard", function()
		it("passes values within bounds", function()
			local s = setup({ Guards.range("coins", { min = 0, max = 100 }) }, { coins = 50 })
			expect(s.doc:increment("coins", 50).ok).toBe(true)
			expect(#s.broken).toBe(0)
		end)

		it("rejects values out of bounds and rolls the transaction back", function()
			local s = setup(
				{ Guards.range("coins", { min = 0, max = 100 }) },
				{ coins = 50, other = 0 }
			)
			local result = s.doc:transact(function(tx)
				tx:increment("other")
				tx:increment("coins", 51)
			end)
			expect(rejected(result)).toBe(true)
			if not result.ok then
				expect((string.find(result.error.message, "above the maximum of 100", 1, true))).never.toBeNil()
			end
			expect(s.doc:get("coins")).toBe(50)
			expect(s.doc:get("other")).toBe(0)
			expect(#s.broken).toBe(1)
			expect(s.broken[1].kind).toBe("range")
			expect(s.broken[1].path).toBe("coins")
		end)

		it("warns and still commits when the action is warn", function()
			local s = setup(
				{ Guards.range("coins", { min = 0 }, { action = "warn" }) },
				{ coins = 0 }
			)
			expect(s.doc:decrement("coins", 5).ok).toBe(true)
			expect(s.doc:get("coins")).toBe(-5)
			expect(#s.reported).toBe(1)
			expect(s.broken[1].action).toBe("warn")
		end)

		it("ignores transactions that don't touch its path", function()
			local s = setup({ Guards.range("coins", { max = 10 }) }, { coins = 999, gems = 0 })
			expect(s.doc:increment("gems").ok).toBe(true)
		end)
	end)

	describe("delta guard", function()
		it("passes changes within the limit", function()
			local s = setup({ Guards.delta("coins", { max = 100 }) }, { coins = 0 })
			expect(s.doc:increment("coins", 100).ok).toBe(true)
			expect(s.doc:decrement("coins", 100).ok).toBe(true)
		end)

		it("rejects a single jump past the limit", function()
			local s = setup({ Guards.delta("coins", { max = 100 }) }, { coins = 0 })
			expect(rejected(s.doc:increment("coins", 101))).toBe(true)
			expect(s.doc:get("coins")).toBe(0)
		end)

		it("limits rises and falls separately", function()
			local s = setup({ Guards.delta("coins", { up = 10, down = 1000 }) }, { coins = 500 })
			expect(s.doc:decrement("coins", 400).ok).toBe(true)
			expect(rejected(s.doc:increment("coins", 11))).toBe(true)
		end)

		it("flags and commits when the action is flag", function()
			local s = setup(
				{ Guards.delta("coins", { max = 1 }, { action = "flag" }) },
				{ coins = 0 }
			)
			expect(s.doc:increment("coins", 5).ok).toBe(true)
			expect(s.broken[1].action).toBe("flag")
		end)
	end)

	describe("rate guard", function()
		it("allows up to count changes per rolling window", function()
			local s = setup(
				{ Guards.rate("inventory", { count = 3, window = 10 }) },
				{ inventory = {} }
			)
			for _ = 1, 3 do
				expect(s.doc:append("inventory", "x").ok).toBe(true)
			end
			expect(rejected(s.doc:append("inventory", "x"))).toBe(true)
			s.universe.clock:advance(10.5)
			expect(s.doc:append("inventory", "x").ok).toBe(true)
		end)

		it("rolls entries off one at a time", function()
			local s = setup({ Guards.rate("n", { count = 2, window = 10 }) }, { n = 0 })
			expect(s.doc:increment("n").ok).toBe(true)
			s.universe.clock:advance(6)
			expect(s.doc:increment("n").ok).toBe(true)
			expect(rejected(s.doc:increment("n"))).toBe(true)
			s.universe.clock:advance(4.5)
			-- The first change is now older than the window, the second isn't
			expect(s.doc:increment("n").ok).toBe(true)
			expect(rejected(s.doc:increment("n"))).toBe(true)
		end)

		it("counts each player separately", function()
			local s = setup({ Guards.rate("n", { count = 1, window = 60 }) }, { n = 0 })
			expect(s.doc:transact(function(tx)
				tx:increment("n")
			end, player(1)).ok).toBe(true)
			expect(s.doc:transact(function(tx)
				tx:increment("n")
			end, player(2)).ok).toBe(true)
			expect(rejected(s.doc:transact(function(tx)
				tx:increment("n")
			end, player(1)))).toBe(true)
		end)

		it("doesn't count rejected attempts", function()
			local s = setup({
				Guards.rate("n", { count = 1, window = 60 }),
				Guards.range("n", { max = 5 }),
			}, { n = 0 })
			expect(rejected(s.doc:increment("n", 10))).toBe(true)
			expect(s.doc:increment("n", 1).ok).toBe(true)
		end)

		it("skips reaction and bundle writes by default, unless told otherwise", function()
			local skipping = setup({ Guards.rate("n", { count = 1, window = 60 }) }, { n = 0 })
			for _ = 1, 3 do
				expect(skipping.doc:transact(function(tx)
					tx:increment("n")
				end, { source = "reaction" }).ok).toBe(true)
			end

			local counting = setup({
				Guards.rate("n", { count = 1, window = 60 }, { skipSources = {} }),
			}, { n = 0 })
			expect(counting.doc:transact(function(tx)
				tx:increment("n")
			end, { source = "reaction" }).ok).toBe(true)
			expect(rejected(counting.doc:transact(function(tx)
				tx:increment("n")
			end, { source = "reaction" }))).toBe(true)
		end)
	end)

	describe("value rate guard", function()
		it("caps total gains within a rolling window", function()
			local s = setup(
				{ Guards.rateValue("coins", { gain = 100, window = 60 }) },
				{ coins = 0 }
			)
			expect(s.doc:increment("coins", 60).ok).toBe(true)
			expect(rejected(s.doc:increment("coins", 50))).toBe(true)
			expect(s.doc:increment("coins", 40).ok).toBe(true)
			s.universe.clock:advance(61)
			expect(s.doc:increment("coins", 100).ok).toBe(true)
		end)

		it("doesn't let spending reset the gain budget", function()
			local s = setup(
				{ Guards.rateValue("coins", { gain = 100, window = 60 }) },
				{ coins = 0 }
			)
			expect(s.doc:increment("coins", 100).ok).toBe(true)
			expect(s.doc:decrement("coins", 100).ok).toBe(true)
			expect(rejected(s.doc:increment("coins", 1))).toBe(true)
		end)

		it("caps losses too", function()
			local s = setup(
				{ Guards.rateValue("coins", { loss = 50, window = 60 }) },
				{ coins = 1000 }
			)
			expect(s.doc:decrement("coins", 50).ok).toBe(true)
			expect(rejected(s.doc:decrement("coins", 1))).toBe(true)
		end)

		it("kicks the player when the action is kick", function()
			local s = setup({
				Guards.rateValue("coins", { gain = 10, window = 60 }, { action = "kick" }),
			}, { coins = 0 })
			local result = s.doc:transact(function(tx)
				tx:increment("coins", 1000)
			end, player(42))
			expect(rejected(result)).toBe(true)
			expect(#s.universe.kicks).toBe(1)
			expect(s.universe.kicks[1].userId).toBe(42)
		end)
	end)

	describe("requires guard", function()
		it("lets the path change alongside the required one", function()
			local s = setup({ Guards.requires("level", "xp") }, { level = 1, xp = 0 })
			expect(s.doc:transact(function(tx)
				tx:increment("xp", 100)
				tx:increment("level")
			end).ok).toBe(true)
		end)

		it("rejects the path changing alone", function()
			local s = setup({ Guards.requires("level", "xp") }, { level = 1, xp = 0 })
			expect(rejected(s.doc:increment("level"))).toBe(true)
			expect(s.doc:increment("xp").ok).toBe(true)
		end)
	end)

	describe("subset guard", function()
		it("passes when every item is in the list", function()
			local s = setup(
				{ Guards.subset("equipped", "inventory") },
				{ equipped = {}, inventory = { "sword", "bow" } }
			)
			expect(s.doc:append("equipped", "bow").ok).toBe(true)
		end)

		it("rejects items that aren't owned, with the item's path", function()
			local s = setup(
				{ Guards.subset("equipped", "inventory") },
				{ equipped = { "sword" }, inventory = { "sword" } }
			)
			expect(rejected(s.doc:append("equipped", "axe"))).toBe(true)
			expect(s.broken[1].path).toBe("equipped[2]")
		end)

		it("catches the container losing an equipped item", function()
			local s = setup(
				{ Guards.subset("equipped", "inventory") },
				{ equipped = { "sword" }, inventory = { "sword" } }
			)
			expect(rejected(s.doc:remove("inventory.1"))).toBe(true)
		end)

		it("checks map keys when the container is a map", function()
			local s = setup(
				{ Guards.subset("equipped", "owned") },
				{ equipped = {}, owned = { sword = 1 } }
			)
			expect(s.doc:append("equipped", "sword").ok).toBe(true)
			expect(rejected(s.doc:append("equipped", "axe"))).toBe(true)
		end)
	end)

	describe("schema guard", function()
		local Player = t.struct({
			coins = t.integer({ min = 0 }),
			name = t.string(),
			inventory = t.array(t.struct({ id = t.string() })),
		})
		local valid = { coins = 1, name = "Ana", inventory = { { id = "a" }, { id = "b" } } }

		it("passes changes that fit", function()
			local s = setup({ Guards.schema(Player) }, valid)
			expect(s.doc:increment("coins").ok).toBe(true)
			expect(s.doc:append("inventory", { id = "c" }).ok).toBe(true)
			expect(s.doc:remove("inventory.1").ok).toBe(true)
		end)

		it("rejects changes that don't fit, with the schema path", function()
			local s = setup({ Guards.schema(Player) }, valid)
			expect(rejected(s.doc:set("coins", -1))).toBe(true)
			expect(s.broken[1].path).toBe("data.coins")
			expect(rejected(s.doc:set("inventory.1.id", 5))).toBe(true)
			expect(s.broken[2].path).toBe("data.inventory[1].id")
		end)

		it("rejects undeclared fields and missing required ones", function()
			local s = setup({ Guards.schema(Player) }, valid)
			expect(rejected(s.doc:set("typo", 1))).toBe(true)
			expect(s.broken[1].path).toBe("data.typo")
			expect(rejected(s.doc:remove("name"))).toBe(true)
		end)

		it("reports the action it was given", function()
			local s = setup({ Guards.schema(Player, { action = "warn" }) }, valid)
			expect(s.doc:set("coins", "lots").ok).toBe(true)
			expect(s.broken[1].action).toBe("warn")
		end)
	end)

	describe("custom guard", function()
		it("passes when the function says so and rejects with its reason otherwise", function()
			local s = setup({
				Guards.custom(function(_diff, state, ctx)
					local coins = (state :: any).coins
					if ctx.userId and coins > 10 then
						return false, "players can't hold more than 10 here"
					end
					return true
				end),
			}, { coins = 0 })
			expect(s.doc:increment("coins", 50).ok).toBe(true)
			local result = s.doc:transact(function(tx)
				tx:increment("coins")
			end, player(7))
			expect(rejected(result)).toBe(true)
			expect(s.broken[1].reason).toBe("players can't hold more than 10 here")
		end)
	end)

	describe("actions and context", function()
		it("lets the strongest action win and reports every violation", function()
			local s = setup({
				Guards.range("coins", { max = 10 }, { action = "warn" }),
				Guards.delta("coins", { max = 5 }, { action = "reject" }),
			}, { coins = 0 })
			expect(rejected(s.doc:increment("coins", 20))).toBe(true)
			expect(#s.broken).toBe(2)
		end)

		it("treats rollback as reject", function()
			local s = setup(
				{ Guards.range("coins", { max = 1 }, { action = "rollback" }) },
				{ coins = 0 }
			)
			expect(rejected(s.doc:increment("coins", 2))).toBe(true)
			expect(s.doc:get("coins")).toBe(0)
		end)

		it("lets a custom action decide, failing closed on nil", function()
			local flagging = setup({
				Guards.range("coins", { max = 1 }, {
					action = function()
						return "flag"
					end,
				}),
			}, { coins = 0 })
			expect(flagging.doc:increment("coins", 5).ok).toBe(true)

			local silent = setup({
				Guards.range("coins", { max = 1 }, {
					action = function()
						return nil
					end,
				}),
			}, { coins = 0 })
			expect(rejected(silent.doc:increment("coins", 5))).toBe(true)
		end)

		it("only checks transactions that ran a listed op", function()
			local opName = "guardTestBuy"
			Transaction.register(opName, function(tx)
				tx:decrement("coins", 1000)
			end)
			local universe = Universe.new()
			local set = Guards.set({
				guards = { Guards.range("coins", { min = 0 }, { ops = { opName } }) },
				reportError = function() end,
			})
			local doc = Document.new({
				data = { coins = 0 },
				ops = { opName },
				reportError = function() end,
			})
			set:attach(doc)
			expect(doc:decrement("coins", 5).ok).toBe(true)
			expect(rejected(doc:op(opName))).toBe(true)
			expect(universe.clock:now()).toBe(0)
		end)

		it("carries source, player, ops and time in each violation", function()
			local s = setup(
				{ Guards.range("coins", { max = 1 }, { action = "flag" }) },
				{ coins = 0 }
			)
			s.universe.clock:advance(123)
			s.doc:transact(function(tx)
				tx:increment("coins", 5)
				tx:set("x", 1)
			end, player(9))
			local violation = s.broken[1]
			expect(violation.source.kind).toBe("player")
			expect(violation.userId).toBe(9)
			expect(violation.ops).toEqual({ "increment", "set" })
			expect(violation.timestamp).toBe(123)
			expect(table.isfrozen(violation)).toBe(true)
		end)

		it("fires events after the transaction settles, so handlers can write", function()
			local s = setup(
				{ Guards.range("coins", { max = 1 }, { action = "flag" }) },
				{ coins = 0, flags = 0 }
			)
			s.set.broken:connect(function()
				s.doc:increment("flags")
			end)
			expect(s.doc:increment("coins", 5).ok).toBe(true)
			expect(s.doc:get("flags")).toBe(1)
		end)

		it("refuses unknown actions and malformed limits", function()
			expect(function()
				Guards.range("coins", { max = 1 }, { action = "explode" :: any })
			end).toThrow("unknown guard action")
			expect(function()
				Guards.range("coins", {})
			end).toThrow("needs a min or a max")
			expect(function()
				Guards.rate("n", { count = 0, window = 10 })
			end).toThrow("count of at least 1")
			expect(function()
				Guards.set():add({} :: any)
			end).toThrow("expected a guard")
		end)

		it("names guards after their kind and path unless named", function()
			expect(Guards.range("coins", { max = 1 }).name).toBe("range coins")
			expect(Guards.custom(function()
				return true
			end, { name = "noCheating" }).name).toBe("noCheating")
		end)
	end)
end
