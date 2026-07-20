--!strict

local Document = require("../../src/Matrix/Document")
local Guards = require("../../src/Obsidian/Guards")
local Spec = require("../_lib/Spec")
local Transaction = require("../../src/Matrix/Transaction")

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("write provenance", function()
		it("keeps the first writer of a path and defaults to the source", function()
			local doc = Document.new({ data = {}, reportError = function() end })
			local seen = {}
			doc:transact(function(tx)
				tx:markWriter("a", "bundle")
				tx:markWriter("a", "reaction")
				seen.a = tx:writerOf("a")
				seen.b = tx:writerOf("b")
			end, { source = "migration" })
			expect(seen.a).toBe("bundle")
			expect(seen.b).toBe("migration")
		end)

		it("lets rate guards skip changes marked as reaction writes", function()
			local doc = Document.new({ data = { coins = 0, xp = 0 }, reportError = function() end })
			doc:addStage(function(tx: Transaction.Transaction)
				if tx:get("xp") ~= tx:getBefore("xp") then
					tx:increment("coins", 10)
					tx:markWriter("coins", "reaction")
				end
			end)
			Guards.set({
				guards = { Guards.rate("coins", { count = 1, window = 60 }) },
				reportError = function() end,
			}):attach(doc)

			local function gainXp(): boolean
				return doc:transact(function(tx)
					tx:increment("xp")
				end, { source = { kind = "player", userId = 1 } }).ok
			end
			expect(gainXp()).toBe(true)
			expect(gainXp()).toBe(true)
			expect(doc:get("coins")).toBe(20)

			local function spend(): boolean
				return doc:transact(function(tx)
					tx:decrement("coins")
				end, { source = { kind = "player", userId = 1 } }).ok
			end
			expect(spend()).toBe(true)
			expect(spend()).toBe(false)
		end)
	end)
end
