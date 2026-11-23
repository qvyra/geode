--!strict

-- The leaderstats option of Geode.players: a value per stat in each player's leaderstats folder,
-- kept in step with the profile through observe and taken away when the profile is released.
-- Only the server makes them

local Path = require("../Matrix/Path")
local Signal = require("../Quartz/Signal")
local Tree = require("../Matrix/Tree")
local Types = require("../Quartz/Types")

export type Stat = {
	path: Path.PathLike,
	name: string,
	-- lowest first. Stats without one come after those with one, in the order listed
	order: number?,
	-- the text to show for a value. A stat with a format is a StringValue
	format: ((value: unknown) -> string)?,
}

export type Parsed = {
	path: Path.Path,
	name: string,
	kind: Types.LeaderstatKind,
	format: ((value: unknown) -> string)?,
	order: number,
	index: number,
	-- a value that can't be shown is reported once per stat, not once per player
	reported: boolean,
}

local Leaderstats = {}

-- Checks the option against the template and puts the stats in order. A mistake fails when the
-- game starts, not when the first player joins
function Leaderstats.parse(stats: { Stat }, template: unknown): { Parsed }
	assert(type(stats) == "table", "leaderstats must be a list of stats")
	local parsed: { Parsed } = {}
	local names: { [string]: boolean } = {}
	for index, stat in stats do
		assert(type(stat) == "table", "each leaderstat must be a table")
		local name = stat.name
		assert(type(name) == "string" and name ~= "", "every leaderstat needs a name")
		assert(not names[name], `two leaderstats are named {name}`)
		names[name] = true
		assert(
			stat.order == nil or type(stat.order) == "number",
			`leaderstat {name}: order must be a number`
		)
		assert(
			stat.format == nil or type(stat.format) == "function",
			`leaderstat {name}: format must be a function`
		)
		local path = Path.parse(stat.path)
		assert(#path > 0, `leaderstat {name} needs a path`)
		local kind: Types.LeaderstatKind = "StringValue"
		if stat.format == nil then
			local default = Tree.get(template, path)
			if type(default) == "number" then
				kind = if default % 1 == 0 then "IntValue" else "NumberValue"
			elseif type(default) ~= "string" then
				error(
					`leaderstat {name}: the template holds a {typeof(default)} at {Path.format(path)}. `
						.. "Numbers and strings show as they are, anything else needs a format",
					0
				)
			end
		end
		table.insert(parsed, {
			path = path,
			name = name,
			kind = kind,
			format = stat.format,
			order = stat.order or math.huge,
			index = index,
			reported = false,
		})
	end
	table.sort(parsed, function(a: Parsed, b: Parsed): boolean
		if a.order ~= b.order then
			return a.order < b.order
		end
		return a.index < b.index
	end)
	return parsed
end

local function finite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

-- What the stat's value shows for `value`. Anything it can't show turns into 0 or "", reported
local function shown(stat: Parsed, value: unknown, report: (message: string) -> ()): number | string
	local function problem(message: string)
		if not stat.reported then
			stat.reported = true
			report(`leaderstat {stat.name}: {message}`)
		end
	end
	local format = stat.format
	if format then
		local ok, text = pcall(format, value)
		if ok and type(text) == "string" then
			return text
		end
		problem(
			if ok then `format returned a {typeof(text)}, not a string` else `format failed: {text}`
		)
		return ""
	end
	if stat.kind == "StringValue" then
		if type(value) == "string" then
			return value
		end
		if value ~= nil then
			problem(
				`{Path.format(stat.path)} holds a {typeof(value)}, which a StringValue can't show`
			)
		end
		return ""
	end
	if type(value) ~= "number" or not finite(value) then
		if value ~= nil then
			problem(
				`{Path.format(stat.path)} holds {tostring(value)}, which a number stat can't show`
			)
		end
		return 0
	end
	if stat.kind == "IntValue" and value % 1 ~= 0 then
		problem(
			"its template value is a whole number, so it's an IntValue and shows values rounded down. "
				.. "Give it a format to show fractions"
		)
		return math.floor(value)
	end
	return value
end

-- Gives every player whose profile loads a leaderstats value per stat, and takes them away when
-- the profile is released, its session is lost or the player left. `loaded` and `released` are
-- PlayerData's signals, which fire with the player and the profile
function Leaderstats.attach(
	loaded: Signal.Signal,
	released: Signal.Signal,
	adapter: Types.Leaderstats,
	stats: { Parsed },
	report: (message: string) -> ()
)
	local specs: { Types.LeaderstatSpec } = {}
	for _, stat in stats do
		table.insert(specs, { name = stat.name, kind = stat.kind })
	end
	local open: { [unknown]: { values: Types.LeaderstatValues, connections: { Types.Connection } } } =
		{}
	-- a name the game's own folder already uses is reported once, not once per player
	local clashReported: { [string]: boolean } = {}

	loaded:connect(function(player: any, profile: any)
		-- a profile that's already on its way out gets none
		if open[profile] or profile:state() ~= "active" then
			return
		end
		local values = adapter:attach(player, specs)
		local left: { [string]: boolean } = {}
		local skipped: { Types.LeaderstatSkip } = values.skipped or {}
		for _, skip in skipped do
			left[skip.name] = true
			if not clashReported[skip.name] then
				clashReported[skip.name] = true
				report(
					`leaderstat {skip.name} isn't shown: the leaderstats folder already holds a {skip.found} named {skip.name}, and this stat needs a {skip.kind}. The game's value is left alone`
				)
			end
		end
		local connections: { Types.Connection } = {}
		for _, stat in stats do
			if left[stat.name] then
				continue
			end
			values:set(stat.name, shown(stat, profile:get(stat.path), report))
			table.insert(
				connections,
				profile:observe(stat.path, function(newValue: unknown)
					values:set(stat.name, shown(stat, newValue, report))
				end)
			)
		end
		open[profile] = { values = values, connections = connections }
	end)

	released:connect(function(_player: any, profile: any)
		local entry = open[profile]
		if entry == nil then
			return
		end
		open[profile] = nil
		for _, connection in entry.connections do
			connection:disconnect()
		end
		entry.values:destroy()
	end)
end

return Leaderstats
