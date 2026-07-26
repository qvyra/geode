--!strict

local Document = require("../../src/Matrix/Document")
local Facet = require("../../src/Facet/Facet")
local Guards = require("../../src/Obsidian/Guards")
local Spec = require("../_lib/Spec")
local Transaction = require("../../src/Matrix/Transaction")

type Any = any

local function levelCost(level: number): number
	return level * 100
end

local function progressBundle(): Facet.Bundle
	return Facet.bundle({ "xp", "level" }, function(tx)
		local xp, level = tx:get("xp") :: number, tx:get("level") :: number
		while xp >= levelCost(level) do
			xp -= levelCost(level)
			level += 1
		end
		tx:set("xp", xp)
		tx:set("level", level)
	end, { name = "progress" })
end

local function levelReward(): Facet.Reaction
	return Facet.react({ "level" }, function(tx)
		local gained = (tx:get("level") :: number) - (tx:getBefore("level") :: number)
		if gained > 0 then
			tx:increment("coins", gained * 50)
		end
	end, { name = "levelReward", writes = { "coins" } })
end

local function build(
	data: unknown,
	facets: Facet.SetOptions,
	guards: { Guards.Guard }?
): Document.Document
	local doc = Document.new({ data = data, reportError = function() end })
	Facet.set(facets):attach(doc)
	if guards then
		Guards.set({ guards = guards, reportError = function() end }):attach(doc)
	end
	return doc
end

