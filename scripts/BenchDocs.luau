--!strict

-- Fills the tables in docs/benchmarks.md from latest.json. A table sits between two comments,
--
--   <!-- bench:table hops start -->
--   <!-- bench:table hops end -->
--
-- and everything between them is written again. The prose around them stays as written. A table
-- with a notes column keeps each row's notes, matched by the row's label, since those are
-- written by hand. Tables come out the way Prettier formats them

local BenchDocs = {}

type Table = {
	headers: { string },
	-- the last column is kept by hand when set
	notes: boolean?,
	suites: { string },
	cells: (result: (scenario: string, metric: string) -> any) -> { string },
}

--// cells

local function seconds(value: number): string
	return string.format("%.2f", value)
end

local function timing(result: any): string
	if result == nil or result.value.n == 0 then
		return "-"
	end
	local value = result.value
	local failed = if value.failed > 0 then `, {value.failed} failed` else ""
	if value.kind == "range" then
		return `{seconds(value.min)} to {seconds(value.max)}{failed}`
	end
	return `{seconds(value.median)} ({seconds(value.min)} to {seconds(value.max)}, {value.n}{failed})`
end

local function amount(result: any): string
	if result == nil then
		return "-"
	end
	local value = result.value
	local function one(number: number): string
		return string.format("%.1f", number)
	end
	return `{one(value.median)} ({one(value.min)} to {one(value.max)}, {value.n})`
end

local function count(result: any): string
	if result == nil then
		return "-"
	end
	return `{result.value.passed} of {result.value.total}`
end

local function valuesSeen(result: any): string
	if result == nil then
		return "-"
	end
	local value = result.value
	local seen = {}
	for text, times in value.counts do
		table.insert(seen, { text = text, times = times })
	end
	table.sort(seen, function(a, b)
		return a.times > b.times or (a.times == b.times and a.text < b.text)
	end)
	local parts = {}
	for _, entry in seen do
		table.insert(parts, `{entry.text} in {entry.times}`)
	end
	return `{table.concat(parts, ", ")} of {value.total}`
end

