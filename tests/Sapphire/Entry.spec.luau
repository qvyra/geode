--!strict

local Geode = require("../../src")
local Spec = require("../_lib/Spec")

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Geode.Profile", function()
		it("exposes the store constructor", function()
			expect(type(Geode.Profile.store)).toBe("function")
			local universe = Geode.Testing.universe()
			local store = Geode.Profile.store({
				name = "Entry",
				template = { coins = 0 },
				services = universe:server(),
				reportError = function() end,
			})
			local result = universe.clock:run(function()
				return store:load("p1")
			end)
			expect(result.ok).toBe(true)
		end)
	end)
end