local function player(userId: number): Document.TransactOptions
	return { source = { kind = "player", userId = userId } }
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("xp and level bundle, end to end", function()
		it("levels up inside the same transaction and pays the reward", function()
			local doc = build({ xp = 0, level = 1, coins = 0 }, {
				bundles = { progressBundle() },
				reactions = { levelReward() },
			}, {
				Guards.requires("level", "xp"),
				Guards.range("coins", { min = 0 }),
			})

			local result = doc:transact(function(tx)
				tx:increment("xp", 250)
			end, player(1))
			assert(result.ok and result.record, "expected a commit")

			expect(doc:get("level")).toBe(2)
			expect(doc:get("xp")).toBe(150)
			expect(doc:get("coins")).toBe(50)
			expect(doc:revision()).toBe(1)
			expect(result.record.diff.level.new).toBe(2)
			expect(result.record.diff.coins.new).toBe(50)
		end)

		it("levels several times from one big gain", function()
			local doc = build({ xp = 0, level = 1, coins = 0 }, {
				bundles = { progressBundle() },
				reactions = { levelReward() },
			})
			doc:increment("xp", 100 + 200 + 300 + 5)
			expect(doc:get("level")).toBe(4)
			expect(doc:get("xp")).toBe(5)
			expect(doc:get("coins")).toBe(150)
		end)

		it("stops a direct level edit with the requires guard", function()
			local doc = build({ xp = 0, level = 1, coins = 0 }, {
				bundles = { progressBundle() },
			}, { Guards.requires("level", "xp") })
			local result = doc:set("level", 10)
			expect(result.ok).toBe(false)
			expect(doc:get("level")).toBe(1)
		end)

		it("rolls back bundle and reaction writes when a guard rejects", function()
			local doc = build({ xp = 0, level = 1, coins = 0 }, {
				bundles = { progressBundle() },
				reactions = { levelReward() },
			}, { Guards.range("coins", { max = 10 }) })
			local result = doc:increment("xp", 150)
			expect(result.ok).toBe(false)
			expect(doc:get("xp")).toBe(0)
			expect(doc:get("level")).toBe(1)
			expect(doc:get("coins")).toBe(0)
		end)

		it("keeps reaction writes out of the player's rate limit but under range guards", function()
			local doc = build({ xp = 0, level = 1, coins = 0 }, {
				bundles = { progressBundle() },
				reactions = { levelReward() },
			}, {
				Guards.rate("coins", { count = 1, window = 60 }),
				Guards.range("coins", { max = 100 }),
			})
			local function gain(amount: number): boolean
				return doc:transact(function(tx)
					tx:increment("xp", amount)
				end, player(1)).ok
			end
			expect(gain(100)).toBe(true)
			expect(gain(200)).toBe(true)
			expect(doc:get("coins")).toBe(100)
			expect(gain(300)).toBe(false)
			expect(doc:get("coins")).toBe(100)
		end)

		it("only runs the bundle when one of its fields changes", function()
			local runs = 0
			local doc = build({ xp = 0, level = 1, other = 0 }, {
				bundles = {
					Facet.bundle({ "xp", "level" }, function()
						runs += 1
					end),
				},
			})
			doc:increment("other")
			expect(runs).toBe(0)
			doc:increment("xp")
			expect(runs).toBe(1)
		end)
	end)

	describe("reactions", function()
		it("run in dependency order whatever order they were declared in", function()
			local order = {}
			local second = Facet.react({ "b" }, function(tx)
				table.insert(order, "second")
				tx:set("c", (tx:get("b") :: number) + 1)
			end, { name = "second", writes = { "c" } })
			local first = Facet.react({ "a" }, function(tx)
				table.insert(order, "first")
				tx:set("b", (tx:get("a") :: number) + 1)
			end, { name = "first", writes = { "b" } })

			local set = Facet.set({ reactions = { second, first } })
			expect(set.order[1].name).toBe("first")
			expect(set.order[2].name).toBe("second")

			local doc =
				Document.new({ data = { a = 0, b = 0, c = 0 }, reportError = function() end })
			set:attach(doc)
			doc:set("a", 10)
			expect(order).toEqual({ "first", "second" })
			expect(doc:get("c")).toBe(12)
		end)

		it("can't write outside what they declared", function()
			local doc = build({ a = 0, b = 0, sneaky = 0 }, {
				reactions = {
					Facet.react({ "a" }, function(tx)
						tx:set("b", 1)
						tx:set("sneaky", 1)
					end, { name = "leaky", writes = { "b" } }),
				},
			})
			local result = doc:increment("a")
			expect(result.ok).toBe(false)
			if not result.ok then
				expect((string.find(result.error.message, "leaky wrote sneaky", 1, true))).never.toBeNil()
			end
			expect(doc:get("a")).toBe(0)
		end)

		it("can't be declared without their writes", function()
			expect(function()
				Facet.react({ "a" }, function() end, nil :: any)
			end).toThrow("declare the paths it writes")
		end)

		it("stop with a loud error past the depth limit", function()
			local function chain(maxDepth: number): Document.Document
				return build({ a = 0, m1 = 0, n1 = 0, m2 = 0, n2 = 0, z = 0 }, {
					maxDepth = maxDepth,
					bundles = {
						Facet.bundle({ "m1", "n1" }, function(tx)
							tx:set("n1", tx:get("m1"))
						end),
						Facet.bundle({ "m2", "n2" }, function(tx)
							tx:set("n2", tx:get("m2"))
						end),
					},
					reactions = {
						Facet.react({ "a" }, function(tx)
							tx:set("m1", tx:get("a"))
						end, { writes = { "m1" } }),
						Facet.react({ "n1" }, function(tx)
							tx:set("m2", tx:get("n1"))
						end, { writes = { "m2" } }),
						Facet.react({ "n2" }, function(tx)
							tx:set("z", tx:get("n2"))
						end, { writes = { "z" } }),
					},
				})
			end

			local deep = chain(8)
			expect(deep:set("a", 7).ok).toBe(true)
			expect(deep:get("z")).toBe(7)

			local shallow = chain(2)
			local result = shallow:set("a", 7)
			expect(result.ok).toBe(false)
			if not result.ok then
				expect(
					(string.find(result.error.message, "didn't settle within 2 rounds", 1, true))
				).never.toBeNil()
			end
			expect(shallow:get("z")).toBe(0)
		end)
	end)

	describe("cycles", function()
		it("are an error when the set is defined", function()
			local ping = Facet.react({ "x" }, function() end, { name = "ping", writes = { "y" } })
			local pong = Facet.react({ "y" }, function() end, { name = "pong", writes = { "x" } })
			expect(function()
				Facet.set({ reactions = { ping, pong } })
			end).toThrow("cycle through ping, pong")
		end)

		it("include a reaction that triggers itself", function()
			local echo = Facet.react({ "x" }, function() end, { name = "echo", writes = { "x" } })
			expect(function()
				Facet.set({ reactions = { echo } })
			end).toThrow("echo writes a path it depends on")
		end)

		it("include loops that pass through a bundle", function()
			local refund = Facet.react(
				{ "level" },
				function() end,
				{ name = "refund", writes = { "xp" } }
			)
			expect(function()
				Facet.set({ bundles = { progressBundle() }, reactions = { refund } })
			end).toThrow("cycle through")
		end)

		it("count nested paths as related", function()
			local a = Facet.react(
				{ "stats" },
				function() end,
				{ name = "a", writes = { "inventory.count" } }
			)
			local b = Facet.react(
				{ "inventory" },
				function() end,
				{ name = "b", writes = { "stats.total" } }
			)
			expect(function()
				Facet.set({ reactions = { a, b } })
			end).toThrow("cycle")
		end)
	end)

	describe("derived fields", function()
		it("read like stored fields and recompute only when a dependency changes", function()
			local computes = 0
			local doc = build({ level = 2, gear = { attack = 5 }, other = 0 }, {
				derived = {
					Facet.derive("power", { "level", "gear" }, function(state)
						computes += 1
						local data = state :: Any
						return { total = data.level * 10 + data.gear.attack }
					end),
				},
			})
			expect(doc:get("power.total")).toBe(25)
			expect(doc:get("power.total")).toBe(25)
			expect(computes).toBe(1)
			doc:increment("other")
			expect(doc:get("power.total")).toBe(25)
			expect(computes).toBe(1)
			doc:increment("level")
			expect(doc:get("power.total")).toBe(35)
			expect(computes).toBe(2)
			expect(table.isfrozen(doc:get("power") :: Any)).toBe(true)
		end)

		it("aren't part of the stored snapshot", function()
			local doc = build({ level = 1 }, {
				derived = {
					Facet.derive("double", { "level" }, function(state)
						return (state :: Any).level * 2
					end),
				},
			})
			expect(doc:get("double")).toBe(2)
			expect((doc:snapshot() :: Any).double).toBeNil()
		end)

		it("can't be written", function()
			local doc = build({ level = 1 }, {
				derived = {
					Facet.derive("double", { "level" }, function(state)
						return (state :: Any).level * 2
					end),
				},
			})
			local result = doc:set("double", 99)
			expect(result.ok).toBe(false)
			if not result.ok then
				expect(result.error.kind).toBe("rejected")
			end
			expect(doc:get("double")).toBe(2)
		end)

		it("can't share a name with a stored field", function()
			expect(function()
				build({ power = 1, level = 1 }, {
					derived = {
						Facet.derive("power", { "level" }, function()
							return 0
						end),
					},
				})
			end).toThrow("clashes with a stored field")
		end)

		it("fire observers when their value changes", function()
			local doc = build({ level = 1, other = 0 }, {
				derived = {
					Facet.derive("double", { "level" }, function(state)
						return (state :: Any).level * 2
					end),
				},
			})
			local seen = {}
			doc:observe("double", function(new, old)
				table.insert(seen, { new = new, old = old })
			end)
			doc:increment("other")
			doc:increment("level")
			expect(seen).toEqual({ { new = 4, old = 2 } })
		end)

		it("refuse duplicate names and dotted names", function()
			expect(function()
				Facet.derive("a.b", { "x" }, function()
					return 0
				end)
			end).toThrow("can't contain dots")
			local first = Facet.derive("same", { "x" }, function()
				return 0
			end)
			expect(function()
				Facet.set({ derived = { first, first } })
			end).toThrow("two derived fields are named same")
		end)
	end)

	describe("bundles", function()
		it("can't write outside their fields", function()
			local doc = build({ xp = 0, level = 1, coins = 0 }, {
				bundles = {
					Facet.bundle({ "xp", "level" }, function(tx)
						tx:set("coins", 1)
					end, { name = "greedy" }),
				},
			})
			local result = doc:increment("xp")
			expect(result.ok).toBe(false)
			if not result.ok then
				expect((string.find(result.error.message, "greedy wrote coins", 1, true))).never.toBeNil()
			end
		end)

		it("mark their writes as bundle writes", function()
			local writers = {}
			local doc = Document.new({ data = { xp = 0, level = 1 }, reportError = function() end })
			Facet.set({ bundles = { progressBundle() } }):attach(doc)
			doc:addStage(function(tx: Transaction.Transaction)
				writers.xp = tx:writerOf("xp")
				writers.level = tx:writerOf("level")
			end)
			doc:transact(function(tx)
				tx:increment("xp", 100)
			end, player(3))
			expect(writers.xp).toBe("player")
			expect(writers.level).toBe("bundle")
		end)
	end)
end
