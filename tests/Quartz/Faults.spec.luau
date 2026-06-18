--!strict

local Fixture = require("./Contracts/Fixture")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")

local unwrap, errorKind = Fixture.unwrap, Fixture.errorKind

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("fault injection", function()
		it("throttles a method a fixed number of times", function()
			local universe = Universe.new()
			local server = universe:server()
			local store = server.dataStore("Players")
			server:inject({ method = "update", fault = "throttle", times = 2 })

			universe.clock:run(function()
				local first = store:update("p1", function()
					return 1
				end)
				expect(errorKind(first)).toBe("throttled")
				if not first.ok then
					expect(first.error.code).toBe(304)
				end
				expect(errorKind(store:update("p1", function()
					return 1
				end))).toBe("throttled")
				expect(errorKind(store:update("p1", function()
					return 1
				end))).toBeNil()
			end)
		end)

		it("matches keys by pattern and stores by name", function()
			local universe = Universe.new()
			local server = universe:server()
			server:inject({ store = "Players", key = "p%d+", fault = { code = 502 } })

			universe.clock:run(function()
				expect(errorKind(server.dataStore("Players"):get("p12"))).toBe("internal")
				expect(errorKind(server.dataStore("Players"):get("guild"))).toBeNil()
				expect(errorKind(server.dataStore("Other"):get("p12"))).toBeNil()
			end)
		end)

		it("filters by service", function()
			local universe = Universe.new()
			local server = universe:server()
			server:inject({ service = "hashMap", fault = "throttle" })

			universe.clock:run(function()
				expect(errorKind(server.hashMap("Sessions"):get("a"))).toBe("throttled")
				expect(errorKind(server.dataStore("Sessions"):get("a"))).toBeNil()
			end)
		end)

		it("adds latency on the virtual clock", function()
			local universe = Universe.new()
			local server = universe:server()
			server:inject({ method = "get", fault = { latency = 3 } })

			universe.clock:run(function()
				local started = universe.clock:now()
				unwrap(server.dataStore("Players"):get("p1"))
				expect(universe.clock:now() - started).toBe(3)
			end)
		end)

		it("lands a foreign write before the caller's transform", function()
			local universe = Universe.new()
			local server = universe:server()
			local store = server.dataStore("Players")
			server:inject({
				method = "update",
				times = 1,
				fault = {
					foreignWrite = function()
						return { owner = "other" }
					end,
				},
			})

			universe.clock:run(function()
				unwrap(store:set("p1", { owner = "me" }))
				local seen: unknown = nil
				unwrap(store:update("p1", function(current)
					seen = current
					return nil
				end))
				expect(seen).toEqual({ owner = "other" })
			end)
		end)

		it("reruns the transform when asked, stale value first", function()
			local universe = Universe.new()
			local server = universe:server()
			local store = server.dataStore("Players")
			server:inject({
				method = "update",
				times = 1,
				fault = {
					rerun = true,
					foreignWrite = function()
						return 2
					end,
				},
			})

			universe.clock:run(function()
				unwrap(store:set("p1", 1))
				local seen = {}
				local update = unwrap(store:update("p1", function(current)
					table.insert(seen, current)
					return (current :: number) * 10
				end))
				expect(seen).toEqual({ 1, 2 })
				expect(update.value).toBe(20)
			end)
		end)

		it("clears faults on demand", function()
			local universe = Universe.new()
			local server = universe:server()
			server:inject({ fault = "throttle" })
			server:clearFaults()

			universe.clock:run(function()
				expect(errorKind(server.dataStore("Players"):get("p1"))).toBeNil()
			end)
		end)

		it("only affects the server it was injected on", function()
			local universe = Universe.new()
			local a = universe:server()
			local b = universe:server()
			a:inject({ fault = "throttle" })

			universe.clock:run(function()
				expect(errorKind(a.dataStore("Players"):get("p1"))).toBe("throttled")
				expect(errorKind(b.dataStore("Players"):get("p1"))).toBeNil()
			end)
		end)
	end)
end
