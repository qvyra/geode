--!strict

local FakeRoblox = require("./FakeRoblox")
local Fixture = require("./Contracts/Fixture")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")

local unwrap, errorKind = Fixture.unwrap, Fixture.errorKind

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("mock request budget", function()
		it("is unlimited until set", function()
			local universe = Universe.new()
			local server = universe:server()
			expect(server.budget:get("get")).toBe(math.huge)
		end)

		it("is used up by calls and throttles once empty", function()
			local universe = Universe.new()
			local server = universe:server()
			local store = server.dataStore("Players")
			server:setBudget("get", 2)
			universe.clock:run(function()
				unwrap(store:get("a"))
				unwrap(store:get("b"))
				expect(server.budget:get("get")).toBe(0)
				local third = store:get("c")
				expect(errorKind(third)).toBe("throttled")
				if not third.ok then
					expect(third.error.code).toBe(301)
				end
			end)
		end)

		it("refills over time", function()
			local universe = Universe.new()
			local server = universe:server()
			server:setBudget("setIncrement", 0, 2)
			universe.clock:advance(1.5)
			expect(server.budget:get("setIncrement")).toBe(3)
		end)

		it("charges each call to its own budget", function()
			local universe = Universe.new()
			local server = universe:server()
			local store = server.dataStore("Players")
			server:setBudget("update", 0)
			universe.clock:run(function()
				expect(errorKind(store:get("a"))).toBeNil()
				expect(errorKind(store:update("a", function()
					return 1
				end))).toBe("throttled")
			end)
		end)

		it("is read through the real adapter too", function()
			local universe = Universe.new()
			local server = universe:server()
			server:setBudget("get", 7)
			local services = FakeRoblox.services(server)
			expect(services.budget:get("get")).toBe(7)
		end)
	end)
end
