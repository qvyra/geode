--!strict

local FakeRoblox = require("./FakeRoblox")
local Fixture = require("./Contracts/Fixture")
local Signal = require("../../src/Quartz/Signal")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")

local unwrap = Fixture.unwrap

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Signal", function()
		it("calls handlers in connection order with the fired values", function()
			local signal = Signal.new()
			local seen = {}
			signal:connect(function(a, b)
				table.insert(seen, `first {a} {b}`)
			end)
			signal:connect(function(a)
				table.insert(seen, `second {a}`)
			end)
			signal:fire(1, 2)
			expect(seen).toEqual({ "first 1 2", "second 1" })
			expect(signal:handlerCount()).toBe(2)
		end)

		it("reports a failing handler and keeps calling the rest", function()
			local reported = {}
			local signal = Signal.new(function(message)
				table.insert(reported, message)
			end)
			local reached = false
			signal:connect(function()
				error("broken handler")
			end)
			signal:connect(function()
				reached = true
			end)
			signal:fire()
			expect(reached).toBe(true)
			expect(#reported).toBe(1)
		end)

		it("stops calling a handler once disconnected, even mid fire", function()
			local signal = Signal.new()
			local count = 0
			local second
			signal:connect(function()
				second:disconnect()
			end)
			second = signal:connect(function()
				count += 1
			end)
			signal:fire()
			signal:fire()
			expect(count).toBe(0)
			expect(signal:handlerCount()).toBe(1)
		end)
	end)

	describe("Players adapter", function()
		it("records kicks in a mock universe", function()
			local universe = Universe.new()
			local server = universe:server({ jobId = "lobby" })
			unwrap(server.players:kick(5, "cheating"))
			expect(universe.kicks).toEqual({ { jobId = "lobby", userId = 5, reason = "cheating" } })
		end)

		it("kicks through the real adapter too", function()
			local universe = Universe.new()
			local services = FakeRoblox.services(universe:server())
			unwrap(services.players:kick(8, "bye"))
			expect(#universe.kicks).toBe(1)
			expect(universe.kicks[1].userId).toBe(8)
		end)
	end)
end
