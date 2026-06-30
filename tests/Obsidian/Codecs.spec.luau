--!strict

local Lune = require("./LuneDatatypes")
local Spec = require("../_lib/Spec")
local t = require("../../src/Obsidian/Schema")

local codec = Lune.codec
local roblox = Lune.roblox

local function roundTrip(schema: t.Schema, value: unknown): unknown
	local held = schema.codec :: t.Codec
	assert(held.is(value), `{held.name} doesn't accept the value`)
	local ok, decoded = held.decode(held.encode(value))
	assert(ok, tostring(decoded))
	return decoded
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("codecs", function()
		it("round trip vectors, colors and UDim2", function()
			local v3 = roundTrip(codec.Vector3, roblox.Vector3.new(1.5, -2, 3)) :: any
			expect(v3.X).toBe(1.5)
			expect(v3.Y).toBe(-2)
			local v2 = roundTrip(codec.Vector2, roblox.Vector2.new(4, 5)) :: any
			expect(v2.Y).toBe(5)
			local color = roundTrip(codec.Color3, roblox.Color3.new(0.5, 0.25, 1)) :: any
			expect(color.G).toBe(0.25)
			local udim = roundTrip(codec.UDim2, roblox.UDim2.new(0.5, 10, 1, -5)) :: any
			expect(udim.X.Offset).toBe(10)
			expect(udim.Y.Offset).toBe(-5)
		end)

		it("round trips a CFrame through its twelve components", function()
			local original = roblox.CFrame.new(1, 2, 3) * roblox.CFrame.Angles(0, math.pi / 2, 0)
			local held = codec.CFrame.codec :: t.Codec
			local stored = held.encode(original) :: { number }
			expect(#stored).toBe(12)
			local decoded = roundTrip(codec.CFrame, original) :: any
			expect(decoded.Position.X).toBe(1)
			expect(math.abs(decoded.LookVector.X - original.LookVector.X) < 1e-6).toBe(true)
		end)

		it("round trips BrickColor and DateTime", function()
			local brick = roundTrip(codec.BrickColor, roblox.BrickColor.new(21)) :: any
			expect(brick.Number).toBe(21)
			local moment = Lune.DateTime.fromUnixTimestamp(1700000000)
			local decoded = roundTrip(codec.DateTime, moment) :: any
			expect(decoded.unixTimestampMillis).toBe(1700000000000)
		end)

		it("stores enum items by name and checks their enum type", function()
			local material = codec.EnumItem(roblox.Enum.Material :: any)
			local held = material.codec :: t.Codec
			expect(held.encode(roblox.Enum.Material.Plastic)).toBe("Plastic")
			expect(held.is(roblox.Enum.Material.Plastic)).toBe(true)
			expect(held.is(roblox.Enum.KeyCode.A)).toBe(false)
			local ok, item = held.decode("Plastic")
			expect(ok).toBe(true)
			expect(item).toBe(roblox.Enum.Material.Plastic)
			local missing = held.decode("NotAMaterial")
			expect(missing).toBe(false)
		end)

		it("refuses malformed stored forms", function()
			local held = codec.Vector3.codec :: t.Codec
			local ok, reason = held.decode({ 1, 2 })
			expect(ok).toBe(false)
			expect((string.find(tostring(reason), "3 numbers", 1, true))).never.toBeNil()
			expect((held.decode("nope"))).toBe(false)
			expect((held.decode({ 1, "2", 3 } :: { unknown }))).toBe(false)
			expect(((codec.BrickColor.codec :: t.Codec).decode("red"))).toBe(false)
			expect(((codec.DateTime.codec :: t.Codec).decode({}))).toBe(false)
		end)

		it("only accepts its own datatype", function()
			expect((codec.Vector3.codec :: t.Codec).is(roblox.Vector2.new(1, 2))).toBe(false)
			expect((codec.Color3.codec :: t.Codec).is({ 1, 2, 3 })).toBe(false)
		end)

		it("builds custom codecs", function()
			local Money = codec.custom(function(value)
				return math.floor((value :: number) * 100)
			end, function(encoded)
				if type(encoded) ~= "number" then
					error("money must be stored as cents")
				end
				return encoded / 100
			end, { name = "Money", version = 2 })
			local held = Money.codec :: t.Codec
			expect(held.name).toBe("Money")
			expect(held.version).toBe(2)
			expect(held.encode(12.34)).toBe(1234)
			local ok, value = held.decode(1234)
			expect(ok).toBe(true)
			expect(value).toBe(12.34)
			local bad, reason = held.decode("x")
			expect(bad).toBe(false)
			expect((string.find(tostring(reason), "cents", 1, true))).never.toBeNil()
		end)

		it("are schema nodes with version 1 by default", function()
			expect(codec.Vector3.kind).toBe("codec")
			expect((codec.Vector3.codec :: t.Codec).version).toBe(1)
			expect(table.isfrozen(codec)).toBe(true)
		end)
	end)
end
