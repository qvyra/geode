--!strict

local Cpu = require("./Cpu")
local Spec = require("../_lib/Spec")

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Geode edit timings", function()
		it("times every batch and applies every edit", function()
			local now = 0
			local report = Cpu.run(function(): number
				now += 1
				return now
			end)
			expect(#report.batches).toBe(5)
			expect(report.batches[1]).toBe(1)
			expect(report.coins).toBe(report.edits)
			expect(report.edits).toBe(6 * report.editsPerBatch)
		end)
	end)
end
