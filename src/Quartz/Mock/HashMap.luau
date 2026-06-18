--!strict

local Context = require("./Context")
local Errors = require("../Errors")
local Types = require("../Types")
local Values = require("./Values")

type Context = Context.Context
type MemoryItem = Context.MemoryItem

type Fields = {
	name: string,
	_context: Context,
	_items: { [string]: MemoryItem },
}

local MockHashMap = {}
MockHashMap.__index = MockHashMap

export type MockHashMap = typeof(setmetatable({} :: Fields, MockHashMap))

local SERVICE = "hashMap"

function MockHashMap.new(context: Context, name: string): MockHashMap
	local maps = context.shared.hashMaps
	maps[name] = maps[name] or {}
	local self: Fields = {
		name = name,
		_context = context,
		_items = maps[name],
	}
	return setmetatable(self, MockHashMap)
end

-- Expired items are dropped on read, so a lookup never sees one
function MockHashMap._live(self: MockHashMap, key: string): MemoryItem?
	local item = self._items[key]
	if item and item.expiresAt <= self._context.shared.clock:now() then
		self._items[key] = nil
		return nil
	end
	return item
end

function MockHashMap._store(
	self: MockHashMap,
	key: string,
	value: unknown,
	ttl: number
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
		sortKey = nil,
		expiresAt = self._context.shared.clock:now() + ttl,
	}
	return nil
end

function MockHashMap.get(self: MockHashMap, key: string): Types.Result<unknown>
	local err = Context.enter(self._context, SERVICE, self.name, "get", key)
	if err then
		return Errors.failWith(err)
	end
	local item = self:_live(key)
	return Errors.ok(if item then Values.clone(item.value) else nil)
end

function MockHashMap.set(
	self: MockHashMap,
	key: string,
	value: unknown,
	ttl: number
): Types.Result<nil>
	local err = Context.enter(self._context, SERVICE, self.name, "set", key)
	if err then
		return Errors.failWith(err)
	end
	local storeError = self:_store(key, value, ttl)
	if storeError then
		return Errors.failWith(storeError)
	end
	return Errors.ok(nil)
end

function MockHashMap.update(
	self: MockHashMap,
	key: string,
	transform: (current: unknown) -> unknown,
	ttl: number
): Types.Result<Types.MemoryUpdate>
	local err = Context.enter(self._context, SERVICE, self.name, "update", key)
	if err then
		return Errors.failWith(err)
	end
	local item = self:_live(key)
	local current = if item then Values.clone(item.value) else nil
	local nextValue = transform(current)
	if nextValue == nil then
		return Errors.ok({ value = current, cancelled = true })
	end
	local storeError = self:_store(key, nextValue, ttl)
	if storeError then
		return Errors.failWith(storeError)
	end
	return Errors.ok({ value = Values.clone(nextValue), cancelled = false })
end

function MockHashMap.remove(self: MockHashMap, key: string): Types.Result<nil>
	local err = Context.enter(self._context, SERVICE, self.name, "remove", key)
	if err then
		return Errors.failWith(err)
	end
	self._items[key] = nil
	return Errors.ok(nil)
end

function MockHashMap.list(self: MockHashMap, limit: number?): Types.Result<{ Types.HashMapEntry }>
	local err = Context.enter(self._context, SERVICE, self.name, "list", nil)
	if err then
		return Errors.failWith(err)
	end
	local keys = {}
	for key in self._items do
		if self:_live(key) then
			table.insert(keys, key)
		end
	end
	table.sort(keys)

	local entries: { Types.HashMapEntry } = {}
	for index = 1, math.min(limit or 100, #keys) do
		local key = keys[index]
		entries[index] = { key = key, value = Values.clone(self._items[key].value) }
	end
	return Errors.ok(entries)
end

return MockHashMap
