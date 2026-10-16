--!strict

local Bus = require("../../src/Vein/Bus")
local GuardEvent = require("../../src/Vein/GuardEvent")
local Guards = require("../../src/Obsidian/Guards")
local Helpers = require("../Sapphire/Helpers")
local Lune = require("../Obsidian/LuneDatatypes")
local SharedStore = require("../../src/Opal/SharedStore")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")
local Vein = require("../../src/Vein")
local VeinBridge = require("../../src/Vein/Bridge")
local t = require("../../src/Obsidian/Schema")

-- messages are plain tables
type Any = any

local function listen(): ({ Any }, () -> ())
	local seen: { Any } = {}
	local connection = Vein.subscribe(function(message)
		if message.type == "guardBroken" then
			table.insert(seen, message)
		end
	end)
	return seen, function()
		connection:disconnect()
	end
end

local function loaded(universe: Universe.Universe, store: Any, key: string): Any
	local result = universe.clock:run(function()
		return store:load(key)
	end)
	assert(result.ok, "load failed")
	return result.profile
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("guardBroken telemetry", function()
		it("carries the source, path, kind, ops and before/after values", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server(), {
				guards = { Guards.range("coins", { min = 0 }) },
			})
			local profile = loaded(universe, store, "p1")
			local seen, stop = listen()
			expect(profile:decrement("coins").ok).toBe(false)
			stop()
			local message = seen[1]
			expect(message.store).toBe(Helpers.STORE)
			expect(message.storeKind).toBe("profile")
			expect(message.key).toBe("p1")
			expect(message.kind).toBe("range")
			expect(message.action).toBe("reject")
			expect(message.source).toBe("system")
			expect(message.path).toBe("coins")
			expect(message.before).toBe(0)
			expect(message.after).toBe(-1)
			expect(table.find(message.ops, "decrement")).never.toBeNil()
		end)

		it("fires for rejected transactions and fills the violation's values", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server(), {
				guards = { Guards.range("coins", { min = 0 }) },
			})
			local profile = loaded(universe, store, "p1")
			local violation: Any = nil
			store.guardBroken:connect(function(found)
				violation = found
			end)
			profile:decrement("coins", 5)
			expect(violation.before).toBe(0)
			expect(violation.after).toBe(-5)
		end)

		it("sends valid values in stored form and invalid ones as they are", function()
			local universe = Universe.new()
			local schema = t.struct({ coins = t.number(), spawn = Lune.codec.Vector3 })
			local store = Helpers.store(universe:server(), {
				schema = schema,
				template = { coins = 0, spawn = Lune.roblox.Vector3.new(1, 2, 3) },
			})
			local profile = loaded(universe, store, "p1")
			local seen, stop = listen()
			profile:set("spawn", "not a vector")
			stop()
			local message = seen[1]
			expect(message.path).toBe("data.spawn")
			expect(message.before).toEqual({ 1, 2, 3 })
			expect(message.after).toBe("not a vector")
		end)

		it("leaves out values over the size cap and reports their size", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server(), {
				schema = t.struct({ coins = t.number(), name = t.string({ maxLength = 10 }) }),
				template = { coins = 0, name = "a" },
			})
			local profile = loaded(universe, store, "p1")
			local seen, stop = listen()
			profile:set("name", string.rep("x", 2000))
			stop()
			local message = seen[1]
			expect(message.before).toBe("a")
			expect(message.after).toBeNil()
			expect(message.afterSize > GuardEvent.MAX_VALUE_SIZE).toBe(true)
		end)

		it("comes from shared stores too, with the key", function()
			local universe = Universe.new()
			local store = SharedStore.new({
				name = "Guilds",
				template = { bank = 0 },
				services = universe:server(),
				guards = { Guards.range("bank", { min = 0 }) },
				reportError = function() end,
			} :: Any)
			local seen, stop = listen()
			local result = universe.clock:run(function()
				return store:decrement("guild1", "bank", 3)
			end)
			stop()
			expect(result.ok).toBe(false)
			local message = seen[1]
			expect(message.storeKind).toBe("shared")
			expect(message.store).toBe("Guilds")
			expect(message.key).toBe("guild1")
			expect(message.after).toBe(-3)
		end)

		it("builds nothing when no one listens", function()
			local encodes = 0
			local json: Any = {
				encode = function(_self, _value)
					encodes += 1
					return "0"
				end,
			}
			local violation: Any = {
				guard = "range coins",
				kind = "range",
				path = "coins",
				reason = "too low",
				action = "reject",
				source = { kind = "system" },
				ops = {},
				timestamp = 0,
				before = 0,
				after = -1,
			}
			-- Studio bridges left open by other specs listen to the bus, close them first
			local wasEnabled = VeinBridge.isEnabled()
			Vein.setBridgeEnabled(false)
			expect(Bus.listening()).toBe(false)
			GuardEvent.publish("PlayerData", "profile", "p1", violation, nil, json, 0)
			expect(encodes).toBe(0)
			local _, stop = listen()
			GuardEvent.publish("PlayerData", "profile", "p1", violation, nil, json, 0)
			stop()
			Vein.setBridgeEnabled(wasEnabled)
			expect(encodes).toBe(2)
		end)
	end)
end
