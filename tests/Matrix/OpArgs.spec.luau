--!strict

local Document = require("../../src/Matrix/Document")
local Geode = require("../../src")
local Lune = require("../Obsidian/LuneDatatypes")
local Spec = require("../_lib/Spec")
local Tooling = require("../../src/Sapphire/Tooling")
local Transaction = require("../../src/Matrix/Transaction")
local Validate = require("../../src/Obsidian/Validate")
local t = require("../../src/Obsidian/Schema")

type Any = any

local codec = Lune.codec
local roblox = Lune.roblox

-- Op names are global, so each test registers its own
local opCount = 0
local function uniqueOp(handler: Transaction.OpHandler, options: Transaction.OpOptions?): string
	opCount += 1
	local name = `argsOp{opCount}`
	Transaction.register(name, handler, options)
	return name
end

local function newDoc(ops: { string }): Document.Document
	return Document.new({ data = { inventory = {} }, ops = ops, reportError = function() end })
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("op argument schemas", function()
		it("run the handler when the arguments match", function()
			local name = uniqueOp(function(tx, item: string, amount: number)
				tx:set({ "inventory", item }, amount)
			end, { args = { t.string(), t.integer({ min = 1 }) } })
			local doc = newDoc({ name })
			expect(doc:op(name, "sword", 2).ok).toBe(true)
			expect(doc:get({ "inventory", "sword" })).toBe(2)
		end)

		it("fail with invalidArgs before the handler runs", function()
			local ran = false
			local name = uniqueOp(function(tx, item: string)
				ran = true
				tx:set({ "inventory", item }, 1)
			end, { args = { t.string() } })
			local doc = newDoc({ name })
			local result = doc:transact(function(tx)
				tx:set("touched", true)
				tx:op(name, 42)
			end)
			expect(result.ok).toBe(false)
			expect((result :: Any).error.kind).toBe("invalidArgs")
			local found = string.find((result :: Any).error.message, "argument 1", 1, true)
			expect(found).never.toBeNil()
			expect(ran).toBe(false)
			expect(doc:get("touched")).toBeNil()
		end)

		it("refuse more arguments than declared", function()
			local name = uniqueOp(function() end, { args = { t.string() } })
			local result = newDoc({ name }):op(name, "a", "b") :: Any
			expect(result.ok).toBe(false)
			expect(result.error.kind).toBe("invalidArgs")
		end)

		it("let optional arguments be left out, but not required ones", function()
			local name = uniqueOp(function(tx, item: string, amount: number?)
				tx:set({ "inventory", item }, amount or 1)
			end, { args = { t.string(), t.optional(t.integer()) } })
			local doc = newDoc({ name })
			expect(doc:op(name, "shield").ok).toBe(true)
			expect(doc:get({ "inventory", "shield" })).toBe(1)
			local missing = doc:op(name) :: Any
			expect(missing.error.kind).toBe("invalidArgs")
		end)

		it("leave ops without schemas taking anything", function()
			local name = uniqueOp(function(tx, value: unknown)
				tx:set("anything", value)
			end)
			expect(Transaction.opArgs(name)).toBeNil()
			expect(newDoc({ name }):op(name, { 1, 2 }).ok).toBe(true)
		end)

		it("must be schemas", function()
			expect(function()
				Transaction.register("argsOpBad", function() end, { args = { "string" :: any } })
			end).toThrow("isn't a schema")
		end)

		it("are reachable through Geode.op", function()
			opCount += 1
			local name = `geodeArgsOp{opCount}`
			Geode.op(name, function(tx, value: number)
				tx:set("value", value)
			end, { args = { Geode.t.number() } })
			local doc = Geode.Raw.document({ ops = { name } })
			expect(doc:op(name, 3).ok).toBe(true)
			expect((doc:op(name, "three") :: Any).error.kind).toBe("invalidArgs")
		end)
	end)

	describe("op names and descriptions", function()
		it("are kept for tools without changing how the op runs", function()
			local name = uniqueOp(function(tx, item: string, coins: number)
				tx:set({ "inventory", item }, coins)
			end, {
				args = { t.string(), t.integer({ min = 1, max = 1000 }) },
				names = { "item", "coins" },
				description = "Give the player an item and some coins",
			})
			local info = Transaction.opInfo(name) :: Transaction.OpInfo
			expect(info.names).toEqual({ "item", "coins" })
			expect(info.description).toBe("Give the player an item and some coins")
			expect(table.isfrozen(info)).toBe(true)
			expect(table.isfrozen(info.names :: { string })).toBe(true)
			local doc = newDoc({ name })
			expect(doc:op(name, "sword", 5).ok).toBe(true)
			expect((doc:op(name, "sword", 0) :: Any).error.kind).toBe("invalidArgs")
		end)

		it("can name fewer arguments than the op declares", function()
			local name = uniqueOp(function() end, {
				args = { t.string(), t.number() },
				names = { "item" },
			})
			local info = Transaction.opInfo(name) :: Transaction.OpInfo
			expect(info.names).toEqual({ "item" })
			expect(info.description).toBeNil()
		end)

		it("allow a description on an op without args", function()
			local name = uniqueOp(function() end, { description = "Reset the daily quests" })
			local info = Transaction.opInfo(name) :: Transaction.OpInfo
			expect(info.description).toBe("Reset the daily quests")
			expect(info.names).toBeNil()
		end)

		it("are empty for ops that gave neither, and nil for others", function()
			local name = uniqueOp(function() end, { args = { t.string() } })
			local info = Transaction.opInfo(name) :: Transaction.OpInfo
			expect(info.names).toBeNil()
			expect(info.description).toBeNil()
			expect(Transaction.opInfo("set")).toBeNil()
			expect(Transaction.opInfo("noSuchOpAnywhere")).toBeNil()
		end)

		it("copy the names the op was given", function()
			local names = { "item" }
			local name = uniqueOp(function() end, { args = { t.string() }, names = names })
			names[1] = "changed"
			expect((Transaction.opInfo(name) :: Transaction.OpInfo).names).toEqual({ "item" })
		end)

		it("need args to name", function()
			expect(function()
				Transaction.register("namesOpNoArgs", function() end, { names = { "item" } })
			end).toThrow("declares no args")
			expect(Transaction.isRegistered("namesOpNoArgs")).toBe(false)
		end)

		it("can't name more arguments than the op declares", function()
			expect(function()
				Transaction.register("namesOpTooMany", function() end, {
					args = { t.string() },
					names = { "item", "coins" },
				})
			end).toThrow("names 2 arguments but declares 1")
			expect(Transaction.isRegistered("namesOpTooMany")).toBe(false)
			expect(Transaction.opArgs("namesOpTooMany")).toBeNil()
		end)

		it("must be a list of non-empty strings", function()
			local args = { t.string(), t.string() }
			expect(function()
				Transaction.register("namesOpBad", function() end, {
					args = args,
					names = "item" :: any,
				})
			end).toThrow("must be a list of strings")
			expect(function()
				Transaction.register("namesOpBad", function() end, {
					args = args,
					names = { "item", "" },
				})
			end).toThrow("name 2 of op namesOpBad must be a non%-empty string")
			expect(function()
				Transaction.register("namesOpBad", function() end, {
					args = args,
					names = { "item", 2 :: any },
				})
			end).toThrow("must be a non%-empty string")
			expect(function()
				Transaction.register("namesOpBad", function() end, {
					args = args,
					names = { first = "item" } :: any,
				})
			end).toThrow("must be a list of strings")
			expect(Transaction.isRegistered("namesOpBad")).toBe(false)
		end)

		it("need a non-empty string for the description", function()
			expect(function()
				Transaction.register("descriptionOpBad", function() end, { description = "" })
			end).toThrow("description must be a non%-empty string")
			expect(function()
				Transaction.register("descriptionOpBad", function() end, {
					description = 42 :: any,
				})
			end).toThrow("description must be a non%-empty string")
			expect(Transaction.isRegistered("descriptionOpBad")).toBe(false)
		end)

		it("are reachable through Geode.op", function()
			opCount += 1
			local name = `geodeNamesOp{opCount}`
			Geode.op(name, function() end, {
				args = { Geode.t.string() },
				names = { "item" },
				description = "Grant an item",
			})
			local info = Transaction.opInfo(name) :: Transaction.OpInfo
			expect(info.names).toEqual({ "item" })
			expect(info.description).toBe("Grant an item")
		end)
	end)

	describe("custom op arguments for tools", function()
		it("are described from their schemas", function()
			local name = uniqueOp(function() end, {
				args = { t.string(), t.optional(codec.Vector3) },
			})
			local listed = Tooling.ops({ name })
			local described = listed[#listed]
			expect(described.name).toBe(name)
			local args = described.args :: { Tooling.ArgSpec }
			expect(#args).toBe(2)
			expect(args[1].type).toBe("schema")
			expect((args[1].schema :: Any).kind).toBe("string")
			expect(args[2].optional).toBe(true)
			expect((args[2].schema :: Any).codec).toBe("Vector3")
		end)

		it("are decoded from their stored form with their schemas", function()
			local name = uniqueOp(function() end, { args = { t.string(), codec.Vector3 } })
			local position = roblox.Vector3.new(1, 2, 3)
			local stored = Validate.encode(codec.Vector3, position)
			local ok, values, count = Tooling.decodeArgs(nil, name, { "spawn", stored })
			expect(ok).toBe(true)
			expect(count).toBe(2)
			expect((values :: Any)[2]).toBe(position)

			local tooMany = Tooling.decodeArgs(nil, name, { "spawn", stored, 3 })
			expect(tooMany).toBe(false)
		end)
	end)
end
