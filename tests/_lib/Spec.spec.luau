--!strict

local Spec = require("./Spec")

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Spec.run", function()
		it("reports passing and failing cases with their scoped names", function()
			local results = Spec.run(function(inner)
				inner.describe("outer", function()
					inner.it("passes", function() end)
					inner.it("fails", function()
						inner.expect(1).toBe(2)
					end)
				end)
			end)

			expect(#results).toBe(2)
			expect(results[1].name).toBe("outer > passes")
			expect(results[1].ok).toBe(true)
			expect(results[2].name).toBe("outer > fails")
			expect(results[2].ok).toBe(false)
			expect((string.find(results[2].message :: string, "1 to be 2", 1, true))).never.toBeNil()
		end)
	end)

	describe("expect", function()
		it("compares tables deeply with toEqual", function()
			expect({ a = { 1, 2 } }).toEqual({ a = { 1, 2 } })
			expect({ a = 1 }).never.toEqual({ a = 1, b = 2 })
		end)

		it("matches thrown errors against a pattern", function()
			expect(function()
				error("lease lost")
			end).toThrow("lease")
			expect(function() end).never.toThrow()
		end)

		it("fails a negated matcher when the value matches", function()
			expect(function()
				expect(nil).never.toBeNil()
			end).toThrow("expected not")
		end)
	end)
end
