--!strict

local Json = require("../../src/Quartz/Json")
local Size = require("../../src/Obsidian/Size")
local Spec = require("../_lib/Spec")

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect
	local json = Json.adapter()

	describe("Size", function()
		it("measures the JSON length of a value", function()
			expect(Size.measure(json, { a = 1 })).toBe(#'{"a":1}')
			expect(Size.measure(json, "hi")).toBe(4)
		end)

		it("rates a value against soft and hard budgets", function()
			local value = { name = string.rep("x", 100) }
			local size = Size.measure(json, value)
			expect(Size.check(json, value, { soft = size + 1, hard = size + 2 }).level).toBe("ok")
			expect(Size.check(json, value, { soft = size - 1, hard = size + 2 }).level).toBe("soft")
			local hard = Size.check(json, value, { soft = 10, hard = size - 1 })
			expect(hard.level).toBe("hard")
			expect(hard.size).toBe(size)
			expect(Size.check(json, value, {}).level).toBe("ok")
		end)

		it("refuses a soft budget above the hard one", function()
			expect(function()
				Size.check(json, 1, { soft = 10, hard = 5 })
			end).toThrow("soft size budget")
		end)
	end)
end
