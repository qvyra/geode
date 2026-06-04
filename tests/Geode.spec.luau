--!strict

local Geode = require("../src")
local Spec = require("./_lib/Spec")

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Geode", function()
		it("exposes a semantic version", function()
			expect(string.match(Geode.version, "^%d+%.%d+%.%d+$")).never.toBeNil()
		end)

		it("is frozen so callers can't patch the public surface", function()
			expect(table.isfrozen(Geode)).toBe(true)
		end)
	end)
end
