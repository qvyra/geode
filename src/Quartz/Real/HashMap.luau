--!strict

local Errors = require("../Errors")
local Types = require("../Types")

type Fields = {
	name: string,
	_map: MemoryStoreHashMap,
}

local RealHashMap = {}
RealHashMap.__index = RealHashMap

export type RealHashMap = typeof(setmetatable({} :: Fields, RealHashMap))

-- unverified: largest page size ListItemsAsync accepts
local LIST_PAGE_SIZE = 100

function RealHashMap.new(map: MemoryStoreHashMap, name: string): RealHashMap
	return setmetatable({ name = name, _map = map } :: Fields, RealHashMap)
end

function RealHashMap.get(self: RealHashMap, key: string): Types.Result<unknown>
	local ok, value = pcall(function(): unknown
		return self._map:GetAsync(key)
	end)
	if not ok then
		return Errors.failWith(Errors.classify(value))
	end
	return Errors.ok(value)
end

function RealHashMap.set(
	self: RealHashMap,
	key: string,
	value: unknown,
	ttl: number
): Types.Result<nil>
	local ok, err = pcall(function()
		self._map:SetAsync(key, value, ttl)
	end)
	if not ok then
		return Errors.failWith(Errors.classify(err))
	end
	return Errors.ok(nil)
end

function RealHashMap.update(
	self: RealHashMap,
	key: string,
	transform: (current: unknown) -> unknown,
	ttl: number
): Types.Result<Types.MemoryUpdate>
	local cancelled = false
	local lastSeen: unknown = nil
	local ok, value = pcall(function(): unknown
		return self._map:UpdateAsync(key, function(current: unknown)
			lastSeen = current
			local nextValue = transform(current)
			cancelled = nextValue == nil
			return nextValue
		end, ttl)
	end)
	if not ok then
		return Errors.failWith(Errors.classify(value))
	end
	if cancelled then
		return Errors.ok({ value = lastSeen, cancelled = true })
	end
	return Errors.ok({ value = value, cancelled = false })
end

function RealHashMap.remove(self: RealHashMap, key: string): Types.Result<nil>
	local ok, err = pcall(function()
		self._map:RemoveAsync(key)
	end)
	if not ok then
		return Errors.failWith(Errors.classify(err))
	end
	return Errors.ok(nil)
end

function RealHashMap.list(self: RealHashMap, limit: number?): Types.Result<{ Types.HashMapEntry }>
	local wanted = limit or LIST_PAGE_SIZE
	local ok, pagesOrError = pcall(function()
		return self._map:ListItemsAsync(math.min(wanted, LIST_PAGE_SIZE))
	end)
	if not ok then
		return Errors.failWith(Errors.classify(pagesOrError))
	end
	local pages = pagesOrError :: MemoryStoreHashMapPages

	local entries: { Types.HashMapEntry } = {}
	while true do
		for _, item in pages:GetCurrentPage() do
			local entry = item :: { key: string, value: unknown }
			table.insert(entries, { key = entry.key, value = entry.value })
			if #entries >= wanted then
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

return RealHashMap
