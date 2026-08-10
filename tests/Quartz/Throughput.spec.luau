--!strict

local Fixture = require("./Contracts/Fixture")
local Spec = require("../_lib/Spec")
local Throughput = require("../../src/Quartz/Throughput")
local Universe = require("../../src/Quartz/Mock/Universe")

local unwrap, errorKind = Fixture.unwrap, Fixture.errorKind

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Throughput", function()
		it("rounds every request up to the next kilobyte", function()
			expect(Throughput.kilobytes(0)).toBe(1)
			expect(Throughput.kilobytes(1)).toBe(1)
			expect(Throughput.kilobytes(1024)).toBe(1)
			expect(Throughput.kilobytes(1025)).toBe(2)
		end)

		it("refuses what doesn't fit until the oldest use leaves the window", function()
			local tracker = Throughput.tracker(10, 60)
			tracker:add(0, 6)
			tracker:add(30, 3)
			local fits, retryAt = tracker:room(40, 2)
			expect(fits).toBe(false)
			expect(retryAt).toBe(60)
			expect((tracker:room(60, 2))).toBe(true)
			expect(tracker:used(60)).toBe(3)
		end)

		it("lets one oversized request through an empty window", function()
			local tracker = Throughput.tracker(10, 60)
			expect((tracker:room(0, 50))).toBe(true)
		end)
	end)

	describe("mock key throughput", function()
		local function measure(value: unknown): number
			return if type(value) == "string" then #value else 8
		end

		it("throttles a key that writes past 4 MB a minute", function()
			local universe = Universe.new({ limits = { measure = measure, keyThroughput = true } })
			local server = universe:server()
			local store = server.dataStore("Players")
			local big = string.rep("x", 2 * 1024 * 1024)
			universe.clock:run(function()
				unwrap(store:set("p1", big))
				unwrap(store:set("p1", big))
				local third = store:set("p1", "small")
				expect(errorKind(third)).toBe("throttled")
				unwrap(store:set("p2", "other keys are unaffected"))
				universe.clock:wait(60)
				unwrap(store:set("p1", "small"))
			end)
		end)

		it("is off unless turned on", function()
			local universe = Universe.new({ limits = { measure = measure } })
			local server = universe:server()
			local store = server.dataStore("Players")
			local big = string.rep("x", 3 * 1024 * 1024)
			universe.clock:run(function()
				for _ = 1, 3 do
					unwrap(store:set("p1", big))
				end
			end)
		end)
	end)
end
