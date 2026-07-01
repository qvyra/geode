--!strict

-- Checks live values against a schema, and converts between live values and their stored form.
-- Live values may hold Roblox datatypes. Stored values are plain JSON shaped data

local Issues = require("./Issues")
local Schema = require("./Schema")
local Storable = require("./Storable")

type Schema = Schema.Schema
type Issues = Issues.Issues

export type Options = {
	-- name at the start of every path, default "data"
	root: string?,
	-- max issues to collect, default 50
	limit: number?,
}

local Validate = {}

local function describe(value: unknown): string
	if type(value) == "string" then
		return string.format("%q", value)
	end
	return tostring(value)
end

local function isSequence(source: { [unknown]: unknown }): boolean
	local count = 0
	for key in source do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return false
		end
		count += 1
	end
	return count == #source
end

local check: (
	schema: Schema,
	value: unknown,
	path: string,
	issues: Issues,
	stack: { [unknown]: boolean }
) -> ()

local function checkNumber(schema: Schema, value: number, path: string, issues: Issues)
	if value ~= value then
		issues:add(path, "nan", "NaN can't be stored")
		return
	end
	if value == math.huge or value == -math.huge then
		issues:add(path, "infinite", "infinity can't be stored")
		return
	end
	if schema.integer and value % 1 ~= 0 then
		issues:add(path, "integer", `expected a whole number, got {value}`)
	end
	if schema.min and value < schema.min then
		issues:add(path, "range", `{value} is below the minimum of {schema.min}`)
	end
	if schema.max and value > schema.max then
		issues:add(path, "range", `{value} is above the maximum of {schema.max}`)
	end
end

local function checkString(schema: Schema, value: string, path: string, issues: Issues)
	local length = utf8.len(value)
	if length == nil then
		issues:add(path, "utf8", "string isn't valid UTF-8")
		return
	end
	if schema.minLength and length < schema.minLength then
		issues:add(path, "length", `{length} characters is shorter than {schema.minLength}`)
	end
	if schema.maxLength and length > schema.maxLength then
		issues:add(path, "length", `{length} characters is longer than {schema.maxLength}`)
	end
	if schema.pattern and string.match(value, `^{schema.pattern}$`) == nil then
		issues:add(path, "pattern", `doesn't match the pattern {schema.pattern}`)
	end
end

local function checkTable(
	schema: Schema,
	source: { [unknown]: unknown },
	path: string,
	issues: Issues,
	stack: { [unknown]: boolean }
)
	if stack[source] then
		issues:add(path, "cycle", "table contains itself")
		return
	end
	stack[source] = true

	if schema.kind == "array" then
		if not isSequence(source) then
			-- reuse the storable check, it says exactly what's wrong with the keys
			if Storable.shapeOf(source, path, issues) ~= nil then
				issues:add(path, "type", "expected an array, got a table with named keys")
			end
		else
			local list = source :: { unknown }
			if schema.minLength and #list < schema.minLength then
				issues:add(path, "length", `{#list} items is fewer than {schema.minLength}`)
			end
			if schema.maxLength and #list > schema.maxLength then
				issues:add(path, "length", `{#list} items is more than {schema.maxLength}`)
			end
			for index, item in list do
				check(schema.item :: Schema, item, Issues.child(path, index), issues, stack)
			end
		end
	elseif schema.kind == "map" then
		local entries = 0
		for key, item in source do
			entries += 1
			local childPath = Issues.child(path, key)
			if type(key) ~= "string" then
				issues:add(childPath, "key", `map keys must be strings, found a {typeof(key)}`)
				continue
			end
			if schema.key then
				checkString(schema.key, key :: string, childPath, issues)
			elseif utf8.len(key :: string) == nil then
				issues:add(childPath, "utf8", "key isn't valid UTF-8")
			end
			check(schema.item :: Schema, item, childPath, issues, stack)
		end
		if schema.maxEntries and entries > schema.maxEntries then
			issues:add(path, "entries", `{entries} entries is more than {schema.maxEntries}`)
		end
	elseif schema.kind == "struct" then
		local fields = schema.fields :: { [string]: Schema }
		for _, name in schema.fieldOrder :: { string } do
			check(fields[name], source[name], Issues.child(path, name), issues, stack)
		end
		for key in source do
			if type(key) ~= "string" then
				issues:add(path, "key", `struct keys must be strings, found a {typeof(key)}`)
			elseif fields[key :: string] == nil and not schema.extra then
				issues:add(Issues.child(path, key), "extra", "field isn't declared in the schema")
			end
		end
	end

	stack[source] = nil
end

local EXPECTED_TABLE: { [string]: boolean } = { array = true, map = true, struct = true }

