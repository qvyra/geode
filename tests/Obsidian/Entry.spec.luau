--!strict

local Geode = require("../../src")
local Json = require("../../src/Quartz/Json")
local Spec = require("../_lib/Spec")

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Geode.t, Geode.codec and Geode.schema", function()
		it("are wired to the schema module and frozen", function()
			local schema = Geode.t.struct({ coins = Geode.t.integer({ min = 0 }) })
			expect(Geode.schema.validate(schema, { coins = 5 }).ok).toBe(true)
			expect(Geode.schema.validate(schema, { coins = -1 }).ok).toBe(false)
			expect(Geode.schema.checkStorable({ fn = print }).ok).toBe(false)
			expect(Geode.schema.encode(schema, { coins = 1 })).toEqual({ coins = 1 })
			expect((Geode.schema.decode(schema, { coins = 1 }))).toBe(true)
			expect(Geode.schema.measure(Json.adapter(), { coins = 1 })).toBe(11)
			expect(Geode.schema.checkSize(Json.adapter(), 1, { hard = 0 }).level).toBe("hard")
			expect(Geode.codec.Vector3.kind).toBe("codec")
			expect(table.isfrozen(Geode.t)).toBe(true)
			expect(table.isfrozen(Geode.codec)).toBe(true)
			expect(table.isfrozen(Geode.schema)).toBe(true)
		end)
	end)
end
