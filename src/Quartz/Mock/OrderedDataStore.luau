--!strict

local Context = require("./Context")
local Errors = require("../Errors")
local Types = require("../Types")

type Context = Context.Context

type Fields = {
	name: string,
	scope: string,
	_context: Context,
	_values: { [string]: number },
}

local MockOrderedDataStore = {}
MockOrderedDataStore.__index = MockOrderedDataStore

export type MockOrderedDataStore = typeof(setmetatable({} :: Fields, MockOrderedDataStore))

local SERVICE = "orderedDataStore"

function MockOrderedDataStore.new(
	context: Context,
	name: string,
	scope: string
): MockOrderedDataStore
	local id = `{name}\0{scope}`
	local stores = context.shared.orderedDataStores
	stores[id] = stores[id] or {}
	local self: Fields = {
		name = name,
		scope = scope,
		_context = context,
		_values = stores[id],
	}
	return setmetatable(self, MockOrderedDataStore)
end

local function isInteger(value: unknown): boolean
	return type(value) == "number" and value % 1 == 0
end

function MockOrderedDataStore._enter(self: MockOrderedDataStore, method: string, key: string?)
	local err = Context.enter(self._context, SERVICE, self.name, method, key)
	if err == nil then
		err = Context.checkStoreName(self._context.shared, self.name, self.scope)
	end
	if err == nil and key then
		err = Context.checkKey(self._context.shared, key)
	end
	return err
end

function MockOrderedDataStore.get(self: MockOrderedDataStore, key: string): Types.Result<number?>
	local err = self:_enter("get", key)
	if err then
		return Errors.failWith(err)
	end
	return Errors.ok(self._values[key])
end

function MockOrderedDataStore.set(
	self: MockOrderedDataStore,
	key: string,
	value: number
): Types.Result<nil>
	local err = self:_enter("set", key)
	if err then
		return Errors.failWith(err)
	end
	if not isInteger(value) then
		return Errors.failWith(Errors.classify(`106: Ordered values must be integers, got {value}`))
	end
	self._values[key] = value
	return Errors.ok(nil)
end

function MockOrderedDataStore.update(
	self: MockOrderedDataStore,
	key: string,
	transform: (current: number?) -> number?
): Types.Result<Types.OrderedUpdate>
	local err = self:_enter("update", key)
	if err then
		return Errors.failWith(err)
	end
	local current = self._values[key]
	local nextValue = transform(current)
	if nextValue == nil then
		return Errors.ok({ value = current, cancelled = true })
	end
	if not isInteger(nextValue) then
		return Errors.failWith(
			Errors.classify(`106: Ordered values must be integers, got {nextValue}`)
		)
	end
	self._values[key] = nextValue
	return Errors.ok({ value = nextValue, cancelled = false })
end

function MockOrderedDataStore.remove(self: MockOrderedDataStore, key: string): Types.Result<number?>
	local err = self:_enter("remove", key)
	if err then
		return Errors.failWith(err)
	end
	local previous = self._values[key]
	self._values[key] = nil
	return Errors.ok(previous)
end

function MockOrderedDataStore.increment(
	self: MockOrderedDataStore,
	key: string,
	delta: number
): Types.Result<number>
	local err = self:_enter("increment", key)
	if err then
		return Errors.failWith(err)
	end
	if not isInteger(delta) then
		return Errors.fail("invalidValue", "increment delta must be an integer")
	end
	local nextValue = (self._values[key] or 0) + delta
	self._values[key] = nextValue
	return Errors.ok(nextValue)
end

function MockOrderedDataStore.getSorted(
	self: MockOrderedDataStore,
	query: Types.OrderedQuery?
): Types.Result<{ Types.OrderedEntry }>
	local err = self:_enter("getSorted", nil)
	if err then
		return Errors.failWith(err)
	end
	local ascending = query == nil or query.ascending ~= false
	local limit = query and query.limit or 100
	local min = query and query.min
	local max = query and query.max

	local entries: { Types.OrderedEntry } = {}
	for key, value in self._values do
		if (min == nil or value >= min) and (max == nil or value <= max) then
			table.insert(entries, { key = key, value = value })
		end
	end
	-- tie break on key so results stay stable between runs
	table.sort(entries, function(a, b)
		if a.value ~= b.value then
			return if ascending then a.value < b.value else a.value > b.value
		end
		return a.key < b.key
	end)

	local page: { Types.OrderedEntry } = {}
	for index = 1, math.min(limit, #entries) do
		page[index] = entries[index]
	end
	return Errors.ok(page)
end

return MockOrderedDataStore
