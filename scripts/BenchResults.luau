--!strict

-- Turns what `lune run bench` saves into the bench data kept in benchmarks/. Plain Luau with no
-- Lune requires, so the tests can run it: the caller decodes and writes the files

local BenchResults = {}

export type RunInfo = {
	build: string,
	sourceTree: string,
	benchTree: string,
	workflowRun: string?,
}

--// JSON

-- Marks a table that has to come out as a JSON array even when it's empty
local ARRAY = table.freeze({ __array = true })

--[=[
	Marks a list so `encode` writes it as an array even when it's empty
]=]
function BenchResults.array<T>(list: { T }): { T }
	return setmetatable(list :: any, ARRAY) :: any
end

-- Keys that read best first. Everything else follows in alphabetical order
local KEY_ORDER = {
	"$schema",
	"schemaVersion",
	"kind",
	"id",
	"run",
	"date",
	"build",
	"suite",
	"scenario",
	"metric",
	"subject",
	"runs",
	"value",
}
local KEY_RANK: { [string]: number } = {}
for rank, key in KEY_ORDER do
	KEY_RANK[key] = rank
end

local function before(a: string, b: string): boolean
	local rankA, rankB = KEY_RANK[a], KEY_RANK[b]
	if rankA and rankB then
		return rankA < rankB
	elseif rankA or rankB then
		return rankA ~= nil
	end
	return a < b
end

local ESCAPES: { [string]: string } = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function quote(text: string): string
	local escaped = string.gsub(text, '[%c"\\]', function(char: string): string
		return ESCAPES[char] or string.format("\\u%04x", string.byte(char))
	end)
	return `"{escaped}"`
end

-- The shortest text that reads back as the same number, so files don't change between runs of
-- the same data
local function number(value: number): string
	if value ~= value or value == math.huge or value == -math.huge then
		error("JSON has no NaN or infinity")
	end
	if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
		return string.format("%d", value)
	end
	for precision = 15, 16 do
		local text = string.format("%." .. precision .. "g", value)
		if tonumber(text) == value then
			return text
		end
	end
	return string.format("%.17g", value)
end

local function isArray(value: { [any]: any }): boolean
	if getmetatable(value :: any) == ARRAY then
		return true
	end
	local count = 0
	for key in value do
		if type(key) ~= "number" then
			return false
		end
		count += 1
	end
	return count > 0 and count == #value
end

