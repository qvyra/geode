--!strict

local Errors = require("../Errors")
local RobloxApi = require("./RobloxApi")
local Types = require("../Types")

type Fields = {
	name: string,
	scope: string,
	_store: DataStore,
	_api: RobloxApi.RobloxApi,
}

local RealDataStore = {}
RealDataStore.__index = RealDataStore

export type RealDataStore = typeof(setmetatable({} :: Fields, RealDataStore))

-- unverified: largest page size ListVersionsAsync accepts
local VERSION_PAGE_SIZE = 100

function RealDataStore.new(
	store: DataStore,
	name: string,
	scope: string,
	api: RobloxApi.RobloxApi
): RealDataStore
	local self: Fields = { name = name, scope = scope, _store = store, _api = api }
	return setmetatable(self, RealDataStore)
end

local function toInfo(info: DataStoreKeyInfo?): Types.KeyInfo?
	if info == nil then
		return nil
	end
	return {
		version = info.Version,
		createdTime = info.CreatedTime,
		updatedTime = info.UpdatedTime,
		userIds = info:GetUserIds(),
		metadata = info:GetMetadata(),
	}
end

function RealDataStore._setOptions(
	self: RealDataStore,
	options: Types.WriteOptions?
): ({ number }?, DataStoreSetOptions?)
	if options == nil then
		return nil, nil
	end
	local setOptions = if options.metadata then self._api.newSetOptions(options.metadata) else nil
	return options.userIds, setOptions
end

function RealDataStore.get(self: RealDataStore, key: string): Types.Result<Types.Read>
	local ok, value, info = pcall(function()
		return self._store:GetAsync(key)
	end)
	if not ok then
		return Errors.failWith(Errors.classify(value))
	end
	return Errors.ok({ value = value, info = toInfo(info) })
end

function RealDataStore.set(
	self: RealDataStore,
	key: string,
	value: unknown,
	options: Types.WriteOptions?
): Types.Result<string>
	local userIds, setOptions = self:_setOptions(options)
	local ok, version = pcall(function()
		return self._store:SetAsync(key, value, userIds, setOptions)
	end)
	if not ok then
		return Errors.failWith(Errors.classify(version))
	end
	return Errors.ok(version :: string)
end

function RealDataStore.update(
	self: RealDataStore,
	key: string,
	transform: Types.Transform
): Types.Result<Types.Update>
	-- UpdateAsync may run the transform several times. Only the last run decides the outcome
	local cancelled = false
	local lastSeen: unknown = nil
	local lastInfo: Types.KeyInfo? = nil

	local ok, value, info = pcall(function()
		return self._store:UpdateAsync(key, function(current: unknown, keyInfo: DataStoreKeyInfo?)
			lastSeen = current
			lastInfo = toInfo(keyInfo)
			local nextValue, options = transform(current, lastInfo)
			cancelled = nextValue == nil
			if cancelled then
				return nil
			end
			local userIds = options and options.userIds
			local metadata = options and options.metadata
			return nextValue, userIds, metadata
		end)
	end)
	if not ok then
		return Errors.failWith(Errors.classify(value))
	end
	if cancelled then
		return Errors.ok({ value = lastSeen, info = lastInfo, cancelled = true })
	end
	return Errors.ok({ value = value, info = toInfo(info), cancelled = false })
end

function RealDataStore.remove(self: RealDataStore, key: string): Types.Result<Types.Read>
	local ok, value, info = pcall(function()
		return self._store:RemoveAsync(key)
	end)
	if not ok then
		return Errors.failWith(Errors.classify(value))
	end
	return Errors.ok({ value = value, info = toInfo(info) })
end

function RealDataStore.increment(
	self: RealDataStore,
	key: string,
	delta: number,
	options: Types.WriteOptions?
): Types.Result<number>
	local userIds = options and options.userIds
	local metadata = options and options.metadata
	local incrementOptions = if metadata then self._api.newIncrementOptions(metadata) else nil
	local ok, value = pcall(function(): number
		local result = self._store:IncrementAsync(key, delta, userIds, incrementOptions)
		return result :: number
	end)
	if not ok then
		return Errors.failWith(Errors.classify(value))
	end
	return Errors.ok(value)
end

function RealDataStore.listVersions(
	self: RealDataStore,
	key: string,
	query: Types.VersionQuery?
): Types.Result<{ Types.VersionInfo }>
	local ascending = query == nil or query.ascending ~= false
	local limit = query and query.limit or VERSION_PAGE_SIZE
	-- assumes 0 means no bound for minDate and maxDate, unverified
	local minDate = query and query.minDate or 0
	local maxDate = query and query.maxDate or 0
	local direction = if ascending then self._api.sortAscending else self._api.sortDescending

	local ok, pagesOrError = pcall(function()
		return self._store:ListVersionsAsync(
			key,
			direction,
			minDate,
			maxDate,
			math.min(limit, VERSION_PAGE_SIZE)
		)
	end)
	if not ok then
		return Errors.failWith(Errors.classify(pagesOrError))
	end
	local pages = pagesOrError :: DataStoreVersionPages

	local found: { Types.VersionInfo } = {}
	while true do
		for _, item in pages:GetCurrentPage() do
			local version = item :: DataStoreObjectVersionInfo
			table.insert(found, {
				version = version.Version,
				createdTime = version.CreatedTime,
				deleted = version.IsDeleted,
			})
			if #found >= limit then
				return Errors.ok(found)
			end
		end
		if pages.IsFinished then
			return Errors.ok(found)
		end
		local advanced, advanceError = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)
		if not advanced then
			return Errors.failWith(Errors.classify(advanceError))
		end
	end
end

function RealDataStore.getVersion(
	self: RealDataStore,
	key: string,
	version: string
): Types.Result<Types.Read>
	local ok, value, info = pcall(function()
		return self._store:GetVersionAsync(key, version)
	end)
	if not ok then
		return Errors.failWith(Errors.classify(value))
	end
	return Errors.ok({ value = value, info = toInfo(info) })
end

return RealDataStore
