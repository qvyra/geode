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

-- Reads back what Path.format wrote, like `inventory[3].name` or `["odd key"]`. Nil when the
-- text isn't in that form, e.g. a custom guard's free-form path
function Path.parseFormatted(text: string): Path?
	if text == "" then
		return {}
	end
	local parsed: Path = {}
	local index = 1
	local length = #text
	while index <= length do
		local char = string.sub(text, index, index)
		if char == "[" then
			local number, after = string.match(text, "^%[(%d+)%]()", index)
			if number then
				table.insert(parsed, tonumber(number) :: number)
				index = after :: number
				continue
			end
			if string.sub(text, index + 1, index + 1) ~= '"' then
				return nil
			end
			-- a %q string: walk to the closing quote, honouring escapes
			local cursor = index + 2
			local chunks = {}
			while cursor <= length do
				local c = string.sub(text, cursor, cursor)
				if c == "\\" then
					local nextChar = string.sub(text, cursor + 1, cursor + 1)
					local digits = string.match(text, "^%d%d?%d?", cursor + 1)
					if digits then
						table.insert(chunks, string.char(tonumber(digits) :: number))
						cursor += 1 + #digits
					elseif nextChar == "n" or nextChar == "\n" then
						table.insert(chunks, "\n")
						cursor += 2
					elseif nextChar == "r" then
						table.insert(chunks, "\r")
						cursor += 2
					elseif nextChar == "t" then
						table.insert(chunks, "\t")
						cursor += 2
					else
						table.insert(chunks, nextChar)
						cursor += 2
					end
				elseif c == '"' then
					break
				else
					table.insert(chunks, c)
					cursor += 1
				end
			end
			if string.sub(text, cursor, cursor + 1) ~= '"]' then
				return nil
			end
			table.insert(parsed, table.concat(chunks))
			index = cursor + 2
		else
			if char == "." then
				if #parsed == 0 then
					return nil
				end
				index += 1
			elseif #parsed > 0 then
				return nil
			end
			local name, after = string.match(text, "^([%a_][%w_]*)()", index)
			if not name then
				return nil
			end
			table.insert(parsed, name)
			index = after :: number
		end
	end
	return parsed
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
