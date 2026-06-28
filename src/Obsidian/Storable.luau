--!strict

-- Checks that a value survives a trip through a DataStore unchanged. JSON drops or mangles a lot
-- silently (NaN, holes in arrays, numeric keys, Roblox datatypes), so each of those is an error
-- here instead of a surprise on the next load

local Issues = require("./Issues")

local Storable = {}

type TableShape = "array" | "map"

-- Sorts out what kind of table this is, reporting key problems on the way. Returns nil when the
-- keys can't be stored at all
local function shapeOf(
	source: { [unknown]: unknown },
	path: string,
	issues: Issues.Issues
): TableShape?
	local numberKeys, stringKeys, highest = 0, 0, 0
	local valid = true

	for key in source do
		local keyType = type(key)
		if keyType == "string" then
			stringKeys += 1
			if utf8.len(key :: string) == nil then
				issues:add(
					path,
					"utf8",
					`key {string.format("%q", key :: string)} isn't valid UTF-8`
				)
				valid = false
			end
		elseif keyType == "number" then
			local index = key :: number
			if index % 1 ~= 0 or index < 1 then
				issues:add(path, "key", `key {index} isn't a positive whole number`)
				valid = false
			else
				numberKeys += 1
				highest = math.max(highest, index)
			end
		else
			issues:add(
				path,
				"key",
				`keys must be strings or array indices, found a {typeof(key)} key`
			)
			valid = false
		end
	end

	if not valid then
		return nil
	end
	if numberKeys > 0 and stringKeys > 0 then
		issues:add(path, "mixed", "table mixes array items and named keys")
		return nil
	end
	if numberKeys > 0 and highest ~= numberKeys then
		issues:add(
			path,
			"sparse",
			`array has holes: {numberKeys} items but the highest index is {highest}`
		)
		return nil
	end
	return if numberKeys > 0 then "array" else "map"
end

local function check(
	value: unknown,
	path: string,
	issues: Issues.Issues,
	stack: { [unknown]: boolean }
)
	if issues:full() then
		return
	end

	local kind = typeof(value)
	if kind == "nil" or kind == "boolean" then
		return
	elseif kind == "number" then
		local number = value :: number
		if number ~= number then
			issues:add(path, "nan", "NaN can't be stored")
		elseif number == math.huge or number == -math.huge then
			issues:add(path, "infinite", "infinity can't be stored")
		end
	elseif kind == "string" then
		if utf8.len(value :: string) == nil then
			issues:add(path, "utf8", "string isn't valid UTF-8")
		end
	elseif kind == "table" then
		local source = value :: { [unknown]: unknown }
		if stack[source] then
			issues:add(path, "cycle", "table contains itself")
			return
		end
		if shapeOf(source, path, issues) == nil then
			return
		end
		stack[source] = true
		for key, child in source do
			check(child, Issues.child(path, key), issues, stack)
		end
		stack[source] = nil
	elseif kind == "function" then
		issues:add(path, "function", "functions can't be stored")
	elseif kind == "thread" then
		issues:add(path, "thread", "threads can't be stored")
	elseif kind == "Instance" then
		issues:add(path, "instance", "Instances can't be stored, save an identifier instead")
	else
		issues:add(path, "datatype", `{kind} can't be stored as is, declare a codec for it`)
	end
end

--[=[
	Reports everything in `value` that a DataStore couldn't store faithfully

	@within Schema
	@param value unknown
	@param root string? -- name used at the start of every path, defaults to "data"
	@return ValidationResult
]=]
function Storable.check(value: unknown, root: string?, limit: number?): Issues.Result
	local issues = Issues.new(limit)
	check(value, root or "data", issues, {})
	return issues:result()
end

-- For callers that already hold an issue list. Passing the caller's stack keeps cycle detection
-- working across the boundary
function Storable.checkInto(
	value: unknown,
	path: string,
	issues: Issues.Issues,
	stack: { [unknown]: boolean }?
)
	check(value, path, issues, stack or {})
end

Storable.shapeOf = shapeOf

return Storable
