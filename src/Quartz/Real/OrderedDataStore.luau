--!strict

local Errors = require("../Errors")
local Types = require("../Types")

type Fields = {
	name: string,
	scope: string,
	_store: OrderedDataStore,
}

local RealOrderedDataStore = {}
RealOrderedDataStore.__index = RealOrderedDataStore

export type RealOrderedDataStore = typeof(setmetatable({} :: Fields, RealOrderedDataStore))

-- unverified: largest page size GetSortedAsync accepts
local SORTED_PAGE_SIZE = 100

function RealOrderedDataStore.new(
	store: OrderedDataStore,
	name: string,
	scope: string
): RealOrderedDataStore
	local self: Fields = { name = name, scope = scope, _store = store }
	return setmetatable(self, RealOrderedDataStore)
end

function RealOrderedDataStore.get(self: RealOrderedDataStore, key: string): Types.Result<number?>
	local ok, value = pcall(function(): number?
		local result = self._store:GetAsync(key)
		return result :: number?
	end)
	if not ok then
		return Errors.failWith(Errors.classify(value))
	end
	return Errors.ok(value)
end

function RealOrderedDataStore.set(
	self: RealOrderedDataStore,
	key: string,
	value: number
): Types.Result<nil>
	local ok, err = pcall(function()
		self._store:SetAsync(key, value)
	end)
	if not ok then
		return Errors.failWith(Errors.classify(err))
	end
	return Errors.ok(nil)
end

function RealOrderedDataStore.update(
	self: RealOrderedDataStore,
	key: string,
	transform: (current: number?) -> number?
): Types.Result<Types.OrderedUpdate>
	local cancelled = false
	local lastSeen: number? = nil
	local ok, value = pcall(function(): number?
		local result = self._store:UpdateAsync(key, function(current: number?)
			lastSeen = current
			local nextValue = transform(current)
			cancelled = nextValue == nil
			-- nil cancels the update, Roblox's type defs don't model that
			return nextValue :: any
		end)
		return result :: number?
	end)
	if not ok then
		return Errors.failWith(Errors.classify(value))
	end
	if cancelled then
		return Errors.ok({ value = lastSeen, cancelled = true })
	end
	return Errors.ok({ value = value, cancelled = false })
end

function RealOrderedDataStore.remove(self: RealOrderedDataStore, key: string): Types.Result<number?>
	local ok, value = pcall(function(): number?
		local result = self._store:RemoveAsync(key)
		return result :: number?
	end)
	if not ok then
		return Errors.failWith(Errors.classify(value))
	end
	return Errors.ok(value)
end

function RealOrderedDataStore.increment(
	self: RealOrderedDataStore,
	key: string,
	delta: number
): Types.Result<number>
	local ok, value = pcall(function(): number
		local result = self._store:IncrementAsync(key, delta)
		return result :: number
	end)
	if not ok then
		return Errors.failWith(Errors.classify(value))
	end
	return Errors.ok(value)
end

function RealOrderedDataStore.getSorted(
	self: RealOrderedDataStore,
	query: Types.OrderedQuery?
): Types.Result<{ Types.OrderedEntry }>
	local ascending = query == nil or query.ascending ~= false
	local limit = query and query.limit or SORTED_PAGE_SIZE
	local min = query and query.min
	local max = query and query.max

	local ok, pagesOrError = pcall(function()
		return self._store:GetSortedAsync(ascending, math.min(limit, SORTED_PAGE_SIZE), min, max)
	end)
	if not ok then
		return Errors.failWith(Errors.classify(pagesOrError))
	end
	local pages = pagesOrError :: DataStorePages

	local entries: { Types.OrderedEntry } = {}
	while true do
		for _, item in pages:GetCurrentPage() do
			local entry = item :: { key: string, value: number }
			table.insert(entries, { key = entry.key, value = entry.value })
			if #entries >= limit then
				return Errors.ok(entries)
			end
		end
		if pages.IsFinished then
			return Errors.ok(entries)
		end
		local advanced, advanceError = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)
		if not advanced then
			return Errors.failWith(Errors.classify(advanceError))
		end
	end
end

return RealOrderedDataStore
