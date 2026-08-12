--!strict

local Guards = require("../../src/Obsidian/Guards")
local Helpers = require("./Helpers")
local Lune = require("../Obsidian/LuneDatatypes")
local Profile = require("../../src/Sapphire/Profile")
local ProfileStore = require("../../src/Sapphire/ProfileStore")
local Record = require("../../src/Sapphire/Record")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")
local t = require("../../src/Obsidian/Schema")

type Any = any

local function load(
	universe: Universe.Universe,
	store: ProfileStore.ProfileStore,
	key: string,
	userId: number?
): Profile.Profile
	local result = universe.clock:run(function()
		return store:load(key, { userId = userId })
	end)
	if not result.ok then
		error(`load failed: {result.error.kind} {result.error.message}`, 2)
	end
	return result.profile
end

local function errorKind(result: ProfileStore.LoadResult): string?
	if result.ok then
		return nil
	end
	return result.error.kind
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("loading", function()
		it("creates a record from the template and takes the lease", function()
			local universe = Universe.new()
			local server = universe:server({ jobId = "A" })
			local store = Helpers.store(server)
			local profile = load(universe, store, "p1", 1)

			expect(profile:get("coins")).toBe(0)
			local record = Helpers.stored(universe, "p1") :: Record.Record
			local lease = record.meta.lease :: Record.Lease
			expect(lease.jobId).toBe("A")
			expect(lease.session).toBe((record.meta.lastSession :: Record.LastSession).session)
			expect(record.meta.revision).toBe(0)
			expect(record.data).toEqual({ coins = 0, log = {} })
			expect(store:get("p1")).toBe(profile)
		end)

		it("loads saved data and keeps counting revisions", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server())
			local first = load(universe, store, "p1")
			first:increment("coins", 5)
			first:increment("coins", 5)
			universe.clock:run(function()
				return first:release()
			end)

			local second = load(universe, store, "p1")
			expect(second:get("coins")).toBe(10)
			expect(second:revision()).toBe(2)
		end)

		it("refuses to load a key twice on one server", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server())
			load(universe, store, "p1")
			local again = universe.clock:run(function()
				return store:load("p1")
			end)
			expect(errorKind(again)).toBe("alreadyLoaded")
		end)

		it("leaves records it doesn't recognize untouched", function()
			local universe = Universe.new()
			local server = universe:server()
			universe.clock:run(function()
				return server.dataStore(Helpers.STORE):set("p1", "not a record")
			end)
			local store = Helpers.store(server)
			local result = universe.clock:run(function()
				return store:load("p1")
			end)
			expect(errorKind(result)).toBe("corrupt")
			expect(Helpers.stored(universe, "p1") :: unknown).toBe("not a record")
		end)
	end)

	describe("saving", function()
		it("autosaves on the interval and renews the lease", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server())
			local profile = load(universe, store, "p1")
			profile:increment("coins", 3)
			expect(profile:isSaved()).toBe(false)

			universe.clock:advance(10)
			local record = Helpers.stored(universe, "p1") :: Record.Record
			expect((record.data :: Any).coins).toBe(3)
			expect(record.meta.revision).toBe(1)
			expect((record.meta.lease :: Record.Lease).renewedAt).toBe(10)
			expect(profile:isSaved()).toBe(true)
		end)

		it(
			"keeps data in memory and the lease alive when the record outgrows the hard limit",
			function()
				local universe = Universe.new()
				local store, reported =
					Helpers.store(universe:server(), { sizeBudget = { hard = 120 } })
				local profile = load(universe, store, "p1")
				profile:append("log", string.rep("x", 200))
				universe.clock:advance(5)
				local result = universe.clock:run(function()
					return profile:save()
				end)
				expect(result.ok).toBe(false)
				if not result.ok then
					expect(result.error.kind).toBe("tooLarge")
				end
				local record = Helpers.stored(universe, "p1") :: Record.Record
				expect(#(record.data :: Any).log).toBe(0)
				expect((record.meta.lease :: Record.Lease).renewedAt > 0).toBe(true)
				expect(#reported > 0).toBe(true)

				local release = universe.clock:run(function()
					return profile:release()
				end)
				expect(release.ok).toBe(false)
				expect(profile:isActive()).toBe(true)
				expect(profile:append("log", "still writable").ok).toBe(true)
			end
		)
	end)

	describe("releasing", function()
		it("saves, clears the lease and closes the profile", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server())
			local profile = load(universe, store, "p1")
			local releasedFired = false
			profile.released:connect(function()
				releasedFired = true
			end)
			profile:increment("coins", 7)
			local result = universe.clock:run(function()
				return profile:release()
			end)
			expect(result.ok).toBe(true)
			expect(releasedFired).toBe(true)
			expect(profile:state()).toBe("released")
			expect(store:get("p1")).toBeNil()

			local record = Helpers.stored(universe, "p1") :: Record.Record
			expect(record.meta.lease).toBeNil()
			expect((record.data :: Any).coins).toBe(7)
			expect(profile:increment("coins").ok).toBe(false)
		end)

		it("goes back to active when the final write fails, and succeeds on retry", function()
			local universe = Universe.new()
			local server = universe:server()
			local store = Helpers.store(server)
			local profile = load(universe, store, "p1")
			profile:increment("coins", 2)
			server:inject({ method = "update", fault = "throttle", times = 5 })

			local first = universe.clock:run(function()
				return profile:release()
			end)
			expect(first.ok).toBe(false)
			expect(profile:isActive()).toBe(true)
			expect(profile:get("coins")).toBe(2)

			local second = universe.clock:run(function()
				return profile:release()
			end)
			expect(second.ok).toBe(true)
			expect(((Helpers.stored(universe, "p1") :: Record.Record).data :: Any).coins).toBe(2)
		end)

		it("releases every profile on shutdown", function()
			local universe = Universe.new()
			local server = universe:server()
			local store = Helpers.store(server)
			local one = load(universe, store, "p1")
			local two = load(universe, store, "p2")
			one:increment("coins")
			two:increment("coins", 2)
			server:shutdown()
			universe.clock:advance(20)

			expect(store:openCount()).toBe(0)
			for _, key in { "p1", "p2" } do
				local record = Helpers.stored(universe, key) :: Record.Record
				expect(record.meta.lease).toBeNil()
			end
			expect(((Helpers.stored(universe, "p2") :: Record.Record).data :: Any).coins).toBe(2)
		end)
	end)

	describe("leases held elsewhere", function()
		it("fails after stealAfter with the fail policy", function()
			local universe = Universe.new()
			local a = Helpers.store(universe:server({ jobId = "A" }), { autosaveInterval = 30 })
			local b = Helpers.store(
				universe:server({ jobId = "B" }),
				{ stealPolicy = "fail", autosaveInterval = 30 }
			)
			load(universe, a, "p1")
			local result = universe.clock:run(function()
				return b:load("p1")
			end)
			expect(errorKind(result)).toBe("leaseHeld")
			expect(universe.clock:now() >= 5).toBe(true)
		end)

		it("waits for the holder to release with the wait policy", function()
			local universe = Universe.new()
			local a = Helpers.store(universe:server({ jobId = "A" }), { autosaveInterval = 30 })
			local b = Helpers.store(
				universe:server({ jobId = "B" }),
				{ stealPolicy = "wait", autosaveInterval = 30 }
			)
			local held = load(universe, a, "p1")
			held:increment("coins", 4)
			universe.clock:delay(8, function()
				held:release()
			end)
			local taken = load(universe, b, "p1")
			expect(taken:get("coins")).toBe(4)
			expect(universe.clock:now() >= 8).toBe(true)
		end)

		it("steals with the steal policy, and the old holder loses its session", function()
			local universe = Universe.new()
			local a = Helpers.store(universe:server({ jobId = "A" }))
			local b = Helpers.store(universe:server({ jobId = "B" }))
			local old = load(universe, a, "p1", 77)
			local lostReason: string? = nil
			old.sessionLost:connect(function(reason)
				lostReason = reason
			end)

			local new = load(universe, b, "p1")
			expect(new:isActive()).toBe(true)
			universe.clock:advance(15)

			expect(old:state()).toBe("lost")
			expect(lostReason).toBe("another server took the session")
			expect(old:increment("coins").ok).toBe(false)
			expect(a:get("p1")).toBeNil()
			expect(#universe.kicks).toBe(1)
			expect(universe.kicks[1].userId).toBe(77)
			expect(universe.kicks[1].jobId).toBe("A")
		end)

		it("runs a custom session lost handler", function()
			local universe = Universe.new()
			local seen: { unknown } = {}
			local a = Helpers.store(universe:server({ jobId = "A" }), {
				onSessionLost = function(profile, reason)
					table.insert(seen, profile)
					table.insert(seen, reason)
				end,
			})
			local b = Helpers.store(universe:server({ jobId = "B" }))
			local old = load(universe, a, "p1", 1)
			load(universe, b, "p1")
			universe.clock:advance(15)
			expect(seen[1]).toBe(old)
			expect(#universe.kicks).toBe(0)
		end)

		it("takes a stale lease right away", function()
			local universe = Universe.new()
			local dead = universe:server({ jobId = "A" })
			local a = Helpers.store(dead)
			local b = Helpers.store(universe:server({ jobId = "B" }), { stealPolicy = "fail" })
			load(universe, a, "p1")
			dead:crash()
			universe.clock:advance(61)

			local started = universe.clock:now()
			local profile = load(universe, b, "p1")
			expect(profile:isActive()).toBe(true)
			expect(universe.clock:now()).toBe(started)
		end)
	end)

	describe("schemas, guards and facets", function()
		local function schemaStore(server: Universe.MockServer): ProfileStore.ProfileStore
			local Data = t.struct({
				coins = t.integer({ min = 0 }),
				log = t.array(t.string()),
				home = Lune.codec.Vector3,
			})
			return (
				Helpers.store(server, {
					schema = Data,
					template = { coins = 0, log = {}, home = Lune.roblox.Vector3.new(1, 2, 3) },
				})
			)
		end

		it("stores codec values in their stored form and loads them back", function()
			local universe = Universe.new()
			local store = schemaStore(universe:server())
			local profile = load(universe, store, "p1")
			expect(typeof(profile:get("home"))).toBe("Vector3")
			universe.clock:run(function()
				return profile:release()
			end)
			local record = Helpers.stored(universe, "p1") :: Record.Record
			expect((record.data :: Any).home).toEqual({ 1, 2, 3 })

			local again = load(universe, store, "p1")
			expect((again:get("home") :: Any).Z).toBe(3)
		end)

		it("refuses stored data the schema can't decode and gives the lease back", function()
			local universe = Universe.new()
			local server = universe:server()
			universe.clock:run(function()
				local broken = Record.new({ coins = 0, log = {}, home = { 1, 2 } }, 0, 1)
				return server.dataStore(Helpers.STORE):set("p1", broken)
			end)
			local store = schemaStore(server)
			local result = universe.clock:run(function()
				return store:load("p1")
			end)
			expect(errorKind(result)).toBe("invalidData")
			universe.clock:advance(10)
			expect((Helpers.stored(universe, "p1") :: Record.Record).meta.lease).toBeNil()
		end)

		it("refuses a template that doesn't match the schema", function()
			local universe = Universe.new()
			expect(function()
				Helpers.store(universe:server(), {
					schema = t.struct({ coins = t.integer() }),
					template = { coins = "none" },
				})
			end).toThrow("template doesn't match")
		end)

		it("runs guards on profiles and reports violations on the store", function()
			local universe = Universe.new()
			local store = Helpers.store(
				universe:server(),
				{ guards = { Guards.range("coins", { min = 0 }) } }
			)
			local profile = load(universe, store, "p1")
			local seen: { unknown } = {}
			store.guardBroken:connect(function(_violation, which)
				table.insert(seen, which)
			end)
			expect(profile:decrement("coins").ok).toBe(false)
			expect(seen[1]).toBe(profile)
		end)

		it("rejects schema violations through the built in schema guard", function()
			local universe = Universe.new()
			local store = schemaStore(universe:server())
			local profile = load(universe, store, "p1")
			expect(profile:set("coins", -1).ok).toBe(false)
			expect(profile:set("coins", 5).ok).toBe(true)
		end)
	end)

	describe("Studio", function()
		it("keeps data in memory by default", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server({ studio = true }))
			local profile = load(universe, store, "p1")
			profile:increment("coins")
			universe.clock:run(function()
				return profile:release()
			end)
			expect(Helpers.stored(universe, "p1")).toBeNil()
		end)

		it("uses a separate scope in scope mode and live data in real mode", function()
			local universe = Universe.new()
			local scoped = Helpers.store(universe:server({ studio = true }), { studio = "scope" })
			expect(scoped.scope).toBe("studio_global")
			load(universe, scoped, "p1")
			expect(Helpers.stored(universe, "p1", "studio_global")).never.toBeNil()

			local real = Helpers.store(universe:server({ studio = true }), { studio = "real" })
			expect(real.scope).toBe("global")
		end)
	end)

	describe("options", function()
		it("refuses timings that can't work", function()
			local universe = Universe.new()
			expect(function()
				Helpers.store(universe:server(), { autosaveInterval = 100, leaseTimeout = 50 })
			end).toThrow("leaseTimeout must be longer")
			expect(function()
				Helpers.store(universe:server(), { name = "" })
			end).toThrow("needs a name")
		end)
	end)
end