local function write(value: unknown, indent: string, out: { string })
	local kind = type(value)
	if kind == "string" then
		table.insert(out, quote(value :: string))
	elseif kind == "number" then
		table.insert(out, number(value :: number))
	elseif kind == "boolean" then
		table.insert(out, if value then "true" else "false")
	elseif kind == "nil" then
		table.insert(out, "null")
	elseif kind == "table" then
		local tbl = value :: { [any]: any }
		local inner = indent .. "\t"
		if isArray(tbl) then
			if #tbl == 0 then
				table.insert(out, "[]")
				return
			end
			local flat = true
			for _, item in ipairs(tbl) do
				if type(item) == "table" then
					flat = false
					break
				end
			end
			-- lists of plain values stay on one line, which keeps samples and timelines short
			if flat then
				table.insert(out, "[")
				for index, item in ipairs(tbl) do
					if index > 1 then
						table.insert(out, ", ")
					end
					write(item, inner, out)
				end
				table.insert(out, "]")
				return
			end
			table.insert(out, "[\n")
			for index, item in ipairs(tbl) do
				table.insert(out, inner)
				write(item, inner, out)
				table.insert(out, if index < #tbl then ",\n" else "\n")
			end
			table.insert(out, indent .. "]")
			return
		end
		local keys: { string } = {}
		for key in tbl do
			if type(key) ~= "string" then
				error(`a JSON object can only have string keys, found a {type(key)}`)
			end
			table.insert(keys, key)
		end
		if #keys == 0 then
			table.insert(out, "{}")
			return
		end
		table.sort(keys, before)
		table.insert(out, "{\n")
		for index, key in keys do
			table.insert(out, `{inner}{quote(key)}: `)
			write(tbl[key], inner, out)
			table.insert(out, if index < #keys then ",\n" else "\n")
		end
		table.insert(out, indent .. "}")
	else
		error(`JSON can't hold a {kind}`)
	end
end

--[=[
	Encodes a value as JSON with tabs, keys in a fixed order and numbers in their shortest exact
	form, so the same data always gives the same file
]=]
function BenchResults.encode(value: unknown): string
	local out = {}
	write(value, "", out)
	table.insert(out, "\n")
	return table.concat(out)
end

-- Lune's JSON decoder can be one bit off on the last digit of a float, so runs are read here with
-- tonumber, which rounds correctly, and a re-encoded run matches what the bench wrote
local function decodeAt(text: string, at: number): (unknown, number)
	at = string.find(text, "[^ \t\r\n]", at) or error("JSON ended early")
	local char = string.sub(text, at, at)
	if char == "{" then
		local object: { [string]: unknown } = {}
		at = string.find(text, "[^ \t\r\n]", at + 1) or error("JSON ended early")
		if string.sub(text, at, at) == "}" then
			return object, at + 1
		end
		while true do
			local key, value
			key, at = decodeAt(text, at)
			if type(key) ~= "string" then
				error(`expected a key at {at}`)
			end
			at = string.find(text, ":", at, true) or error(`expected : at {at}`)
			value, at = decodeAt(text, at + 1)
			object[key :: string] = value
			at = string.find(text, "[^ \t\r\n]", at) or error("JSON ended early")
			local after = string.sub(text, at, at)
			if after == "}" then
				return object, at + 1
			elseif after ~= "," then
				error(`expected , or }} at {at}`)
			end
			at += 1
		end
	elseif char == "[" then
		local list = BenchResults.array({})
		at = string.find(text, "[^ \t\r\n]", at + 1) or error("JSON ended early")
		if string.sub(text, at, at) == "]" then
			return list, at + 1
		end
		while true do
			local value
			value, at = decodeAt(text, at)
			if value == nil then
				error(`null inside a list at {at}`)
			end
			table.insert(list, value)
			at = string.find(text, "[^ \t\r\n]", at) or error("JSON ended early")
			local after = string.sub(text, at, at)
			if after == "]" then
				return list, at + 1
			elseif after ~= "," then
				error(`expected , or ] at {at}`)
			end
			at += 1
		end
	elseif char == '"' then
		local parts = {}
		local from = at + 1
		while true do
			local stop = string.find(text, '["\\]', from) or error("unfinished string")
			table.insert(parts, string.sub(text, from, stop - 1))
			if string.sub(text, stop, stop) == '"' then
				return table.concat(parts), stop + 1
			end
			local escape = string.sub(text, stop + 1, stop + 1)
			if escape == "u" then
				local code = tonumber(string.sub(text, stop + 2, stop + 5), 16) or error("bad \\u")
				from = stop + 6
				if
					code >= 0xD800
					and code <= 0xDBFF
					and string.sub(text, from, from + 1) == "\\u"
				then
					local low = tonumber(string.sub(text, from + 2, from + 5), 16)
						or error("bad \\u")
					code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
					from += 6
				end
				table.insert(parts, utf8.char(code))
			else
				local plain = ({ b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" })[escape]
				table.insert(parts, plain or escape)
				from = stop + 2
			end
		end
	elseif string.sub(text, at, at + 3) == "true" then
		return true, at + 4
	elseif string.sub(text, at, at + 4) == "false" then
		return false, at + 5
	elseif string.sub(text, at, at + 3) == "null" then
		return nil, at + 4
	end
	local literal = string.match(text, "^-?%d+%.?%d*[eE]?[-+]?%d*", at)
	local value = literal and tonumber(literal)
	if value == nil then
		error(`unexpected {char} at {at}`)
	end
	return value, at + #(literal :: string)
end

--[=[
	Decodes JSON with every number exactly as written. Lists come back marked as lists, so an empty
	one is written back as `[]`
]=]
function BenchResults.decode(text: string): any
	local value, at = decodeAt(text, 1)
	if string.find(text, "[^ \t\r\n]", at) then
		error(`more after the JSON value at {at}`)
	end
	return value
end

--// cleaning a run

-- Fields that only identify the place, the server or a key. None of them is a measurement
local DROPPED = table.freeze({
	jobId = true,
	placeId = true,
	placeVersion = true,
	universeId = true,
	key = true,
	topic = true,
})

local UUID = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"

-- Ids that turn up inside messages: JobIds, and place or universe ids, which are long numbers
local function scrub(text: string): string
	local withoutJobs = string.gsub(text, UUID, "<job>")
	local withoutIds = string.gsub(withoutJobs, "%d%d%d%d%d%d%d%d%d%d%d%d+", "<id>")
	return withoutIds
end

local function clean(value: unknown): unknown
	if type(value) == "string" then
		return scrub(value)
	elseif type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in value :: { [any]: any } do
		if type(key) == "string" and DROPPED[key] then
			continue
		end
		copy[key] = clean(child)
	end
	if getmetatable(value :: any) == ARRAY then
		setmetatable(copy, ARRAY :: any)
	end
	return copy
end

--[=[
	Cleans one bench run for keeping in the repo. Drops the place version, JobIds, place ids, keys
	and messaging topics, and blanks ids inside messages. Whether each task had a server to itself
	is kept as `environment.ownServer`. Every measurement stays as the bench saved it
]=]
function BenchResults.sanitize(results: any, info: RunInfo): { [string]: any }
	local seen: { [string]: number } = {}
	for _, entry in results.tasks do
		local jobId = entry.report and entry.report.environment and entry.report.environment.jobId
		if jobId then
			seen[jobId] = (seen[jobId] or 0) + 1
		end
	end

	local tasks = BenchResults.array({})
	for _, entry in results.tasks do
		local copy = clean(entry) :: { [string]: any }
		local environment = entry.report and entry.report.environment
		if environment and environment.jobId then
			copy.report.environment.ownServer = seen[environment.jobId] == 1
		end
		if copy.logTail and next(copy.logTail) == nil then
			copy.logTail = nil
		end
		table.insert(tasks, copy)
	end

	return {
		run = results.run,
		date = results.date,
		build = info.build,
		geodeSourceTree = info.sourceTree,
		benchTree = info.benchTree,
		workflowRun = info.workflowRun,
		libraries = clean(results.pins),
		refused = clean(results.refused),
		tasks = tasks,
	}
end

return BenchResults
