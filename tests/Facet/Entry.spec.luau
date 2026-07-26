--!strict

local Geode = require("../../src")
local Spec = require("../_lib/Spec")

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Geode.bundle, Geode.react, Geode.derive and Geode.Raw.facets", function()
		it("build a facet set that works on a raw document", function()
			local doc =
				Geode.Raw.document({ data = { a = 1, b = 0 }, reportError = function() end })
			local facets = Geode.Raw.facets({
				bundles = {
					Geode.bundle({ "a" }, function(tx)
						tx:set("a", math.max(tx:get("a") :: number, 0))
					end),
				},
				reactions = {
					Geode.react({ "a" }, function(tx)
						tx:set("b", (tx:get("a") :: number) * 2)
					end, { writes = { "b" } }),
				},
				derived = {
					Geode.derive("sum", { "a", "b" }, function(state)
						local data = state :: { a: number, b: number }
						return data.a + data.b
					end),
				},
			})
			facets:attach(doc)
			doc:set("a", -5)
			expect(doc:get("a")).toBe(0)
			doc:set("a", 4)
			expect(doc:get("b")).toBe(8)
			expect(doc:get("sum")).toBe(12)
		end)
	end)
end
