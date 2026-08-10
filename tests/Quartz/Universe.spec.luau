--!strict

local Fixture = require("./Contracts/Fixture")
local Geode = require("../../src")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")

local unwrap, errorKind = Fixture.unwrap, Fixture.errorKind

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Universe", function()
		it("shares data between servers", function()
			local universe = Universe.new()
			local a = universe:server()
			local b = universe:server()
			universe.clock:run(function()
				unwrap(a.dataStore("Players"):set("p1", "from a"))
				expect(unwrap(b.dataStore("Players"):get("p1")).value).toBe("from a")
				unwrap(a.hashMap("Presence"):set("p1", "a", 30))
				expect(unwrap(b.hashMap("Presence"):get("p1"))).toBe("a")
			end)
		end)

		it("gives each server its own job id", function()
			local universe = Universe.new()
			expect(universe:server().jobId == universe:server().jobId).toBe(false)
			expect(universe:server({ jobId = "named" }).jobId).toBe("named")
		end)

		it("delivers messages across servers after the configured latency", function()
			local universe = Universe.new({ messagingLatency = 2 })
			local a = universe:server()
			local b = universe:server()
			local heardAt: number? = nil
			universe.clock:run(function()
				unwrap(b.messaging:subscribe("release", function()
					heardAt = universe.clock:now()
				end))
				unwrap(a.messaging:publish("release", "p1"))
				universe.clock:wait(5)
			end)
			expect(heardAt).toBe(2)
		end)

		it("records teleports for assertions", function()
			local universe = Universe.new()
			local server = universe:server({ jobId = "lobby" })
			universe.clock:run(function()
				unwrap(server.teleport:teleport(42, { "p1", "p2" }))
			end)
			expect(#universe.teleports).toBe(1)
			expect(universe.teleports[1].fromJobId).toBe("lobby")
			expect(universe.teleports[1].players).toEqual({ "p1", "p2" })
		end)

		it("enforces key length and value size limits", function()
			local universe = Universe.new({
				limits = {
					keyLength = 5,
					valueSize = 10,
					measure = function(value)
						return #tostring(value)
					end,
				},
			})
			local store = universe:server().dataStore("Players")
			universe.clock:run(function()
				expect(errorKind(store:get("too_long"))).toBe("invalidKey")
				expect(errorKind(store:set("ok", string.rep("x", 11)))).toBe("tooLarge")
				expect(errorKind(store:set("ok", "short"))).toBeNil()
			end)
		end)
	end)

	describe("MemoryStore call limits", function()
		it("caps sorted map ranges at 200 and queue reads at 100", function()
			local universe = Universe.new()
			local server = universe:server()
			local map = server.sortedMap("Ladder")
			local queue = server.queue("Jobs")
			universe.clock:run(function()
				expect(errorKind(map:getRange({ count = 200 }))).toBeNil()
				expect(errorKind(map:getRange({ count = 201 }))).toBe("invalidValue")
				expect(errorKind(queue:read({ count = 100 }))).toBeNil()
				expect(errorKind(queue:read({ count = 101 }))).toBe("invalidValue")
				expect(errorKind(queue:read({ count = 0 }))).toBe("invalidValue")
			end)
		end)
	end)

	describe("MockServer.crash", function()
		it("leaves calls in flight unanswered", function()
			local universe = Universe.new()
			local server = universe:server()
			server:inject({ method = "set", fault = { latency = 5 } })
			local finished = false
			universe.clock:spawn(function()
				server.dataStore("Players"):set("p1", 1)
				finished = true
			end)
			server:crash()
			universe.clock:advance(10)
			-- The latency wait ends, but a dead server's next call never comes back
			expect(finished).toBe(true)

			local after = false
			universe.clock:spawn(function()
				server.dataStore("Players"):get("p1")
				after = true
			end)
			universe.clock:advance(10)
			expect(after).toBe(false)
			expect(server:isAlive()).toBe(false)
		end)

		it("stops its subscribers from hearing messages", function()
			local universe = Universe.new()
			local dead = universe:server()
			local live = universe:server()
			local heard = 0
			universe.clock:run(function()
				unwrap(dead.messaging:subscribe("t", function()
					heard += 1
				end))
			end)
			dead:crash()
			universe.clock:run(function()
				unwrap(live.messaging:publish("t", "x"))
				universe.clock:wait(1)
			end)
			expect(heard).toBe(0)
		end)
	end)

	describe("Geode entry points", function()
		it("exposes the real and mock constructors", function()
			expect(type(Geode.Raw.services)).toBe("function")
			expect(type(Geode.Raw.fromRoblox)).toBe("function")
			expect(Geode.Raw.classifyError("301: x").kind).toBe("throttled")
			expect(type(Geode.Raw.clock)).toBe("function")
			expect(type(Geode.Raw.scheduler)).toBe("function")
			expect(Geode.Testing.clock(5):now()).toBe(5)
			expect(type(Geode.Testing.universe():server().jobId)).toBe("string")
		end)

		it("freezes both tables", function()
			expect(table.isfrozen(Geode.Raw)).toBe(true)
			expect(table.isfrozen(Geode.Testing)).toBe(true)
		end)
	end)
end
