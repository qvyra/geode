--!strict

local Errors = require("../../src/Quartz/Errors")
local Spec = require("../_lib/Spec")

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Errors.classify", function()
		it("reads the numeric code at the start of DataStore errors", function()
			local err = Errors.classify("304: UpdateAsync request dropped. Request was throttled")
			expect(err.kind).toBe("throttled")
			expect(err.code).toBe(304)
		end)

		it("maps key, value and size codes", function()
			expect(Errors.classify("101: Key name can't be empty").kind).toBe("invalidKey")
			expect(Errors.classify("104: Cannot store function").kind).toBe("invalidValue")
			expect(Errors.classify("105: Serialized value exceeds limit").kind).toBe("tooLarge")
			expect(Errors.classify("502: API rejected request").kind).toBe("internal")
		end)

		it("falls back to unknown for codes it doesn't know", function()
			local err = Errors.classify("999: something new")
			expect(err.kind).toBe("unknown")
			expect(err.code).toBe(999)
		end)

		it("matches wording when there is no code", function()
			expect(Errors.classify("Request was throttled").kind).toBe("throttled")
			expect(Errors.classify("The item is too large").kind).toBe("tooLarge")
			expect(Errors.classify("something odd").kind).toBe("unknown")
		end)

		it("keeps the original message", function()
			expect(Errors.classify({}).message).never.toBeNil()
			expect(Errors.classify("301: dropped").message).toBe("301: dropped")
		end)
	end)

	describe("Errors.ok and Errors.fail", function()
		it("build both sides of a result", function()
			local good = Errors.ok(5)
			expect(good.ok).toBe(true)
			local bad = Errors.fail("notFound", "missing", 404)
			expect(bad.ok).toBe(false)
			if not bad.ok then
				expect(bad.error.kind).toBe("notFound")
				expect(bad.error.code).toBe(404)
			end
			local wrapped = Errors.failWith({ kind = "internal", message = "x" })
			expect(wrapped.ok).toBe(false)
		end)
	end)
end
