--!strict

-- Codecs turn Roblox datatypes into plain storable values and back. The stored form carries no
-- type tag, the schema says which codec applies, so stored data stays small. Every codec has a
-- version so its stored form can change later through a migration

local Schema = require("./Schema")

type Schema = Schema.Schema
type Codec = Schema.Codec

-- Datatype constructors and accessors, injected so codecs run in Lune against its datatype
-- library and in Roblox against the real globals
export type Datatypes = {
	vector3: (x: number, y: number, z: number) -> unknown,
	vector2: (x: number, y: number) -> unknown,
	cframe: (components: { number }) -> unknown,
	color3: (r: number, g: number, b: number) -> unknown,
	udim2: (xScale: number, xOffset: number, yScale: number, yOffset: number) -> unknown,
	brickColor: (number: number) -> unknown,
	dateTimeFromMillis: (millis: number) -> unknown,
	dateTimeToMillis: (value: unknown) -> number,
}

export type CustomOptions = {
	name: string?,
	version: number?,
	is: ((value: unknown) -> boolean)?,
}

export type CodecSet = {
	Vector3: Schema,
	Vector2: Schema,
	CFrame: Schema,
	Color3: Schema,
	UDim2: Schema,
	DateTime: Schema,
	BrickColor: Schema,
	EnumItem: (enumType: Enum) -> Schema,
	custom: (
		encode: (value: unknown) -> unknown,
		decode: (encoded: unknown) -> unknown,
		options: CustomOptions?
	) -> Schema,
}

local Codecs = {}

local function numbers(
	encoded: unknown,
	count: number,
	name: string
): (boolean, { number } | string)
	if type(encoded) ~= "table" then
		return false, `{name} should be stored as {count} numbers, found a {typeof(encoded)}`
	end
	local list = encoded :: { unknown }
	if #list ~= count then
		return false, `{name} should be stored as {count} numbers, found {#list}`
	end
	for index = 1, count do
		if type(list[index]) ~= "number" then
			return false, `{name} item {index} should be a number`
		end
	end
	return true, list :: { number }
end

local function isType(name: string): (value: unknown) -> boolean
	return function(value: unknown): boolean
		return typeof(value) == name
	end
end

local function numeric(
	name: string,
	count: number,
	encode: (value: any) -> { number },
	build: (list: { number }) -> unknown
): Schema
	return Schema.fromCodec({
		name = name,
		version = 1,
		is = isType(name),
		encode = encode :: (unknown) -> unknown,
		decode = function(encoded: unknown): (boolean, unknown)
			local ok, list = numbers(encoded, count, name)
			if not ok then
				return false, list
			end
			return true, build(list :: { number })
		end,
	})
end

-- Builds the codec set over a datatype provider. Geode.codec uses the real globals
function Codecs.build(datatypes: () -> Datatypes): CodecSet
	local set = {} :: CodecSet

	set.Vector3 = numeric("Vector3", 3, function(value: Vector3)
		return { value.X, value.Y, value.Z }
	end, function(list)
		return datatypes().vector3(list[1], list[2], list[3])
	end)

	set.Vector2 = numeric("Vector2", 2, function(value: Vector2)
		return { value.X, value.Y }
	end, function(list)
		return datatypes().vector2(list[1], list[2])
	end)

	set.CFrame = numeric("CFrame", 12, function(value: CFrame)
		return { value:GetComponents() }
	end, function(list)
		return datatypes().cframe(list)
	end)

	set.Color3 = numeric("Color3", 3, function(value: Color3)
		return { value.R, value.G, value.B }
	end, function(list)
		return datatypes().color3(list[1], list[2], list[3])
	end)

	set.UDim2 = numeric("UDim2", 4, function(value: UDim2)
		return { value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset }
	end, function(list)
		return datatypes().udim2(list[1], list[2], list[3], list[4])
	end)

	set.BrickColor = Schema.fromCodec({
		name = "BrickColor",
		version = 1,
		is = isType("BrickColor"),
		encode = function(value: unknown): unknown
			return (value :: BrickColor).Number
		end,
		decode = function(encoded: unknown): (boolean, unknown)
			if type(encoded) ~= "number" then
				return false, "BrickColor should be stored as its number"
			end
			return true, datatypes().brickColor(encoded)
		end,
	})

	set.DateTime = Schema.fromCodec({
		name = "DateTime",
		version = 1,
		is = isType("DateTime"),
		encode = function(value: unknown): unknown
			return datatypes().dateTimeToMillis(value)
		end,
		decode = function(encoded: unknown): (boolean, unknown)
			if type(encoded) ~= "number" then
				return false, "DateTime should be stored as Unix milliseconds"
			end
			return true, datatypes().dateTimeFromMillis(encoded)
		end,
	})

	function set.EnumItem(enumType: Enum): Schema
		local enumName = tostring(enumType)
		return Schema.fromCodec({
			name = `EnumItem({enumName})`,
			version = 1,
			is = function(value: unknown): boolean
				return typeof(value) == "EnumItem" and (value :: EnumItem).EnumType == enumType
			end,
			encode = function(value: unknown): unknown
				return (value :: EnumItem).Name
			end,
			decode = function(encoded: unknown): (boolean, unknown)
				if type(encoded) ~= "string" then
					return false, `{enumName} item should be stored as its name`
				end
				-- indexing a missing item throws, i.e. the stored name is stale
				local ok, item = pcall(function()
					return (enumType :: any)[encoded]
				end)
				if not ok or item == nil then
					return false, `{enumName} has no item named {encoded}`
				end
				return true, item
			end,
		})
	end

	function set.custom(
		encode: (value: unknown) -> unknown,
		decode: (encoded: unknown) -> unknown,
		options: CustomOptions?
	): Schema
		return Schema.fromCodec({
			name = options and options.name or "custom",
			version = options and options.version or 1,
			is = options and options.is or function(value: unknown): boolean
				return value ~= nil
			end,
			encode = encode,
			decode = function(encoded: unknown): (boolean, unknown)
				local ok, value = pcall(decode, encoded)
				if not ok then
					return false, tostring(value)
				end
				return true, value
			end,
		})
	end

	return table.freeze(set)
end

-- The datatypes of the running Roblox game. Only valid inside Roblox
function Codecs.liveDatatypes(): Datatypes
	return {
		vector3 = Vector3.new,
		vector2 = Vector2.new,
		cframe = function(components: { number }): unknown
			return CFrame.new(table.unpack(components))
		end,
		color3 = Color3.new,
		udim2 = UDim2.new,
		brickColor = function(number: number): unknown
			return BrickColor.new(number)
		end,
		dateTimeFromMillis = DateTime.fromUnixTimestampMillis,
		dateTimeToMillis = function(value: unknown): number
			return (value :: DateTime).UnixTimestampMillis
		end,
	}
end

return Codecs
