--!strict

-- Leaderstats on a mock server: one folder per player, values in the order they were added.
-- Values are checked against their kind, so a test notices a string set on an IntValue

local Types = require("../Types")

export type MockValue = {
	name: string,
	kind: Types.LeaderstatKind,
	value: number | string,
}

type Folder = { values: { MockValue } }

type Fields = {
	_folders: { [unknown]: Folder },
}

local MockLeaderstats = {}
MockLeaderstats.__index = MockLeaderstats

export type MockLeaderstats = typeof(setmetatable({} :: Fields, MockLeaderstats))

local DEFAULTS: { [string]: number | string } = {
	IntValue = 0,
	NumberValue = 0,
	StringValue = "",
}

local function fits(kind: Types.LeaderstatKind, value: unknown): boolean
	if kind == "StringValue" then
		return type(value) == "string"
	elseif kind == "IntValue" then
		return type(value) == "number" and value % 1 == 0
	end
	return type(value) == "number"
end

function MockLeaderstats.new(): MockLeaderstats
	return setmetatable({ _folders = {} } :: Fields, MockLeaderstats)
end

function MockLeaderstats.attach(
	self: MockLeaderstats,
	player: unknown,
	stats: { Types.LeaderstatSpec }
): Types.LeaderstatValues
	local folder = self._folders[player]
	local made = folder == nil
	if folder == nil then
		folder = { values = {} }
		self._folders[player] = folder
	end
	local held = folder :: Folder
	-- every value this attach writes to, and the ones it made, which are all it removes
	local writes: { MockValue } = {}
	local mine: { MockValue } = {}
	local skipped: { Types.LeaderstatSkip } = {}
	local adopted: { string } = {}
	for _, stat in stats do
		local existing: MockValue? = nil
		for _, entry in held.values do
			if entry.name == stat.name then
				existing = entry
				break
			end
		end
		if existing and existing.kind == stat.kind then
			table.insert(writes, existing)
			table.insert(adopted, stat.name)
		elseif existing then
			local found: string = existing.kind
			table.insert(skipped, { name = stat.name, kind = stat.kind, found = found })
		else
			local value: MockValue =
				{ name = stat.name, kind = stat.kind, value = DEFAULTS[stat.kind] }
			table.insert(held.values, value)
			table.insert(writes, value)
			table.insert(mine, value)
		end
	end
	return {
		skipped = skipped,
		adopted = adopted,
		set = function(_values: Types.LeaderstatValues, name: string, value: number | string)
			for _, entry in writes do
				if entry.name == name then
					assert(
						fits(entry.kind, value),
						`{name} is a {entry.kind} and can't hold {value}`
					)
					entry.value = value
				end
			end
		end,
		destroy = function(_values: Types.LeaderstatValues)
			for _, entry in mine do
				local index = table.find(held.values, entry)
				if index then
					table.remove(held.values, index)
				end
			end
			if made and #held.values == 0 and self._folders[player] == held then
				self._folders[player] = nil
			end
			table.clear(mine)
			table.clear(writes)
		end,
	}
end

-- What the player's leaderstats folder holds, in order. nil when they have no folder
function MockLeaderstats.read(self: MockLeaderstats, player: unknown): { MockValue }?
	local folder = self._folders[player]
	if folder == nil then
		return nil
	end
	local copy = {}
	for _, entry in folder.values do
		table.insert(copy, table.clone(entry))
	end
	return copy
end

-- How many players have a leaderstats folder, so a test can tell none were left behind
function MockLeaderstats.count(self: MockLeaderstats): number
	local count = 0
	for _ in self._folders do
		count += 1
	end
	return count
end

return MockLeaderstats
