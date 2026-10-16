--!strict

-- What development tools need to edit a profile: which ops a store allows, what the schema says
-- at a path, and turning arguments that crossed the bridge in stored form back into live values.
-- Everything here answers with plain data, since it crosses a Bindable

local Path = require("../Matrix/Path")
local Schema = require("../Obsidian/Schema")
local Validate = require("../Obsidian/Validate")

type Schema = Schema.Schema

local Tooling = {}

export type ArgSpec = {
	name: string,
	-- "path", "number", "index", "value" (decoded with the schema at the op's path), "item" (an
	-- item of the list at the path), "fields" (fields of the struct at the path)
	type: string,
	optional: boolean?,
}

export type OpSpec = {
	name: string,
	builtin: boolean,
	-- nil for custom ops, which don't declare their arguments
	args: { ArgSpec }?,
}

-- Built-in ops a tool can call. `update` takes a function, so it can't cross a Bindable
local function arg(name: string, kind: string, optional: boolean?): ArgSpec
	return { name = name, type = kind, optional = optional }
end

local BUILT_IN: { OpSpec } = {
	{ name = "set", builtin = true, args = { arg("path", "path"), arg("value", "value") } },
	{
		name = "increment",
		builtin = true,
		args = { arg("path", "path"), arg("amount", "number", true) },
	},
	{
		name = "decrement",
		builtin = true,
		args = { arg("path", "path"), arg("amount", "number", true) },
	},
	{ name = "append", builtin = true, args = { arg("path", "path"), arg("value", "item") } },
	{
		name = "insert",
		builtin = true,
		args = { arg("path", "path"), arg("index", "index"), arg("value", "item") },
	},
	{ name = "remove", builtin = true, args = { arg("path", "path") } },
	{ name = "clear", builtin = true, args = { arg("path", "path", true) } },
	{
		name = "merge",
		builtin = true,
		args = { arg("path", "path", true), arg("partial", "fields") },
	},
}

local SPECS: { [string]: OpSpec } = {}
for _, spec in BUILT_IN do
	SPECS[spec.name] = spec
end

-- The schema node at `path` with optionals unwrapped. Nil past what the schema declares, so a
-- path that goes inside a codec or json value has no node
local function nodeAt(root: Schema, path: Path.Path): Schema?
	local node, depth = Validate.at(root, path)
	if node == nil or depth < #path then
		return nil
	end
	while node.kind == "optional" do
		node = node.item :: Schema
	end
	return node
end

local function describe(node: Schema): { [string]: unknown }
	local out: { [string]: unknown } = { kind = node.kind }
	if node.kind == "codec" then
		local codec = node.codec :: Schema.Codec
		out.codec = codec.name
		out.codecVersion = codec.version
	elseif node.kind == "struct" then
		out.fields = table.clone(node.fieldOrder :: { string })
		out.extra = node.extra == true
	elseif node.kind == "array" or node.kind == "map" then
		out.item = (node.item :: Schema).kind
	elseif node.kind == "enum" then
		out.values = table.clone(node.values :: { unknown })
	elseif node.kind == "literal" then
		out.value = node.value
	elseif node.kind == "union" then
		local options = {}
		for _, option in node.options :: { Schema } do
			table.insert(options, option.kind)
		end
		out.options = options
	end
	for _, bound in { "min", "max", "integer", "minLength", "maxLength", "maxEntries" } do
		local value = (node :: any)[bound]
		if value ~= nil then
			out[bound] = value
		end
	end
	return out
end

-- Whether `op` is one of the built-in ops a tool can call
function Tooling.isBuiltIn(op: string): boolean
	return SPECS[op] ~= nil
end

-- Paths cross as a list of segments, or a dotted string
local function readPath(raw: unknown): Path.Path?
	if raw == nil then
		return {}
	end
	if type(raw) ~= "string" and type(raw) ~= "table" then
		return nil
	end
	local ok, parsed = pcall(Path.parse, raw :: Path.PathLike)
	return if ok then parsed else nil
end

-- The ops a store with `custom` ops enabled lets a tool call, built-ins first
function Tooling.ops(custom: { string }?): { OpSpec }
	local list: { OpSpec } = table.clone(BUILT_IN)
	local names: { string } = custom or {}
	for _, name in names do
		table.insert(list, { name = name, builtin = false })
	end
	return list
end

-- What `schema` says at `path`: `{ declared = false }` past what it describes, or the node's
-- kind with the details a tool needs to build an editor for it
function Tooling.schemaAt(schema: Schema?, rawPath: unknown): { [string]: unknown }
	local path = readPath(rawPath)
	if path == nil then
		return { error = "a path is a list of segments or a dotted string" }
	end
	if schema == nil then
		return { declared = false, untyped = true }
	end
	local node = nodeAt(schema, path)
	if node == nil then
		return { declared = false }
	end
	local out = describe(node)
	out.declared = true
	return out
end

local function decodeAt(schema: Schema?, node: Schema?, value: unknown): (boolean, unknown)
	if schema == nil or node == nil then
		return true, value
	end
	local ok, decoded = Validate.decode(node, value)
	if not ok then
		return false, "the value doesn't match the schema at that path"
	end
	return true, decoded
end

-- Turns `args` for `op` from their stored form back into live values, using the codec at the
-- op's path. Custom ops get their arguments as they came
function Tooling.decodeArgs(
	schema: Schema?,
	op: string,
	args: { unknown }
): (boolean, { unknown } | string, number)
	local spec = SPECS[op]
	if spec == nil then
		return true, args, #args
	end
	local specs = spec.args :: { ArgSpec }
	local out: { unknown } = {}
	local path: Path.Path? = nil
	for index, argSpec in specs do
		local raw = args[index]
		if raw == nil then
			if not argSpec.optional then
				return false, `{op} needs its {argSpec.name} argument`, 0
			end
			continue
		end
		if argSpec.type == "path" then
			path = readPath(raw)
			if path == nil then
				return false, "a path is a list of segments or a dotted string", 0
			end
			out[index] = path
		elseif argSpec.type == "number" or argSpec.type == "index" then
			if type(raw) ~= "number" then
				return false, `{op}'s {argSpec.name} has to be a number`, 0
			end
			out[index] = raw
		else
			local node = if schema and path then nodeAt(schema, path) else nil
			if argSpec.type == "item" and node then
				node = if node.kind == "array" then node.item else nil
			end
			if
				argSpec.type == "fields"
				and node
				and node.kind == "struct"
				and type(raw) == "table"
			then
				local fields = {}
				for name, value in raw :: { [string]: unknown } do
					local field = (node.fields :: { [string]: Schema })[name]
					local ok, decoded = decodeAt(schema, field, value)
					if not ok then
						return false, `{name}: {decoded}`, 0
					end
					fields[name] = decoded
				end
				out[index] = fields
			else
				local ok, decoded = decodeAt(schema, node, raw)
				if not ok then
					return false, decoded :: string, 0
				end
				out[index] = decoded
			end
		end
	end
	return true, out, #specs
end

return Tooling
