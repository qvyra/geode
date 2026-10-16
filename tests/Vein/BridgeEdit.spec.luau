--!strict

-- The bridge's edit requests, driven through the mock bridge, which refuses anything a real
-- Bindable would mangle. That makes these the contract for what crosses in both directions

local Guards = require("../../src/Obsidian/Guards")
local Helpers = require("../Sapphire/Helpers")
local Lune = require("../Obsidian/LuneDatatypes")
local Spec = require("../_lib/Spec")
local Transaction = require("../../src/Matrix/Transaction")
local Universe = require("../../src/Quartz/Mock/Universe")
local Vein = require("../../src/Vein")
local VeinRegistry = require("../../src/Vein/Registry")
local t = require("../../src/Obsidian/Schema")

-- answers are plain tables
type Any = any

-- argument lists mix strings and numbers
local function list(...: any): { any }
	return { ... }
end

local function fresh()
	VeinRegistry._reset()
	Vein.setBridgeEnabled(true)
end

local function request(
	universe: Universe.Universe,
	server: Universe.MockServer,
	body: { [string]: any }
): Any
	return universe.clock:run(function()
		return server.tooling:request(body)
	end)
end

local function opened(universe: Universe.Universe, store: Any, key: string): Any
	local result = universe.clock:run(function()
		return store:load(key)
	end)
	assert(result.ok, "load failed")
	return result.profile
end

