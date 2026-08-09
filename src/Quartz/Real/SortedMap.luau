--!strict

local Errors = require("../Errors")
local RobloxApi = require("./RobloxApi")
local Types = require("../Types")

type Fields = {
	name: string,
	_map: MemoryStoreSortedMap,
	_api: RobloxApi.RobloxApi,
}

local RealSortedMap = {}
RealSortedMap.__index = RealSortedMap

export type RealSortedMap = typeof(setmetatable({} :: Fields, RealSortedMap))

function RealSortedMap.new(
	map: MemoryStoreSortedMap,
	name: string,
	api: RobloxApi.RobloxApi
): RealSortedMap
	return setmetatable({ name = name, _map = map, _api = api } :: Fields, RealSortedMap)
end

function RealSortedMap.get(self: RealSortedMap, key: string): Types.Result<Types.SortedEntry?>
	local ok, value, sortKey = pcall(function(): (unknown, Types.SortKey?)
		local found, foundSortKey = self._map:GetAsync(key)
		return found, foundSortKey :: Types.SortKey?
	end)
	if not ok then
		return Errors.failWith(Errors.classify(value, "memoryStore"))
	end
	if value == nil then
		return Errors.ok(nil)
	end
	return Errors.ok({ key = key, value = value, sortKey = sortKey })
end

function RealSortedMap.set(
	self: RealSortedMap,
	key: string,
	value: unknown,
	ttl: number,
	sortKey: Types.SortKey?
): Types.Result<nil>
	local ok, err = pcall(function()
		self._map:SetAsync(key, value, ttl, sortKey)
	end)
	if not ok then
		return Errors.failWith(Errors.classify(err, "memoryStore"))
	end
	return Errors.ok(nil)
end

function RealSortedMap.update(
	self: RealSortedMap,
	key: string,
	transform: Types.SortedTransform,
	ttl: number
): Types.Result<Types.SortedUpdate>
	local cancelled = false
	local lastSeen: unknown = nil
	local lastSortKey: Types.SortKey? = nil
	local ok, value, sortKey = pcall(function(): (unknown, Types.SortKey?)
		local updated, updatedSortKey = self._map:UpdateAsync(
			key,
			function(current: unknown, currentSortKey: Types.SortKey?)
				lastSeen = current
				lastSortKey = currentSortKey
				local nextValue, nextSortKey = transform(current, currentSortKey)
				cancelled = nextValue == nil
				return nextValue, nextSortKey
			end,
			ttl
		)
		return updated, updatedSortKey :: Types.SortKey?
	end)
	if not ok then
		return Errors.failWith(Errors.classify(value, "memoryStore"))
	end
	if cancelled then
		return Errors.ok({ value = lastSeen, sortKey = lastSortKey, cancelled = true })
	end
	return Errors.ok({ value = value, sortKey = sortKey, cancelled = false })
end

function RealSortedMap.remove(self: RealSortedMap, key: string): Types.Result<nil>
	local ok, err = pcall(function()
		self._map:RemoveAsync(key)
	end)
	if not ok then
		return Errors.failWith(Errors.classify(err, "memoryStore"))
	end
	return Errors.ok(nil)
end

function RealSortedMap.getRange(
	self: RealSortedMap,
	range: Types.SortedRange
): Types.Result<{ Types.SortedEntry }>
	local direction = if range.descending then self._api.sortDescending else self._api.sortAscending
	local ok, itemsOrError = pcall(function()
		return self._map:GetRangeAsync(direction, range.count, range.lower, range.upper)
	end)
	if not ok then
		return Errors.failWith(Errors.classify(itemsOrError, "memoryStore"))
	end

	local entries: { Types.SortedEntry } = {}
	for _, item in itemsOrError :: { unknown } do
		local entry = item :: { key: string, value: unknown, sortKey: Types.SortKey? }
		table.insert(entries, { key = entry.key, value = entry.value, sortKey = entry.sortKey })
	end
	return Errors.ok(entries)
end

return RealSortedMap
