--!strict

local MockClock = require("../../src/Quartz/Mock/Clock")
local Spec = require("../_lib/Spec")

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("MockClock", function()
		it("starts where it's told and only moves on advance", function()
			local clock = MockClock.new(100)
			expect(clock:now()).toBe(100)
			clock:advance(2.5)
			expect(clock:now()).toBe(102.5)
		end)

		it("wakes waiting threads in time order", function()
			local clock = MockClock.new()
			local order = {}
			clock:spawn(function()
				clock:wait(3)
				table.insert(order, "three")
			end)
			clock:spawn(function()
				clock:wait(1)
				table.insert(order, "one")
			end)
			clock:advance(2)
			expect(order).toEqual({ "one" })
			clock:advance(5)
			expect(order).toEqual({ "one", "three" })
			expect(clock:pending()).toBe(0)
		end)

		it("reports the wake up time to the woken thread", function()
			local clock = MockClock.new()
			local wokeAt = -1
			clock:spawn(function()
				clock:wait(4)
				wokeAt = clock:now()
			end)
			clock:advance(10)
			expect(wokeAt).toBe(4)
			expect(clock:now()).toBe(10)
		end)

		it("runs delayed calls when their time comes", function()
			local clock = MockClock.new()
			local fired = false
			clock:delay(5, function()
				fired = true
			end)
			clock:advance(4.9)
			expect(fired).toBe(false)
			clock:advance(0.1)
			expect(fired).toBe(true)
		end)

		it("run jumps between wake ups and returns the result", function()
			local clock = MockClock.new()
			local value = clock:run(function()
				clock:wait(30)
				clock:wait(30)
				return "done"
			end)
			expect(value).toBe("done")
			expect(clock:now()).toBe(60)
		end)

		it("refuses to wait outside a clock thread", function()
			local clock = MockClock.new()
			expect(function()
				clock:wait(1)
			end).toThrow("must run inside")
		end)

		it("errors when run would block forever", function()
			local clock = MockClock.new()
			expect(function()
				clock:run(function()
					coroutine.yield()
					return nil
				end)
			end).toThrow("blocked")
		end)

		it("surfaces errors from spawned threads", function()
			local clock = MockClock.new()
			expect(function()
				clock:spawn(function()
					error("boom")
				end)
			end).toThrow("boom")
		end)
	end)
end
