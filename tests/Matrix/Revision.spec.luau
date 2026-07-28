--!strict

local Document = require("../../src/Matrix/Document")
local Spec = require("../_lib/Spec")

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Document revisions and read only state", function()
		it("counts commits from a starting revision", function()
			local doc =
				Document.new({ data = { n = 0 }, revision = 41, reportError = function() end })
			expect(doc:revision()).toBe(41)
			local result = doc:increment("n")
			assert(result.ok and result.record, "expected a record")
			expect(result.record.revision).toBe(42)
		end)

		it("accepts writes again after clearing read only", function()
			local doc = Document.new({ data = { n = 0 }, reportError = function() end })
			doc:setReadOnly("paused")
			expect(doc:increment("n").ok).toBe(false)
			doc:clearReadOnly()
			expect(doc:isReadOnly()).toBe(false)
			expect(doc:increment("n").ok).toBe(true)
		end)
	end)
end
