--!strict

-- Type builders. Every builder returns a frozen node, so schemas can be shared and reused freely

export type Codec = {
	name: string,
	version: number,
	is: (value: unknown) -> boolean,
	encode: (value: unknown) -> unknown,
	-- false and a reason when the stored form is malformed
	decode: (encoded: unknown) -> (boolean, unknown),
}

export type Kind =
	"string"
	| "number"
	| "boolean"
	| "literal"
	| "enum"
	| "array"
	| "map"
	| "struct"
	| "optional"
	| "union"
	| "codec"
	| "json"

-- One record for every kind. Only the fields of its kind are set
export type Schema = {
	kind: Kind,
	minLength: number?,
	maxLength: number?,
	pattern: string?,
	min: number?,
	max: number?,
	integer: boolean?,
	value: unknown,
	values: { unknown }?,
	item: Schema?,
	key: Schema?,
	maxEntries: number?,
	fields: { [string]: Schema }?,
	-- sorted so issues come out in a stable order
	fieldOrder: { string }?,
	extra: boolean?,
	options: { Schema }?,
	codec: Codec?,
}

export type StringOptions = {
	minLength: number?,
	maxLength: number?,
	-- A Lua pattern the whole string must match
	pattern: string?,
}

export type NumberOptions = {
	min: number?,
	max: number?,
	integer: boolean?,
}

export type ArrayOptions = {
	minLength: number?,
	maxLength: number?,
}

export type MapOptions = {
	key: Schema?,
	maxEntries: number?,
}

export type StructOptions = {
	-- allow undeclared keys. Off by default so typos get caught
	extra: boolean?,
}

--[=[
	@class t

	Schema builders. Each one describes a shape and its limits, and stores and guards check values
	against it
]=]
local t = {}

local function node(fields: Schema): Schema
	return table.freeze(fields)
end

local function checkBounds(low: number?, high: number?, what: string)
	if low and high then
		assert(low <= high, `{what}: minimum {low} is above maximum {high}`)
	end
end

local function isSchema(value: unknown): boolean
	return type(value) == "table" and type((value :: { kind: unknown }).kind) == "string"
end

--[=[
	@within t
	@param options StringOptions?
	@return Schema
]=]
function t.string(options: StringOptions?): Schema
	local minLength = options and options.minLength
	local maxLength = options and options.maxLength
	checkBounds(minLength, maxLength, "t.string")
	return node({
		kind = "string",
		minLength = minLength,
		maxLength = maxLength,
		pattern = options and options.pattern,
	})
end

--[=[
	@within t
	@param options NumberOptions?
	@return Schema
]=]
function t.number(options: NumberOptions?): Schema
	local min = options and options.min
	local max = options and options.max
	checkBounds(min, max, "t.number")
	return node({
		kind = "number",
		min = min,
		max = max,
		integer = options and options.integer,
	})
end

--[=[
	A number with no fractional part

	@within t
	@param options NumberOptions?
	@return Schema
]=]
function t.integer(options: NumberOptions?): Schema
	local min = options and options.min
	local max = options and options.max
	checkBounds(min, max, "t.integer")
	return node({ kind = "number", min = min, max = max, integer = true })
end

--[=[
	@within t
	@return Schema
]=]
function t.boolean(): Schema
	return node({ kind = "boolean" })
end

--[=[
	Exactly this value

	@within t
	@param value string | number | boolean
	@return Schema
]=]
function t.literal(value: string | number | boolean): Schema
	return node({ kind = "literal", value = value })
end

--[=[
	One of a fixed list of values

	@within t
	@param values { string | number }
	@return Schema

	```lua
	local Rarity = Geode.t.enum({ "common", "rare", "epic" })
	```
]=]
function t.enum(values: { string | number }): Schema
	assert(#values > 0, "t.enum needs at least one value")
	return node({ kind = "enum", values = table.freeze(table.clone(values)) :: { unknown } })
end

--[=[
	A list without holes

	@within t
	@param item Schema
	@param options ArrayOptions?
	@return Schema
]=]
function t.array(item: Schema, options: ArrayOptions?): Schema
	assert(isSchema(item), "t.array needs an item schema")
	local minLength = options and options.minLength
	local maxLength = options and options.maxLength
	checkBounds(minLength, maxLength, "t.array")
	return node({ kind = "array", item = item, minLength = minLength, maxLength = maxLength })
end

--[=[
	A table with string keys and values of one schema

	@within t
	@param value Schema
	@param options MapOptions?
	@return Schema
]=]
function t.map(value: Schema, options: MapOptions?): Schema
	assert(isSchema(value), "t.map needs a value schema")
	local key = options and options.key
	if key then
		assert(key.kind == "string", "t.map keys must be a t.string schema")
	end
	return node({
		kind = "map",
		item = value,
		key = key,
		maxEntries = options and options.maxEntries,
	})
end

--[=[
	A table with named fields

	@within t
	@param fields { [string]: Schema }
	@param options StructOptions?
	@return Schema

	```lua
	local Item = Geode.t.struct({
		id = Geode.t.string(),
		amount = Geode.t.integer({ min = 1 }),
	})
	```
]=]
function t.struct(fields: { [string]: Schema }, options: StructOptions?): Schema
	for name, field in fields do
		assert(type(name) == "string", "t.struct field names must be strings")
		assert(isSchema(field), `t.struct field {name} isn't a schema`)
	end
	local order = {}
	for name in fields do
		table.insert(order, name)
	end
	table.sort(order)
	return node({
		kind = "struct",
		fields = table.freeze(table.clone(fields)),
		fieldOrder = table.freeze(order),
		extra = options and options.extra,
	})
end

--[=[
	The inner schema, or nil

	@within t
	@param inner Schema
	@return Schema
]=]
function t.optional(inner: Schema): Schema
	assert(isSchema(inner), "t.optional needs a schema")
	return node({ kind = "optional", item = inner })
end

--[=[
	Any one of several schemas

	@within t
	@param options { Schema }
	@return Schema
]=]
function t.union(options: { Schema }): Schema
	assert(#options >= 2, "t.union needs at least two options")
	for _, option in options do
		assert(isSchema(option), "t.union options must be schemas")
	end
	return node({ kind = "union", options = table.freeze(table.clone(options)) })
end

--[=[
	Any value a DataStore can store faithfully, with no further shape. Handy while part of the
	data isn't typed yet

	@within t
	@return Schema
]=]
function t.json(): Schema
	return node({ kind = "json" })
end

-- codecs build their nodes here, so a codec and its schema always match
--[=[
	A schema that stores values through `codec`

	@within t
]=]
function t.fromCodec(codec: Codec): Schema
	return node({ kind = "codec", codec = table.freeze(codec) })
end

t.isSchema = isSchema

return t
