--!strict

local Spec = require("../_lib/Spec")
local t = require("../../src/Obsidian/Schema")

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("t builders", function()
		it("build frozen nodes with their options", function()
			local name = t.string({ minLength = 1, maxLength = 20, pattern = "%a+" })
			expect(name.kind).toBe("string")
			expect(name.maxLength).toBe(20)
			expect(table.isfrozen(name)).toBe(true)

			local coins = t.integer({ min = 0 })
			expect(coins.kind).toBe("number")
			expect(coins.integer).toBe(true)
			expect(t.number().integer).toBeNil()
			expect(t.boolean().kind).toBe("boolean")
			expect(t.literal(3).value).toBe(3)
			expect(t.json().kind).toBe("json")
		end)

		it("copy and freeze the lists and fields they're given", function()
			local values = { "a", "b" }
			local enum = t.enum(values)
			values[3] = "c"
			expect(#(enum.values :: { unknown })).toBe(2)

			local fields = { a = t.number() }
			local struct = t.struct(fields)
			fields.b = t.number()
			expect((struct.fields :: any).b).toBeNil()
			expect(table.isfrozen(struct.fields :: { [string]: t.Schema })).toBe(true)
		end)

		it("nest", function()
			local list = t.array(t.optional(t.number()), { maxLength = 3 })
			expect(list.kind).toBe("array")
			expect((list.item :: t.Schema).kind).toBe("optional")
			local map = t.map(t.number(), { key = t.string(), maxEntries = 5 })
			expect((map.key :: t.Schema).kind).toBe("string")
			local union = t.union({ t.string(), t.number() })
			expect(#(union.options :: { t.Schema })).toBe(2)
		end)

		it("reject contradictory or malformed options", function()
			expect(function()
				t.number({ min = 5, max = 1 })
			end).toThrow("minimum 5")
			expect(function()
				t.string({ minLength = 3, maxLength = 2 })
			end).toThrow("t.string")
			expect(function()
				t.enum({})
			end).toThrow("at least one")
			expect(function()
				t.union({ t.number() })
			end).toThrow("at least two")
			expect(function()
				t.array(5 :: any)
			end).toThrow("item schema")
			expect(function()
				t.map(t.number(), { key = t.number() })
			end).toThrow("keys must be")
			expect(function()
				t.struct({ a = "nope" :: any })
			end).toThrow("isn't a schema")
		end)

		it("tell schemas apart from other values", function()
			expect(t.isSchema(t.number())).toBe(true)
			expect(t.isSchema({})).toBe(false)
			expect(t.isSchema("number")).toBe(false)
		end)
	end)
end
