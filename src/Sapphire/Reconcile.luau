--!strict

-- Brings loaded data up to the current template by adding what's missing. Existing values
-- never change and keys the template doesn't know are kept, since only a migration may
-- drop data

local Reconcile = {}

local function copy(value: unknown): unknown
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value :: { [unknown]: unknown } do
		result[key] = copy(child)
	end
	return result
end

-- Lists are left alone: merging template items into a player's list would invent entries
local function isList(value: { [unknown]: unknown }): boolean
	return #value > 0
end

local function fill(data: unknown, template: unknown): unknown
	if data == nil then
		return copy(template)
	end
	if type(data) ~= "table" or type(template) ~= "table" then
		return data
	end
	local source = data :: { [unknown]: unknown }
	local defaults = template :: { [unknown]: unknown }
	if isList(source) or isList(defaults) then
		return copy(source)
	end
	local result = copy(source) :: { [unknown]: unknown }
	for key, default in defaults do
		result[key] = fill(source[key], default)
	end
	return result
end

function Reconcile.fill(data: unknown, template: unknown): unknown
	return fill(data, template)
end

return Reconcile