check = function(
	schema: Schema,
	value: unknown,
	path: string,
	issues: Issues,
	stack: { [unknown]: boolean }
)
	if issues:full() then
		return
	end
	local kind = schema.kind

	if kind == "optional" then
		if value ~= nil then
			check(schema.item :: Schema, value, path, issues, stack)
		end
		return
	elseif kind == "json" then
		Storable.checkInto(value, path, issues, stack)
		return
	elseif kind == "union" then
		for _, option in schema.options :: { Schema } do
			local scratch = Issues.new(1)
			check(option, value, path, scratch, stack)
			if scratch:count() == 0 then
				return
			end
		end
		issues:add(path, "union", `{describe(value)} doesn't match any of the allowed shapes`)
		return
	elseif kind == "codec" then
		local codec = schema.codec :: Schema.Codec
		if not codec.is(value) then
			issues:add(path, "codec", `expected a {codec.name}, got a {typeof(value)}`)
		end
		return
	elseif kind == "literal" then
		if value ~= schema.value then
			issues:add(path, "literal", `expected {describe(schema.value)}, got {describe(value)}`)
		end
		return
	elseif kind == "enum" then
		if not table.find(schema.values :: { unknown }, value) then
			issues:add(path, "enum", `{describe(value)} isn't one of the allowed values`)
		end
		return
	end

	local actual = typeof(value)
	if EXPECTED_TABLE[kind] then
		if actual ~= "table" then
			issues:add(
				path,
				"type",
				`expected a {kind}, got {if value == nil then "nil" else `a {actual}`}`
			)
			return
		end
		checkTable(schema, value :: { [unknown]: unknown }, path, issues, stack)
	elseif kind == "number" then
		if actual ~= "number" then
			issues:add(
				path,
				"type",
				`expected a number, got {if value == nil then "nil" else `a {actual}`}`
			)
			return
		end
		checkNumber(schema, value :: number, path, issues)
	elseif kind == "string" then
		if actual ~= "string" then
			issues:add(
				path,
				"type",
				`expected a string, got {if value == nil then "nil" else `a {actual}`}`
			)
			return
		end
		checkString(schema, value :: string, path, issues)
	elseif kind == "boolean" then
		if actual ~= "boolean" then
			issues:add(
				path,
				"type",
				`expected a boolean, got {if value == nil then "nil" else `a {actual}`}`
			)
		end
	end
end

--[=[
	Checks a live value against a schema and reports every problem with its path

	@within Schema
	@param schema Schema
	@param value unknown
	@param options Options?
	@return ValidationResult

	```lua
	local result = Geode.schema.validate(PlayerSchema, data)
	if not result.ok then
		warn(result.issues[1].path, result.issues[1].message)
	end
	```
]=]
function Validate.validate(schema: Schema, value: unknown, options: Options?): Issues.Result
	local issues = Issues.new(options and options.limit)
	check(schema, value, options and options.root or "data", issues, {})
	return issues:result()
end

-- Encoding

local function copyPlain(value: unknown): unknown
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in value :: { [unknown]: unknown } do
		copy[key] = copyPlain(child)
	end
	return copy
end

local function encode(schema: Schema, value: unknown): unknown
	if value == nil then
		return nil
	end
	local kind = schema.kind
	if kind == "codec" then
		return (schema.codec :: Schema.Codec).encode(value)
	elseif kind == "optional" then
		return encode(schema.item :: Schema, value)
	elseif kind == "union" then
		for _, option in schema.options :: { Schema } do
			local scratch = Issues.new(1)
			check(option, value, "", scratch, {})
			if scratch:count() == 0 then
				return encode(option, value)
			end
		end
		return copyPlain(value)
	elseif kind == "array" or kind == "map" then
		local copy = {}
		for key, child in value :: { [unknown]: unknown } do
			copy[key] = encode(schema.item :: Schema, child)
		end
		return copy
	elseif kind == "struct" then
		local fields = schema.fields :: { [string]: Schema }
		local copy = {}
		for key, child in value :: { [unknown]: unknown } do
			local field = fields[key :: string]
			copy[key] = if field then encode(field, child) else copyPlain(child)
		end
		return copy
	end
	return copyPlain(value)
end

--[=[
	Converts a valid live value to its stored form. Validate first, encoding assumes the value
	fits the schema. The result shares no tables with the input

	@within Schema
]=]
function Validate.encode(schema: Schema, value: unknown): unknown
	return encode(schema, value)
end

local function decode(schema: Schema, encoded: unknown, path: string, issues: Issues): unknown
	if encoded == nil then
		return nil
	end
	local kind = schema.kind
	if kind == "codec" then
		local codec = schema.codec :: Schema.Codec
		local ok, value = codec.decode(encoded)
		if not ok then
			issues:add(path, "codec", tostring(value))
			return nil
		end
		return value
	elseif kind == "optional" then
		return decode(schema.item :: Schema, encoded, path, issues)
	elseif kind == "union" then
		-- Codec options can't be told apart by their stored form alone, so the first option whose
		-- decode succeeds wins
		for _, option in schema.options :: { Schema } do
			local scratch = Issues.new(1)
			local value = decode(option, encoded, path, scratch)
			if scratch:count() == 0 then
				local fit = Issues.new(1)
				check(option, value, path, fit, {})
				if fit:count() == 0 then
					return value
				end
			end
		end
		issues:add(path, "union", "stored value doesn't decode as any of the allowed shapes")
		return nil
	elseif (kind == "array" or kind == "map" or kind == "struct") and type(encoded) == "table" then
		local fields = schema.fields
		local copy = {}
		for key, child in encoded :: { [unknown]: unknown } do
			local childSchema = if fields then fields[key :: string] else schema.item
			copy[key] = if childSchema
				then decode(childSchema, child, Issues.child(path, key), issues)
				else copyPlain(child)
		end
		return copy
	end
	return copyPlain(encoded)
end

--[=[
	Converts a stored value back to its live form. Reports stored values that a codec can't read,
	like a CFrame saved with the wrong number of components

	@within Schema
	@return (boolean, unknown | ValidationResult) -- true and the value, or false and the issues
]=]
function Validate.decode(schema: Schema, encoded: unknown, options: Options?): (boolean, unknown)
	local issues = Issues.new(options and options.limit)
	local value = decode(schema, encoded, options and options.root or "data", issues)
	if issues:count() > 0 then
		return false, issues:result()
	end
	return true, value
end

return Validate
