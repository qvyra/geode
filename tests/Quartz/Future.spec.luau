--!strict

local Future = require("../../src/Quartz/Future")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Future", function()
		it("returns right away once resolved", function()
			local universe = Universe.new()
			local future = Future.new(universe:server().clock)
			future:resolve("ready")
			expect(future:isDone()).toBe(true)
			expect(future:await()).toBe("ready")
		end)

		it("wakes every waiter when resolved, and ignores later values", function()
			local universe = Universe.new()
			local future = Future.new(universe:server().clock)
			local seen = {}
			for index = 1, 2 do
				universe.clock:spawn(function()
					seen[index] = future:await()
				end)
			end
			expect(#seen).toBe(0)
			future:resolve("first")
			future:resolve("second")
			universe.clock:advance(0)
			expect(seen).toEqual({ "first", "first" })
		end)
	end)
end
