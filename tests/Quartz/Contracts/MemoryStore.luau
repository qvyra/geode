--!strict

local Fixture = require("./Fixture")
local Spec = require("../../_lib/Spec")
local Types = require("../../../src/Quartz/Types")

local unwrap = Fixture.unwrap

return function(spec: Spec.Api, label: string, make: Fixture.MakeFixture)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe(`HashMap contract ({label})`, function()
		it("stores values until their ttl runs out", function()
			local fixture = make()
			local map = fixture.services.hashMap("Sessions")
			fixture.clock:run(function()
				unwrap(map:set("p1", { server = "a" }, 10))
				expect(unwrap(map:get("p1"))).toEqual({ server = "a" })
				fixture.clock:wait(11)
				expect(unwrap(map:get("p1"))).toBeNil()
			end)
		end)

		it("updates, cancels and removes", function()
			local fixture = make()
			local map = fixture.services.hashMap("Counts")
			fixture.clock:run(function()
				local first = unwrap(map:update("n", function(current)
					return ((current :: number?) or 0) + 1
				end, 60))
				expect(first.value).toBe(1)
				local cancelled = unwrap(map:update("n", function()
					return nil
				end, 60))
				expect(cancelled.cancelled).toBe(true)
				expect(cancelled.value).toBe(1)
				unwrap(map:remove("n"))
				expect(unwrap(map:get("n"))).toBeNil()
			end)
		end)

		it("lists live items", function()
			local fixture = make()
			local map = fixture.services.hashMap("Items")
			fixture.clock:run(function()
				unwrap(map:set("a", 1, 60))
				unwrap(map:set("b", 2, 60))
				unwrap(map:set("c", 3, 1))
				fixture.clock:wait(2)
				local entries = unwrap(map:list())
				expect(#entries).toBe(2)
			end)
		end)
	end)

	describe(`SortedMap contract ({label})`, function()
		it("orders by sort key, then key, in both directions", function()
			local fixture = make()
			local map = fixture.services.sortedMap("Ladder")
			fixture.clock:run(function()
				unwrap(map:set("b", "B", 60, 5))
				unwrap(map:set("a", "A", 60, 5))
				unwrap(map:set("c", "C", 60, 1))

				local ascending = unwrap(map:getRange({ count = 10 }))
				expect(ascending[1].key).toBe("c")
				expect(ascending[2].key).toBe("a")
				expect(ascending[3].key).toBe("b")

				local descending = unwrap(map:getRange({ count = 2, descending = true }))
				expect(#descending).toBe(2)
				expect(descending[1].key).toBe("b")
			end)
		end)

		it("puts numeric sort keys first, then strings, then items without one", function()
			local fixture = make()
			local map = fixture.services.sortedMap("Ladder")
			fixture.clock:run(function()
				unwrap(map:set("none", 0, 60))
				unwrap(map:set("text", 0, 60, "a"))
				unwrap(map:set("number", 0, 60, 99))
				unwrap(map:set("alsoNone", 0, 60))
				local keys = {}
				for _, entry in unwrap(map:getRange({ count = 10 })) do
					table.insert(keys, entry.key)
				end
				expect(keys).toEqual({ "number", "text", "alsoNone", "none" })
			end)
		end)

		it("excludes the bounds it's given", function()
			local fixture = make()
			local map = fixture.services.sortedMap("Ladder")
			fixture.clock:run(function()
				for index = 1, 5 do
					unwrap(map:set(`k{index}`, index, 60, index))
				end
				local middle = unwrap(map:getRange({
					count = 10,
					lower = { sortKey = 1 },
					upper = { sortKey = 5 },
				}))
				expect(#middle).toBe(3)
				expect(middle[1].sortKey).toBe(2)
			end)
		end)

		it("places bounds that hold only a key or only a sort key", function()
			local fixture = make()
			local map = fixture.services.sortedMap("Bounds")
			fixture.clock:run(function()
				unwrap(map:set("a", 1, 60, 5))
				unwrap(map:set("b", 1, 60, 1))
				unwrap(map:set("c", 1, 60, 9))
				unwrap(map:set("d", 1, 60))
				unwrap(map:set("e", 1, 60, 5))
				local function keys(range: Types.SortedRange): { string }
					local found = {}
					for _, entry in unwrap(map:getRange(range)) do
						table.insert(found, entry.key)
					end
					return found
				end
				-- Only a key: the bound sits where that key without a sort key would
				expect(keys({ count = 10, lower = { key = "a" } })).toEqual({ "d" })
				expect(keys({ count = 10, upper = { key = "d" } })).toEqual({ "b", "a", "e", "c" })
				-- Only a sort key: that whole sort-key group is left out.
				-- Roblox doesn't document this one
				expect(keys({ count = 10, lower = { sortKey = 5 } })).toEqual({ "c", "d" })
				expect(keys({ count = 10, upper = { sortKey = 5 } })).toEqual({ "b" })
				expect(keys({ count = 10, lower = { key = "a", sortKey = 5 } })).toEqual({
					"e",
					"c",
					"d",
				})
			end)
		end)

		it("gets, updates sort keys and expires", function()
			local fixture = make()
			local map = fixture.services.sortedMap("Ladder")
			fixture.clock:run(function()
				unwrap(map:set("p1", "x", 5, 10))
				local entry = unwrap(map:get("p1"))
				expect(entry and entry.sortKey).toBe(10)

				local update = unwrap(map:update("p1", function(current, sortKey)
					return current, ((sortKey :: number?) or 0) + 1
				end, 5))
				expect(update.sortKey).toBe(11)

				fixture.clock:wait(6)
				expect(unwrap(map:get("p1"))).toBeNil()
			end)
		end)
	end)

	describe(`Queue contract ({label})`, function()
		it("hands out items by priority, then age", function()
			local fixture = make()
			local queue = fixture.services.queue("Jobs", 30)
			fixture.clock:run(function()
				unwrap(queue:add("low", 60, 0))
				unwrap(queue:add("high", 60, 5))
				unwrap(queue:add("low2", 60, 0))
				local read = unwrap(queue:read({ count = 3 }))
				expect(read.items).toEqual({ "high", "low", "low2" })
			end)
		end)

		it("hides read items until the invisibility timeout, then shows them again", function()
			local fixture = make()
			local queue = fixture.services.queue("Jobs", 10)
			fixture.clock:run(function()
				unwrap(queue:add("job", 60))
				expect(#unwrap(queue:read({ count = 1 })).items).toBe(1)
				expect(#unwrap(queue:read({ count = 1 })).items).toBe(0)
				fixture.clock:wait(11)
				expect(#unwrap(queue:read({ count = 1 })).items).toBe(1)
			end)
		end)

		it("doesn't remove items once their read has timed out", function()
			local fixture = make()
			local queue = fixture.services.queue("Jobs", 10)
			fixture.clock:run(function()
				unwrap(queue:add("job", 60))
				local read = unwrap(queue:read({ count = 1 }))
				fixture.clock:wait(11)
				unwrap(queue:remove(read.id :: string))
				expect(#unwrap(queue:read({ count = 1 })).items).toBe(1)
			end)
		end)

		it("ignores an old read id once the items were read again", function()
			local fixture = make()
			local queue = fixture.services.queue("Jobs", 5)
			fixture.clock:run(function()
				unwrap(queue:add("job", 120))
				local first = unwrap(queue:read({ count = 1 }))
				fixture.clock:wait(6)
				local second = unwrap(queue:read({ count = 1 }))
				expect(#second.items).toBe(1)
				expect(second.id ~= first.id).toBe(true)
				unwrap(queue:remove(first.id :: string))
				fixture.clock:wait(6)
				expect(#unwrap(queue:read({ count = 1 })).items).toBe(1)
			end)
		end)

		it("removes acknowledged items for good", function()
			local fixture = make()
			local queue = fixture.services.queue("Jobs", 10)
			fixture.clock:run(function()
				unwrap(queue:add("job", 60))
				local read = unwrap(queue:read({ count = 1 }))
				unwrap(queue:remove(read.id :: string))
				fixture.clock:wait(11)
				expect(#unwrap(queue:read({ count = 1 })).items).toBe(0)
			end)
		end)

		it("waits for items up to the timeout", function()
			local fixture = make()
			local queue = fixture.services.queue("Jobs", 10)
			fixture.clock:delay(2, function()
				unwrap(queue:add("late", 60))
			end)
			local read = fixture.clock:run(function()
				return unwrap(queue:read({ count = 1, waitTimeout = 5 }))
			end)
			expect(read.items).toEqual({ "late" })
		end)

		it("returns nothing when all or nothing can't be met", function()
			local fixture = make()
			local queue = fixture.services.queue("Jobs", 10)
			fixture.clock:run(function()
				unwrap(queue:add("only", 60))
				local read = unwrap(queue:read({ count = 2, allOrNothing = true }))
				expect(#read.items).toBe(0)
				expect(read.id).toBeNil()
			end)
		end)
	end)
end
