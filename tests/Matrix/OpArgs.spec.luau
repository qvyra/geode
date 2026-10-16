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
