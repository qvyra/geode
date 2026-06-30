--!strict

-- Codec datatypes backed by Lune's Roblox and DateTime libraries

local Codecs = require("../../src/Obsidian/Codecs")
local DateTime = require("@lune/datetime")
-- Lune's typedefs don't declare the datatype constructors, though they exist at runtime
local roblox = require("@lune/roblox") :: any

local function datatypes(): Codecs.Datatypes
	return {
		vector3 = roblox.Vector3.new,
		vector2 = roblox.Vector2.new,
		cframe = function(components: { number }): unknown
			return roblox.CFrame.new(table.unpack(components))
		end,
		color3 = roblox.Color3.new,
		udim2 = roblox.UDim2.new,
		brickColor = function(number: number): unknown
			return roblox.BrickColor.new(number)
		end,
		dateTimeFromMillis = function(millis: number): unknown
			return DateTime.fromUnixTimestamp(millis / 1000)
		end,
		dateTimeToMillis = function(value: unknown): number
			return (value :: DateTime.DateTime).unixTimestampMillis
		end,
	}
end

return {
	datatypes = datatypes,
	codec = Codecs.build(datatypes),
	roblox = roblox,
	DateTime = DateTime,
}
