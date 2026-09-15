--!strict

local Helpers = require("../Sapphire/Helpers")
local Registry = require("../../src/Vein/Registry")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")
local Vein = require("../../src/Vein")

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Vein", function()
		it("reports idle and every feature missing when nothing runs", function()
			Registry._reset()
			local snapshot = Vein.snapshot()
			expect(snapshot.v).toBe(1)
			expect(snapshot.idle).toBe(true)
			expect(table.find(snapshot.missing, "Profile")).never.toBeNil()
			expect(table.find(snapshot.missing, "Ranked")).never.toBeNil()
		end)

		it("lists what registered with live details and drops it from missing", function()
			Registry._reset()
			local universe = Universe.new()
			local store = Helpers.store(universe:server())
			universe.clock:run(function()
				return store:load("p1")
			end)
			local snapshot = Vein.snapshot()
			expect(snapshot.idle).toBe(false)
			expect(snapshot.modules[1].kind).toBe("profileStore")
			local details = snapshot.modules[1].details :: { [string]: unknown }
			expect(details.open).toBe(1)
			expect(table.find(snapshot.missing, "Profile")).toBeNil()
			Registry._reset()
		end)

		it("publishes versioned messages for profile events", function()
			Registry._reset()
			local universe = Universe.new()
			local store = Helpers.store(universe:server())
			local types = {}
			local connection = Vein.subscribe(function(message)
				expect(message.v).toBe(Vein.VERSION)
				table.insert(types, message.type)
			end)
			local result = universe.clock:run(function()
				return store:load("p1")
			end)
			if result.ok then
				result.profile:increment("coins")
				universe.clock:run(function()
					return result.profile:release()
				end)
			end
			connection:disconnect()
			expect(table.find(types, "profileLoaded")).never.toBeNil()
			expect(table.find(types, "profileSaved")).never.toBeNil()
			expect(table.find(types, "profileReleased")).never.toBeNil()
			Registry._reset()
		end)
	end)
end