local function joinWords(parts: { string }): string
	if #parts <= 1 then
		return parts[1] or "none"
	end
	return table.concat(parts, ", ", 1, #parts - 1) .. " and " .. parts[#parts]
end

local function requestWords(catalog: any, result: any): string
	if result == nil then
		return "-"
	end
	local parts = {}
	for _, method in catalog.requestMethods do
		local range = result.value.byMethod[method.id]
		if range == nil or range.max == 0 then
			continue
		end
		local times = if range.min == range.max
			then tostring(range.min)
			elseif range.max == range.min + 1 then `{range.min} or {range.max}`
			else `{range.min} to {range.max}`
		table.insert(parts, `{times} {method.label}`)
	end
	return joinWords(parts)
end

local function sameRequests(a: any, b: any): boolean
	if a == nil or b == nil then
		return a == b
	end
	for id, range in a.value.byMethod do
		local other = b.value.byMethod[id]
		if other == nil or other.min ~= range.min or other.max ~= range.max then
			return false
		end
	end
	for id in b.value.byMethod do
		if a.value.byMethod[id] == nil then
			return false
		end
	end
	return true
end

--// tables

local function tables(catalog: any): { [string]: Table }
	return {
		["perf-times"] = {
			headers = {
				"Library",
				"Load, new profile (s)",
				"Load, stored profile (s)",
				"Save (s)",
				"Release (s)",
			},
			suites = { "load-save-release" },
			cells = function(result)
				return {
					timing(result("load-new", "time")),
					timing(result("load-stored", "time")),
					timing(result("save", "time")),
					timing(result("release", "time")),
				}
			end,
		},
		["perf-requests"] = {
			headers = { "Library", "Load", "Save", "Release", "Notes" },
			notes = true,
			suites = { "load-save-release" },
			cells = function(result)
				local new = result("load-new", "requests")
				local stored = result("load-stored", "requests")
				local load = requestWords(catalog, new)
				if not sameRequests(new, stored) then
					load ..= `, stored profile {requestWords(catalog, stored)}`
				end
				return {
					load,
					requestWords(catalog, result("save", "requests")),
					requestWords(catalog, result("release", "requests")),
				}
			end,
		},
		hops = {
			headers = {
				"Library",
				"Old server releases (s)",
				"Saw the final save",
				"Old server keeps it (s)",
				"Value seen when kept",
				"Requests by the new server",
				"Notes",
			},
			notes = true,
			suites = { "server-hop" },
			cells = function(result)
				local releases = result("old-releases", "requests")
				local keeps = result("old-keeps", "requests")
				local requests = requestWords(catalog, releases)
				if not sameRequests(releases, keeps) then
					requests ..= `, when kept {requestWords(catalog, keeps)}`
				end
				return {
					timing(result("old-releases", "time")),
					count(result("old-releases", "final-save-seen")),
					timing(result("old-keeps", "time")),
					valuesSeen(result("old-keeps", "value-seen")),
					requests,
				}
			end,
		},
		throttling = {
			headers = {
				"Library",
				"Load (s)",
				"Save (s)",
				"Release (s)",
				"What the proxy saw during the load",
			},
			notes = true,
			suites = { "throttling" },
			cells = function(result)
				return {
					timing(result("load", "time")),
					timing(result("save", "time")),
					timing(result("release", "time")),
				}
			end,
		},
		memory = {
			headers = { "Library", "Heap per profile (KB)" },
			suites = { "memory" },
			cells = function(result)
				return { amount(result("loaded-profiles", "heap-per-profile")) }
			end,
		},
		["geode-edits"] = {
			headers = { "Library", "Time per edit (µs)" },
			suites = { "geode-edits" },
			cells = function(result)
				return { amount(result("increment", "time-per-edit")) }
			end,
		},
	}
end

--// markdown

local function width(text: string): number
	return utf8.len(text) or #text
end

-- A markdown table the way Prettier writes one: every column as wide as its widest cell
local function format(rows: { { string } }): string
	local widths = {}
	for _, row in rows do
		for column, cell in row do
			widths[column] = math.max(widths[column] or 3, width(cell))
		end
	end
	local function line(cells: { string }): string
		local padded = {}
		for column, cell in cells do
			padded[column] = cell .. string.rep(" ", widths[column] - width(cell))
		end
		return `| {table.concat(padded, " | ")} |`
	end
	local lines = { line(rows[1]) }
	local dashes = {}
	for column in rows[1] do
		dashes[column] = string.rep("-", widths[column])
	end
	table.insert(lines, line(dashes))
	for index = 2, #rows do
		table.insert(lines, line(rows[index]))
	end
	return table.concat(lines, "\n")
end

local function splitRow(line: string): { string }?
	if string.sub(line, 1, 1) ~= "|" then
		return nil
	end
	local cells = {}
	for cell in string.gmatch(string.sub(line, 2), "([^|]*)|") do
		table.insert(cells, (string.gsub(cell, "^%s*(.-)%s*$", "%1")))
	end
	return cells
end

-- Each row's last cell by its label, from the table that's there now
local function existingNotes(region: string): { [string]: string }
	local notes = {}
	local seen = 0
	for line in string.gmatch(region, "[^\n]+") do
		local cells = splitRow(line)
		if cells then
			seen += 1
			-- the first two lines are the header and the dashes
			if seen > 2 and #cells > 1 then
				notes[cells[1]] = cells[#cells]
			end
		end
	end
	return notes
end

local function labelOf(subject: any): string
	return subject.docsLabel or subject.config.label
end

local function render(catalog: any, latest: any, spec: Table, notes: { [string]: string }): string
	local rows = { spec.headers }
	for _, subject in catalog.subjects do
		local found: { [string]: any } = {}
		local any = false
		for _, result in latest.results do
			if result.subject == subject.id and table.find(spec.suites, result.suite) then
				found[`{result.scenario}|{result.metric}`] = result
				any = true
			end
		end
		if not any then
			continue
		end
		local label = labelOf(subject)
		local row = { label }
		for _, cell in
			spec.cells(function(scenario: string, metric: string): any
				return found[`{scenario}|{metric}`]
			end)
		do
			table.insert(row, cell)
		end
		if spec.notes then
			table.insert(row, notes[label] or "")
		end
		table.insert(rows, row)
	end
	return format(rows)
end

--[=[
	The page with every marked table written again from latest.json. Errors on a marker for a
	table it doesn't know, or one that isn't closed
]=]
function BenchDocs.fill(catalog: any, latest: any, markdown: string): string
	local specs = tables(catalog)
	local out = {}
	local at = 1
	while true do
		local start, startEnd, name =
			string.find(markdown, "<!%-%- bench:table ([%w-]+) start %-%->\n", at)
		if start == nil then
			table.insert(out, string.sub(markdown, at))
			break
		end
		local spec = specs[name :: string]
		if spec == nil then
			error(
				`docs/benchmarks.md marks a table named {name}, which the bench data doesn't have`
			)
		end
		local closing = `<!-- bench:table {name} end -->`
		local stop = string.find(markdown, closing, (startEnd :: number) + 1, true)
		if stop == nil then
			error(`the {name} table in docs/benchmarks.md isn't closed with {closing}`)
		end
		local region = string.sub(markdown, (startEnd :: number) + 1, (stop :: number) - 1)
		table.insert(out, string.sub(markdown, at, startEnd :: number))
		-- Prettier keeps a blank line between a comment and a table
		table.insert(out, "\n")
		table.insert(out, render(catalog, latest, spec, existingNotes(region)))
		table.insert(out, "\n\n")
		at = stop :: number
	end
	return table.concat(out)
end

return BenchDocs
