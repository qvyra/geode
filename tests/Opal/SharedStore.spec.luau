--!strict

local Guards = require("../../src/Obsidian/Guards")
local SharedStore = require("../../src/Opal/SharedStore")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")

type Any = any

local function make(
	server: Universe.MockServer,
	extra: { [string]: any }?
): (SharedStore.SharedStore, { string })
	local reported = {}
	local options: { [string]: any } = {
		name = "Guilds",
		template = { bank = 0, members = {} },
		services = server,
		reportError = function(message: string)
			table.insert(reported, message)
		end,
	}
	local overrides: { [string]: any } = extra or {}
	for key, value in overrides do
		options[key] = value
	end
	return SharedStore.new(options :: any), reported
end

local function stored(universe: Universe.Universe, key: string): Any
	local reader = universe:server({ jobId = "reader" })
	local found = nil
	universe.clock:spawn(function()
		local result = reader.dataStore("Guilds"):get(key)
		if result.ok then
			found = result.value.value
		end
	end)
	return found
end

local function value(result: SharedStore.ReadResult): Any
	if not result.ok then
		error(`read failed: {result.error.message}`, 2)
	end
	return result.value
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("shared store writes", function()
		it("starts from the template and writes through UpdateAsync", function()
			local universe = Universe.new()
			local guilds = make(universe:server())
			universe.clock:run(function()
				expect(guilds:increment("g1", "bank", 50).ok).toBe(true)
				expect(guilds:append("g1", "members", "ana").ok).toBe(true)
				expect(value(guilds:get("g1", "bank"))).toBe(50)
			end)
			local record = stored(universe, "g1")
			expect(record.data).toEqual({ bank = 50, members = { "ana" } })
			expect(record.meta.revision).toBe(2)
		end)

		it("never loses a write when servers race", function()
			local universe = Universe.new()
			local serverA = universe:server({ jobId = "A" })
			local serverB = universe:server({ jobId = "B" })
			local guildsA = make(serverA)
			local guildsB = make(serverB)
			for index = 1, 10 do
				universe.clock:spawn(function()
					guildsA:increment("g1", "bank", 1)
				end)
				universe.clock:spawn(function()
					guildsB:increment("g1", "bank", 1)
				end)
				if index % 3 == 0 then
					-- Another server lands a write first and our transform reruns on fresh data
					serverA:inject({
						method = "update",
						times = 1,
						fault = {
							foreignWrite = function(current: Any)
								local nextValue: Any = table.clone(current)
								nextValue.data = table.clone(current.data)
								nextValue.data.bank += 100
								return nextValue
							end,
							rerun = true,
						},
					})
				end
			end
			universe.clock:advance(60)
			expect(stored(universe, "g1").data.bank).toBe(20 + 300)
		end)

		it("fires listeners and deferred effects once even when the transform reruns", function()
			local universe = Universe.new()
			local server = universe:server()
			local guilds = make(server)
			universe.clock:run(function()
				guilds:increment("g1", "bank", 1)
			end)
			local heard, deferred = 0, 0
			guilds:observe("g1", "bank", function()
				heard += 1
			end)
			server:inject({
				method = "update",
				times = 1,
				fault = {
					foreignWrite = function(current: Any)
						return current
					end,
					rerun = true,
				},
			})
			universe.clock:run(function()
				guilds:transact("g1", function(tx)
					tx:increment("bank", 5)
					tx:defer(function()
						deferred += 1
					end)
				end)
			end)
			expect(heard).toBe(1)
			expect(deferred).toBe(1)
		end)

		it("counts a rate guard once per write that landed", function()
			local universe = Universe.new()
			local server = universe:server()
			local guilds =
				make(server, { guards = { Guards.rate("bank", { count = 2, window = 60 }) } })
			server:inject({
				method = "update",
				times = 2,
				fault = {
					foreignWrite = function(current: Any)
						return current
					end,
					rerun = true,
				},
			})
			universe.clock:run(function()
				expect(guilds:increment("g1", "bank", 1).ok).toBe(true)
				expect(guilds:increment("g1", "bank", 1).ok).toBe(true)
				expect(guilds:increment("g1", "bank", 1).ok).toBe(false)
			end)
		end)

		it("leaves the stored value alone when a guard rejects", function()
			local universe = Universe.new()
			local guilds =
				make(universe:server(), { guards = { Guards.range("bank", { min = 0 }) } })
			universe.clock:run(function()
				guilds:increment("g1", "bank", 10)
				local result = guilds:decrement("g1", "bank", 50)
				expect(result.ok).toBe(false)
				if not result.ok then
					expect(result.error.kind).toBe("rejected")
				end
			end)
			expect(stored(universe, "g1").data.bank).toBe(10)
		end)

		it("fails a transaction that yields instead of writing", function()
			local universe = Universe.new()
			local server = universe:server()
			local guilds = make(server, {
				guards = {
					Guards.custom(function()
						coroutine.yield()
						return true
					end),
				},
			})
			universe.clock:run(function()
				local result = guilds:increment("g1", "bank", 1)
				expect(result.ok).toBe(false)
				if not result.ok then
					expect((string.find(result.error.message, "synchronous", 1, true))).never.toBeNil()
				end
			end)
			universe.clock:advance(5)
			expect(stored(universe, "g1")).toBeNil()
		end)

		it("refuses keys holding something else", function()
			local universe = Universe.new()
			local server = universe:server()
			universe.clock:run(function()
				server.dataStore("Guilds"):set("g1", "not a record")
			end)
			local guilds = make(server)
			universe.clock:run(function()
				local result = guilds:increment("g1", "bank", 1)
				expect(result.ok).toBe(false)
				if not result.ok then
					expect(result.error.kind).toBe("corrupt")
				end
			end)
			expect(stored(universe, "g1")).toBe("not a record")
		end)

		it("refuses writes past the hard size budget", function()
			local universe = Universe.new()
			local guilds = make(universe:server(), { sizeBudget = { soft = 100, hard = 150 } })
			universe.clock:run(function()
				local result = guilds:append("g1", "members", string.rep("x", 200))
				expect(result.ok).toBe(false)
				if not result.ok then
					expect(result.error.kind).toBe("tooLarge")
				end
			end)
			expect(stored(universe, "g1")).toBeNil()
		end)
	end)

	describe("shared store failures", function()
		it("tells deferred callbacks nothing committed when the write is refused", function()
			local universe = Universe.new()
			local guilds = make(universe:server(), { sizeBudget = { soft = 100, hard = 150 } })
			local outcomes = {}
			universe.clock:run(function()
				guilds:transact("g1", function(tx)
					tx:append("members", string.rep("x", 200))
					tx:defer(function(outcome)
						table.insert(outcomes, outcome.committed)
					end)
				end)
			end)
			expect(outcomes).toEqual({ false })
		end)

		it("doesn't serve the template as data when the first read fails", function()
			local universe = Universe.new()
			local server = universe:server()
			local guilds = make(server)
			guilds:observe("g1", "bank", function() end)
			server:inject({ method = "get", fault = { code = 403 } })
			universe.clock:run(function()
				expect(guilds:get("g1").ok).toBe(false)
			end)
		end)
	end)

	describe("shared store reads", function()
		it("serves the cache until it expires", function()
			local universe = Universe.new()
			local guildsA =
				make(universe:server({ jobId = "A" }), { cacheTtl = 10, invalidate = false })
			local guildsB = make(universe:server({ jobId = "B" }), { invalidate = false })
			universe.clock:run(function()
				expect(value(guildsA:get("g1", "bank"))).toBe(0)
				guildsB:increment("g1", "bank", 7)
				expect(value(guildsA:get("g1", "bank"))).toBe(0)
			end)
			universe.clock:advance(10)
			universe.clock:run(function()
				expect(value(guildsA:get("g1", "bank"))).toBe(7)
			end)
		end)

		it("drops the cache sooner when another server says it changed", function()
			local universe = Universe.new({ messagingLatency = 0.1 })
			local guildsA = make(universe:server({ jobId = "A" }), { cacheTtl = 1000 })
			local guildsB = make(universe:server({ jobId = "B" }))
			universe.clock:run(function()
				expect(value(guildsA:get("g1", "bank"))).toBe(0)
				guildsB:increment("g1", "bank", 7)
			end)
			universe.clock:advance(1)
			universe.clock:run(function()
				expect(value(guildsA:get("g1", "bank"))).toBe(7)
			end)
		end)

		it("serves a stale value when a refresh fails", function()
			local universe = Universe.new()
			local server = universe:server()
			local guilds, reported = make(server, { cacheTtl = 1 })
			universe.clock:run(function()
				guilds:increment("g1", "bank", 3)
			end)
			universe.clock:advance(2)
			server:inject({ method = "get", fault = { code = 403 } })
			universe.clock:run(function()
				expect(value(guilds:get("g1", "bank"))).toBe(3)
			end)
			expect(#reported).toBe(1)
		end)
	end)
end
