--!strict

local Json = require("../../src/Quartz/Json")
local Spec = require("../_lib/Spec")
local serde = require("@lune/serde")

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Json.encode", function()
		it("encodes scalars", function()
			expect(Json.encode(nil)).toBe("null")
			expect(Json.encode(true)).toBe("true")
			expect(Json.encode(12)).toBe("12")
			expect(Json.encode(1.5)).toBe("1.5")
			expect(Json.encode("hi")).toBe('"hi"')
		end)

		it("escapes strings so a JSON parser reads them back", function()
			local text = 'quote " backslash \\ newline \n tab \t control ' .. string.char(1)
			expect(serde.decode("json", Json.encode(text))).toBe(text)
			expect(Json.encode(string.char(1))).toBe('"\\u0001"')
		end)

		it("encodes arrays and objects that a JSON parser reads back", function()
			local nested: { unknown } = { 1, 2, { deep = "x" } }
			local value: { [string]: unknown } = { list = nested, empty = {}, flag = false }
			local decoded = serde.decode("json", Json.encode(value))
			expect(decoded).toEqual(value)
		end)

		it("refuses values JSON can't hold", function()
			expect(function()
				Json.encode({ fn = print })
			end).toThrow("can't encode a function")
		end)

		it("works as a Json adapter", function()
			expect(Json.adapter():encode({ 1 })).toBe("[1]")
		end)
	end)
end
