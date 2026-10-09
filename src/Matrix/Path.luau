--!strict

-- Paths address a value inside a store. They can be written as a string, "inventory.3.pos", or as
-- a list, { "inventory", 3, "pos" }. In the string form a segment made only of digits is an array
-- index, so string keys that look like numbers need the list form

export type Segment = string | number
export type Path = { Segment }
export type PathLike = string | Path

local Path = {}

local function checkSegment(segment: unknown, source: unknown): Segment
	if type(segment) == "string" then
		if segment == "" then
			error(`path {Path.describe(source)} has an empty segment`, 0)
		end
		return segment
	elseif type(segment) == "number" then
		if segment % 1 ~= 0 or segment < 1 then
			error(`path {Path.describe(source)} has index {segment}, indices start at 1`, 0)
		end
		return segment
	end
	error(`path {Path.describe(source)} has a {typeof(segment)} segment`, 0)
end

-- Turns either path form into the list form. An empty string or list means the root
function Path.parse(path: PathLike?): Path
	if path == nil or path == "" then
		return {}
	end
	local parsed: Path = {}
	if type(path) == "string" then
		for piece in string.gmatch(path .. ".", "([^%.]*)%.") do
			local index = if string.match(piece, "^%d+$") then tonumber(piece) else nil
			table.insert(parsed, checkSegment(index or piece, path))
		end
	elseif type(path) == "table" then
		for _, segment in path do
			table.insert(parsed, checkSegment(segment, path))
		end
	else
		error(`a path must be a string or a list, got a {typeof(path)}`, 0)
	end
	return parsed
end

function Path.format(path: Path): string
	local parts = {}
	for _, segment in path do
		if type(segment) == "number" then
			table.insert(parts, `[{segment}]`)
		elseif string.match(segment, "^[%a_][%w_]*$") then
			table.insert(parts, if #parts == 0 then segment else `.{segment}`)
		else
			table.insert(parts, `[{string.format("%q", segment)}]`)
		end
	end
	return table.concat(parts)
end

function Path.describe(path: unknown): string
	if type(path) == "string" then
		return string.format("%q", path)
	end
	if type(path) == "table" then
		local parts = {}
		for _, segment in path :: { unknown } do
			table.insert(parts, tostring(segment))
		end
		return `\{ {table.concat(parts, ", ")} \}`
	end
	return tostring(path)
end

function Path.startsWith(path: Path, prefix: Path): boolean
	if #prefix > #path then
		return false
	end
	for index, segment in prefix do
		if path[index] ~= segment then
			return false
		end
	end
	return true
end

function Path.related(a: Path, b: Path): boolean
	return Path.startsWith(a, b) or Path.startsWith(b, a)
end

return Path
