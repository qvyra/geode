--!strict

local Context = require("./Context")
local Errors = require("../Errors")
local Types = require("../Types")
local Values = require("./Values")

type Context = Context.Context
type MemoryItem = Context.MemoryItem
type SortKey = Types.SortKey

type Fields = {
	name: string,
	_context: Context,
	_items: { [string]: MemoryItem },
}

local MockSortedMap = {}
MockSortedMap.__index = MockSortedMap

export type MockSortedMap = typeof(setmetatable({} :: Fields, MockSortedMap))

local SERVICE = "sortedMap"

function MockSortedMap.new(context: Context, name: string): MockSortedMap
	local maps = context.shared.sortedMaps
	maps[name] = maps[name] or {}
	local self: Fields = {
		name = name,
		_context = context,
		_items = maps[name],
	}
	return setmetatable(self, MockSortedMap)
end

local MAX_RANGE_COUNT = 200

--// ordering

-- Numbers first, then strings, then no sort key at all. Ties go by key, alphabetically
local function rank(sortKey: SortKey?): number
	if type(sortKey) == "number" then
		return 0
	elseif sortKey ~= nil then
		return 1
	end
	return 2
end

local function compareSortKeys(a: SortKey?, b: SortKey?): number
	local rankA, rankB = rank(a), rank(b)
	if rankA ~= rankB then
		return if rankA < rankB then -1 else 1
	end
	if a == nil or b == nil or a == b then
		return 0
	end
	return if (a :: any) < (b :: any) then -1 else 1 -- same rank, so both are numbers or both strings
end

local function compareEntries(a: Types.SortedEntry, b: Types.SortedEntry): number
	local bySortKey = compareSortKeys(a.sortKey, b.sortKey)
	if bySortKey ~= 0 then
		return bySortKey
	end
	if a.key == b.key then
		return 0
	end
	return if a.key < b.key then -1 else 1
end

-- Unverified what a bound with only a key or only a sort key compares against. The missing
-- field just isn't compared here
local function compareToBound(entry: Types.SortedEntry, bound: Types.SortedBound): number
	if bound.sortKey ~= nil then
		local bySortKey = compareSortKeys(entry.sortKey, bound.sortKey)
		if bySortKey ~= 0 or bound.key == nil then
			return bySortKey
		end
	end
	if bound.key == nil or entry.key == bound.key then
		return 0
	end
	return if entry.key < bound.key then -1 else 1
end

--// adapter

function MockSortedMap._live(self: MockSortedMap, key: string): MemoryItem?
	local item = self._items[key]
	if item and item.expiresAt <= self._context.shared.clock:now() then
		self._items[key] = nil
		return nil
	end
	return item
end

function MockSortedMap._store(
	self: MockSortedMap,
	key: string,
	value: unknown,
	ttl: number,
	sortKey: SortKey?
): Types.AdapterError?
	if ttl <= 0 then
		return { kind = "invalidValue", message = "ttl must be positive" }
	end
	local ok, copy = Values.copy(value)
	if not ok then
		return { kind = "invalidValue", message = tostring(copy) }
	end
	local sizeError = Context.checkSize(self._context.shared, copy)
	if sizeError then
		return sizeError
	end
	self._items[key] = {
		value = copy,
		sortKey = sortKey,
		expiresAt = self._context.shared.clock:now() + ttl,
	}
	return nil
end

function MockSortedMap.get(self: MockSortedMap, key: string): Types.Result<Types.SortedEntry?>
	local err = Context.enter(self._context, SERVICE, self.name, "get", key)
	if err then
		return Errors.failWith(err)
	end
	local item = self:_live(key)
	if item == nil then
		return Errors.ok(nil)
	end
	return Errors.ok({ key = key, value = Values.clone(item.value), sortKey = item.sortKey })
end

function MockSortedMap.set(
	self: MockSortedMap,
	key: string,
	value: unknown,
	ttl: number,
	sortKey: SortKey?
): Types.Result<nil>
	local err = Context.enter(self._context, SERVICE, self.name, "set", key)
	if err then
		return Errors.failWith(err)
	end
	local storeError = self:_store(key, value, ttl, sortKey)
	if storeError then
		return Errors.failWith(storeError)
	end
	return Errors.ok(nil)
end

function MockSortedMap.update(
	self: MockSortedMap,
	key: string,
	transform: Types.SortedTransform,
	ttl: number
): Types.Result<Types.SortedUpdate>
	local err = Context.enter(self._context, SERVICE, self.name, "update", key)
	if err then
		return Errors.failWith(err)
	end
	local item = self:_live(key)
	local current = if item then Values.clone(item.value) else nil
	local currentSortKey = if item then item.sortKey else nil
	local nextValue, nextSortKey = transform(current, currentSortKey)
	if nextValue == nil then
		return Errors.ok({ value = current, sortKey = currentSortKey, cancelled = true })
	end
	local storeError = self:_store(key, nextValue, ttl, nextSortKey)
	if storeError then
		return Errors.failWith(storeError)
	end
	return Errors.ok({ value = Values.clone(nextValue), sortKey = nextSortKey, cancelled = false })
end

function MockSortedMap.remove(self: MockSortedMap, key: string): Types.Result<nil>
	local err = Context.enter(self._context, SERVICE, self.name, "remove", key)
	if err then
		return Errors.failWith(err)
	end
	self._items[key] = nil
	return Errors.ok(nil)
end

function MockSortedMap.getRange(
	self: MockSortedMap,
	range: Types.SortedRange
): Types.Result<{ Types.SortedEntry }>
	local err = Context.enter(self._context, SERVICE, self.name, "getRange", nil)
	if err then
		return Errors.failWith(err)
	end
	if range.count < 1 or range.count > MAX_RANGE_COUNT or range.count % 1 ~= 0 then
		return Errors.fail(
			"invalidValue",
			`count must be a whole number from 1 to {MAX_RANGE_COUNT}`
		)
	end

	local entries: { Types.SortedEntry } = {}
	for key in self._items do
		local item = self:_live(key)
		if item == nil then
			continue
		end
		local entry = { key = key, value = item.value, sortKey = item.sortKey }
		if range.lower and compareToBound(entry, range.lower) <= 0 then
			continue
		end
		if range.upper and compareToBound(entry, range.upper) >= 0 then
			continue
		end
		table.insert(entries, entry)
	end

	local descending = range.descending == true
	table.sort(entries, function(a, b)
		local order = compareEntries(a, b)
		return if descending then order > 0 else order < 0
	end)

	local page: { Types.SortedEntry } = {}
	for index = 1, math.min(range.count, #entries) do
		local entry = entries[index]
		page[index] =
			{ key = entry.key, value = Values.clone(entry.value), sortKey = entry.sortKey }
	end
	return Errors.ok(page)
end

return MockSortedMap
