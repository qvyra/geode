--!strict

local Path = require("../../src/Matrix/Path")
local Spec = require("../_lib/Spec")

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	local inventoryPos: Path.Path = { "inventory", 3, "pos" }

	describe("Path.parse", function()
		it("splits dotted strings and turns digit segments into indices", function()
			expect(Path.parse("inventory.3.pos")).toEqual(inventoryPos)
			expect(Path.parse("coins")).toEqual({ "coins" })
		end)

		it("takes the list form as is", function()
			local list: Path.Path = { "list", 2 }
			expect(Path.parse({ "scores", "12345" })).toEqual({ "scores", "12345" })
			expect(Path.parse(list)).toEqual(list)
		end)

		it("treats nil and empty as the root", function()
			expect(Path.parse(nil)).toEqual({})
			expect(Path.parse("")).toEqual({})
			expect(Path.parse({})).toEqual({})
		end)

		it("rejects empty segments, bad indices and odd types", function()
			local fractional: Path.Path = { "a", 1.5 }
			-- not a valid Path, the way an untyped caller might send it
			local wrongType: { unknown } = { "a", true }
			expect(function()
				Path.parse("a..b")
			end).toThrow("empty segment")
			expect(function()
				Path.parse("a.0")
			end).toThrow("indices start at 1")
			expect(function()
				Path.parse(fractional)
			end).toThrow("indices start at 1")
			expect(function()
				Path.parse(wrongType :: any)
			end).toThrow("boolean segment")
			expect(function()
				Path.parse(5 :: any)
			end).toThrow("string or a list")
		end)
	end)

	describe("Path.format", function()
		it("writes paths the way schema issues do", function()
			expect(Path.format(inventoryPos)).toBe("inventory[3].pos")
			expect(Path.format({ "scores", "12345" })).toBe('scores["12345"]')
			expect(Path.format({})).toBe("")
		end)
	end)

	describe("Path.related", function()
		it("matches ancestors and descendants both ways", function()
			expect(Path.related({ "a" }, { "a", "b" })).toBe(true)
			expect(Path.related({ "a", "b" }, { "a" })).toBe(true)
			expect(Path.related({ "a", "b" }, { "a", "c" })).toBe(false)
			expect(Path.related({}, { "x" })).toBe(true)
			expect(Path.startsWith({ "a" }, { "a", "b" })).toBe(false)
		end)
	end)
end
