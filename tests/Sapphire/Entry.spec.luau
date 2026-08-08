--!strict

local Geode = require("../../src")
local Spec = require("../_lib/Spec")

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Geode.Profile", function()
		it("exposes the store constructor", function()
			expect(type(Geode.Profile.store)).toBe("function")
			local universe = Geode.Testing.universe()
			local store = Geode.Profile.store({
				name = "Entry",
				template = { coins = 0 },
				services = universe:server(),
				reportError = function() end,
			})
			local result = universe.clock:run(function()
				return store:load("p1")
			end)
			expect(result.ok).toBe(true)
		end)
	end)

	describe("Geode.receipts and Geode.erase", function()
		it("are wired to the profile layer", function()
			local universe = Geode.Testing.universe()
			local server = universe:server()
			local store = Geode.Profile.store({
				name = "EntryReceipts",
				template = { coins = 0 },
				services = server,
				reportError = function() end,
			})
			local process = Geode.receipts(store, {
				[1] = function(tx)
					tx:increment("coins")
				end,
			}, { decisions = { granted = "yes", notProcessed = "no" } })
			local decision = universe.clock:run(function()
				local loaded = store:load("7")
				assert(loaded.ok, "expected a load")
				return process({ PlayerId = 7, ProductId = 1, PurchaseId = "x" })
			end)
			expect(decision).toBe("yes")

			local report = universe.clock:run(function()
				return Geode.erase(7, server)
			end)
			expect(report.erased).toBe(1)
		end)
	end)
end
