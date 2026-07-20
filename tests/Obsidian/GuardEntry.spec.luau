--!strict

local Geode = require("../../src")
local Spec = require("../_lib/Spec")

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Geode.guard and Geode.Raw.guards", function()
		it("build guards and guard sets that work on a raw document", function()
			local doc = Geode.Raw.document({ data = { coins = 0 }, reportError = function() end })
			local guards = Geode.Raw.guards({
				guards = { Geode.guard.range("coins", { min = 0 }) },
				reportError = function() end,
			})
			guards:attach(doc)
			expect(doc:decrement("coins").ok).toBe(false)
			expect(doc:increment("coins").ok).toBe(true)
			for _, name in
				{ "range", "delta", "rate", "rateValue", "requires", "subset", "schema", "custom" }
			do
				expect(type((Geode.guard :: any)[name])).toBe("function")
			end
			expect(table.isfrozen(Geode.guard)).toBe(true)
		end)
	end)
end
