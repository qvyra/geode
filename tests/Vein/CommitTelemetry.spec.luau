--!strict

local Bridge = require("../../src/Vein/Bridge")
local Bus = require("../../src/Vein/Bus")
local Helpers = require("../Sapphire/Helpers")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")
local Vein = require("../../src/Vein")
local VeinRegistry = require("../../src/Vein/Registry")

type Any = any

-- Closes every bridge, so nothing listens to the bus unless a test subscribes
local function quiet()
	VeinRegistry._reset()
	Vein.setBridgeEnabled(false)
end

local function opened(universe: Universe.Universe, store: Any, key: string): Any
	local result = universe.clock:run(function()
		return store:load(key)
	end)
	assert(result.ok, "load failed")
	return result.profile
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("commit telemetry", function()
		it("describes each commit: revision, source, note, ops and changed paths", function()
			quiet()
			local universe = Universe.new()
			local server = universe:server()
			local store = Helpers.store(server)
			local profile = opened(universe, store, "p1")
			local seen: { Any } = {}
			local connection = Bus.subscribe(function(message)
				if message.type == "profileCommitted" then
					table.insert(seen, message)
				end
			end)
			profile:transact(function(tx)
				tx:increment("coins", 5)
				tx:append("log", "bought")
			end, { source = { kind = "player", userId = 42 }, note = "shop" })
			connection:disconnect()
			Vein.setBridgeEnabled(true)
			expect(#seen).toBe(1)
			local message = seen[1]
			expect(message.store).toBe(Helpers.STORE)
			expect(message.key).toBe("p1")
			expect(message.revision).toBe(profile:revision())
			expect(message.source).toBe("player")
			expect(message.player).toBe(42)
			expect(message.note).toBe("shop")
			expect(message.ops).toEqual({ "increment", "append" })
			expect(message.paths).toEqual({ "coins", "log[1]" })
		end)

		it("builds nothing while no one listens", function()
			quiet()
			local universe = Universe.new()
			local server = universe:server()
			local store = Helpers.store(server)
			local profile = opened(universe, store, "p1")
			expect(Bus.listening()).toBe(false)
			local published = 0
			local original = Bus.publish
			Bus.publish = function(...)
				published += 1
				original(...)
			end
			profile:increment("coins", 1)
			profile:increment("coins", 1)
			Bus.publish = original
			Vein.setBridgeEnabled(true)
			expect(published).toBe(0)
			expect(profile:get("coins")).toBe(2)
		end)

		it("is listed among the bridge's features", function()
			expect(table.find(Bridge.FEATURES, "commits")).never.toBeNil()
		end)
	end)
end