local registered = false
local function registerOp()
	if not registered then
		registered = true
		Transaction.register("bridgeEditGrant", function(tx, amount: number)
			tx:increment("coins", amount)
		end)
	end
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("bridge edits", function()
		it("lists the ops a store allows, built-ins with their arguments", function()
			fresh()
			registerOp()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			Helpers.store(server, { studio = "real", ops = { "bridgeEditGrant" } })
			local answer = request(universe, server, { kind = "ops", store = Helpers.STORE })
			local byName: { [string]: Any } = {}
			for _, op in answer.ops do
				byName[op.name] = op
			end
			expect(byName.set.builtin).toBe(true)
			expect(byName.set.args[2].type).toBe("value")
			expect(byName.update).toBeNil()
			expect(byName.bridgeEditGrant.builtin).toBe(false)
			expect(byName.bridgeEditGrant.args).toBeNil()
		end)

		it("describes the schema at a path", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			Helpers.store(server, {
				studio = "real",
				schema = t.struct({ coins = t.number({ min = 0 }), spawn = Lune.codec.Vector3 }),
				template = { coins = 0, spawn = Lune.roblox.Vector3.new(0, 0, 0) },
			})
			local spawn = request(
				universe,
				server,
				{ kind = "schemaAt", store = Helpers.STORE, path = { "spawn" } }
			)
			expect(spawn.declared).toBe(true)
			expect(spawn.kind).toBe("codec")
			expect(spawn.codec).toBe("Vector3")
			local coins = request(
				universe,
				server,
				{ kind = "schemaAt", store = Helpers.STORE, path = "coins" }
			)
			expect(coins.min).toBe(0)
			local nothing = request(
				universe,
				server,
				{ kind = "schemaAt", store = Helpers.STORE, path = "nope" }
			)
			expect(nothing.declared).toBe(false)
		end)

		it("applies an edit with a plugin source and the note, decoding stored values", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			local store = Helpers.store(server, {
				studio = "real",
				schema = t.struct({
					coins = t.number(),
					log = t.array(t.string()),
					spawn = Lune.codec.Vector3,
				}),
				template = { coins = 0, log = {}, spawn = Lune.roblox.Vector3.new(0, 0, 0) },
			})
			local profile = opened(universe, store, "p1")
			local records: { Any } = {}
			profile:onCommit(function(record)
				table.insert(records, record)
			end)
			local answer = request(universe, server, {
				kind = "apply",
				store = Helpers.STORE,
				key = "p1",
				op = "set",
				args = list({ "spawn" }, { 4, 5, 6 }),
				note = "moved the spawn",
			})
			expect(answer.ok).toBe(true)
			expect(answer.via).toBe("here")
			expect(answer.revision).toBe(profile:revision())
			expect(typeof(profile:get("spawn"))).toBe("Vector3")
			expect(records[1].source.kind).toBe("plugin")
			expect(records[1].note).toBe("moved the spawn")
		end)

		it("needs a note", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			opened(universe, Helpers.store(server, { studio = "real" }), "p1")
			local answer = request(universe, server, {
				kind = "apply",
				store = Helpers.STORE,
				key = "p1",
				op = "increment",
				args = list("coins", 1),
			})
			expect(answer.ok).toBe(false)
			expect(answer.error.kind).toBe("noteRequired")
		end)

		it("returns a guard's rejection and skips only rate guards", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			local store = Helpers.store(server, {
				studio = "real",
				guards = {
					Guards.rate("coins", { count = 1, window = 60 }),
					Guards.range("coins", { max = 100 }),
				},
			})
			local profile = opened(universe, store, "p1")
			local function edit(amount: number): Any
				return request(universe, server, {
					kind = "apply",
					store = Helpers.STORE,
					key = "p1",
					op = "increment",
					args = list("coins", amount),
					note = "test",
				})
			end
			expect(edit(10).ok).toBe(true)
			expect(edit(10).ok).toBe(true)
			local rejected = edit(1000)
			expect(rejected.ok).toBe(false)
			expect(rejected.error.kind).toBe("rejected")
			expect(profile:get("coins")).toBe(20)
		end)

		it("loads, edits and releases a profile nobody holds", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			Helpers.store(server, { studio = "real" })
			local answer = request(universe, server, {
				kind = "apply",
				store = Helpers.STORE,
				key = "free",
				op = "increment",
				args = list("coins", 3),
				note = "gift",
			})
			expect(answer.ok).toBe(true)
			expect(answer.via).toBe("loaded")
			local stored = Helpers.stored(universe, "free") :: Any
			expect(stored.data.coins).toBe(3)
			expect(stored.meta.lease).toBeNil()
		end)

		it("releases a profile nobody holds even when a guard refuses the edit", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ jobId = "studio", studio = true })
			local store = Helpers.store(server, {
				studio = "real",
				guards = { Guards.range("coins", { max = 100 }) },
			}) :: Any
			local answer = request(universe, server, {
				kind = "apply",
				store = Helpers.STORE,
				key = "free",
				op = "increment",
				args = list("coins", 1000),
				note = "too much",
			})
			expect(answer.ok).toBe(false)
			expect(answer.error.kind).toBe("rejected")
			expect(store:get("free")).toBeNil()
			local stored = Helpers.stored(universe, "free") :: Any
			expect(stored.meta.lease).toBeNil()
			expect(stored.data.coins).toBe(0)
		end)

		it("won't reach a live holder from Studio on live data", function()
			fresh()
			local universe = Universe.new()
			local live = universe:server({ jobId = "live" })
			opened(universe, Helpers.store(live, { handoff = true }), "p1")
			local studio = universe:server({ jobId = "studio", studio = true })
			Helpers.store(studio, { studio = "real", handoff = true })
			local answer = request(universe, studio, {
				kind = "apply",
				store = Helpers.STORE,
				key = "p1",
				op = "increment",
				args = list("coins", 1),
				note = "test",
			})
			expect(answer.ok).toBe(false)
			expect(answer.error.kind).toBe("unreachable")
		end)

		it("refuses edits where there's no playtest bridge", function()
			fresh()
			local universe = Universe.new()
			local store = Helpers.store(universe:server()) :: Any
			local answer = universe.clock:run(function()
				return store:_toolEdit("p1", "increment", list("coins", 1), "test")
			end)
			expect(answer.ok).toBe(false)
			expect(answer.error.kind).toBe("unavailable")
		end)
	end)

	describe("edits through the holder", function()
		it("run on the server holding the profile and come back with its answer", function()
			fresh()
			local universe = Universe.new({ messagingLatency = 0.2 })
			local holderServer = universe:server({ jobId = "holder" })
			local holderStore = Helpers.store(holderServer, { handoff = true })
			local profile = opened(universe, holderStore, "p1")
			local asking =
				Helpers.store(universe:server({ jobId = "asking" }), { handoff = true }) :: Any
			local answer = universe.clock:run(function()
				return asking:_editThroughHolder(
					"p1",
					"holder",
					"increment",
					list("coins", 4),
					"via holder"
				)
			end)
			expect(answer.ok).toBe(true)
			expect(answer.via).toBe("holder")
			expect(profile:get("coins")).toBe(4)
		end)

		it("report an unanswered edit as unknown, with the saved revision", function()
			fresh()
			local universe = Universe.new({ messagingLatency = 0.2 })
			local holderStore =
				Helpers.store(universe:server({ jobId = "holder" }), { handoff = true })
			local profile = opened(universe, holderStore, "p1")
			profile:increment("coins", 2)
			universe.clock:run(function()
				return profile:save()
			end)
			local asking =
				Helpers.store(universe:server({ jobId = "asking" }), { handoff = true }) :: Any
			local answer = universe.clock:run(function()
				return asking:_editThroughHolder(
					"p1",
					"gone",
					"increment",
					list("coins", 1),
					"test"
				)
			end)
			expect(answer.ok).toBe(false)
			expect(answer.error.kind).toBe("unknown")
			local stored = Helpers.stored(universe, "p1") :: Any
			expect(answer.revision).toBe(stored.meta.revision)
		end)

		it("apply an edit id once, and answer a repeat the same way", function()
			fresh()
			local universe = Universe.new()
			local holderStore =
				Helpers.store(universe:server({ jobId = "holder" }), { handoff = true }) :: Any
			local profile = opened(universe, holderStore, "p1")
			local message = {
				key = "p1",
				to = "holder",
				id = "edit-1",
				name = "increment",
				args = list("coins", 4),
				note = "test",
			}
			universe.clock:run(function()
				holderStore:_editRequested(message)
				holderStore:_editRequested(table.clone(message))
			end)
			expect(profile:get("coins")).toBe(4)
			expect(holderStore._appliedEdits["edit-1"].ok).toBe(true)

			universe.clock:run(function()
				holderStore:_editRequested({
					key = "p1",
					to = "holder",
					id = "edit-2",
					name = "increment",
					args = list("coins", 1),
					note = "test",
				})
			end)
			expect(profile:get("coins")).toBe(5)
		end)
	end)
end
