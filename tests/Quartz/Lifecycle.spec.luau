--!strict

local FakeRoblox = require("./FakeRoblox")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Lifecycle adapter", function()
		it("runs close callbacks in their own threads when a mock server shuts down", function()
			local universe = Universe.new()
			local server = universe:server()
			local finished = {}
			server.lifecycle:bindToClose(function()
				universe.clock:wait(2)
				table.insert(finished, "slow")
			end)
			server.lifecycle:bindToClose(function()
				table.insert(finished, "fast")
			end)
			server:shutdown()
			expect(finished).toEqual({ "fast" })
			universe.clock:advance(2)
			expect(finished).toEqual({ "fast", "slow" })
		end)

		it("reports Studio as configured", function()
			local universe = Universe.new()
			expect(universe:server().lifecycle:isStudio()).toBe(false)
			expect(universe:server({ studio = true }).lifecycle:isStudio()).toBe(true)
		end)

		it("works through the real adapter too", function()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			local services = FakeRoblox.services(server)
			expect(services.lifecycle:isStudio()).toBe(true)
			local closed = false
			services.lifecycle:bindToClose(function()
				closed = true
			end)
			server:shutdown()
			expect(closed).toBe(true)
		end)
	end)
end
