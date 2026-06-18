--!strict

local Fixture = require("./Fixture")
local Spec = require("../../_lib/Spec")

local unwrap = Fixture.unwrap

return function(spec: Spec.Api, label: string, make: Fixture.MakeFixture)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe(`OrderedDataStore contract ({label})`, function()
		it("sets, gets, increments and removes integers", function()
			local fixture = make()
			local board = fixture.services.orderedDataStore("Wins")
			fixture.clock:run(function()
				expect(unwrap(board:get("p1"))).toBeNil()
				unwrap(board:set("p1", 5))
				expect(unwrap(board:increment("p1", 2))).toBe(7)
				expect(unwrap(board:remove("p1"))).toBe(7)
				expect(unwrap(board:get("p1"))).toBeNil()
			end)
		end)

		it("updates and cancels", function()
			local fixture = make()
			local board = fixture.services.orderedDataStore("Wins")
			fixture.clock:run(function()
				unwrap(board:set("p1", 1))
				local update = unwrap(board:update("p1", function(current)
					return (current or 0) + 10
				end))
				expect(update.value).toBe(11)
				local cancelled = unwrap(board:update("p1", function()
					return nil
				end))
				expect(cancelled.cancelled).toBe(true)
				expect(cancelled.value).toBe(11)
			end)
		end)

		it("sorts in both directions with bounds and limits across pages", function()
			local fixture = make()
			local board = fixture.services.orderedDataStore("Wins")
			fixture.clock:run(function()
				for index = 1, 12 do
					unwrap(board:set(`p{index}`, index * 10))
				end

				local top = unwrap(board:getSorted({ ascending = false, limit = 3 }))
				expect(#top).toBe(3)
				expect(top[1]).toEqual({ key = "p12", value = 120 })
				expect(top[3].value).toBe(100)

				local bounded = unwrap(board:getSorted({ min = 30, max = 50 }))
				expect(#bounded).toBe(3)
				expect(bounded[1].value).toBe(30)

				expect(#unwrap(board:getSorted({ limit = 11 }))).toBe(11)
			end)
		end)
	end)
end
