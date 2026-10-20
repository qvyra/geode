--!strict

local Context = require("./Context")
local Errors = require("../Errors")
local Faults = require("./Faults")
local Types = require("../Types")
local Values = require("./Values")

type Context = Context.Context
type DataStoreEntry = Context.DataStoreEntry
type StoredVersion = Context.StoredVersion

type Fields = {
	name: string,
	scope: string,
	_context: Context,
	_entries: { [string]: DataStoreEntry },
	-- this server's copies of keys, only with `dataStoreCache` on
	_cached: { [string]: { read: Types.Read, expiresAt: number } },
}

local MockDataStore = {}
MockDataStore.__index = MockDataStore

export type MockDataStore = typeof(setmetatable({} :: Fields, MockDataStore))

local SERVICE = "dataStore"

function MockDataStore.new(context: Context, name: string, scope: string): MockDataStore
	local id = `{name}\0{scope}`
	local stores = context.shared.dataStores
	stores[id] = stores[id] or {}
	local self: Fields = {
		name = name,
		scope = scope,
		_context = context,
		_entries = stores[id],
		_cached = {},
	}
	return setmetatable(self, MockDataStore)
end

--// helpers

local HOUR_MILLIS = 3600 * 1000

-- One version per key per UTC hour. A later write in the same hour replaces it and the old
-- id reads as nil after that. Checked on live keys, Roblox doesn't document this
local function keepVersion(entry: DataStoreEntry, stored: StoredVersion)
	local versions = entry.versions
	local last = versions[#versions]
	if last and last.createdTime // HOUR_MILLIS == stored.createdTime // HOUR_MILLIS then
		local replaced = entry.replaced or {}
		entry.replaced = replaced
		replaced[last.version] = true
		versions[#versions] = stored
	else
		table.insert(versions, stored)
	end
end

local function latest(entry: DataStoreEntry?): StoredVersion?
	if entry == nil then
		return nil
	end
	local last = entry.versions[#entry.versions]
	if last == nil or last.deleted then
		return nil
	end
	return last
end

local function infoOf(entry: DataStoreEntry, version: StoredVersion): Types.KeyInfo
	return {
		version = version.version,
		createdTime = entry.createdTime,
		updatedTime = version.createdTime,
		userIds = table.clone(version.userIds),
		metadata = Values.clone(version.metadata) :: { [string]: unknown },
	}
end

local function readOf(entry: DataStoreEntry?, version: StoredVersion?): Types.Read
	if entry == nil or version == nil then
		return { value = nil, info = nil }
	end
	return { value = Values.clone(version.value), info = infoOf(entry, version) }
end

local function cloneRead(read: Types.Read): Types.Read
	local info = read.info
	return {
		value = Values.clone(read.value),
		info = if info
			then {
				version = info.version,
				createdTime = info.createdTime,
				updatedTime = info.updatedTime,
				userIds = table.clone(info.userIds),
				metadata = Values.clone(info.metadata) :: { [string]: unknown },
			}
			else nil,
	}
end

-- Keeps this server's copy of `key` and restarts its timer
function MockDataStore._remember(self: MockDataStore, key: string, read: Types.Read)
	local cache = self._context.shared.dataStoreCache
	if cache == nil then
		return
	end
	self._cached[key] = {
		read = cloneRead(read),
		expiresAt = self._context.shared.clock:now() + cache.seconds,
	}
end

function MockDataStore._cachedRead(self: MockDataStore, key: string): Types.Read?
	local entry = self._cached[key]
	if entry == nil or self._context.shared.clock:now() >= entry.expiresAt then
		return nil
	end
	return cloneRead(entry.read)
end

function MockDataStore._enter(
	self: MockDataStore,
	method: string,
	key: string
): (Types.AdapterError?, Faults.ForeignWrite?, Types.AdapterError?)
	local err, foreign, landed = Context.enter(self._context, SERVICE, self.name, method, key)
	if err then
		return err, nil, nil
	end
	local shared = self._context.shared
	return Context.checkStoreName(shared, self.name, self.scope) or Context.checkKey(shared, key),
		foreign,
		landed
end

function MockDataStore._write(
	self: MockDataStore,
	key: string,
	value: unknown,
	options: Types.WriteOptions?
): (Types.AdapterError?, StoredVersion?)
	local ok, copy = Values.copy(value)
	if not ok then
		return Errors.classify(`104: {copy}`), nil
	end
	local sizeError = Context.checkSize(self._context.shared, copy)
	if sizeError then
		return sizeError, nil
	end
	local throughputError =
		Context.useThroughput(self._context.shared, self:_throughputId(key), copy, true)
	if throughputError then
		return throughputError, nil
	end

	local shared = self._context.shared
	local now = Context.nowMillis(shared)
	local entry = self._entries[key]
	if entry == nil then
		entry = { createdTime = now, versions = {} }
		self._entries[key] = entry
	end
	local stored: StoredVersion = {
		version = Context.nextId(shared),
		value = copy,
		createdTime = now,
		deleted = false,
		userIds = if options and options.userIds then table.clone(options.userIds) else {},
		metadata = if options and options.metadata
			then Values.clone(options.metadata) :: { [string]: unknown }
			else {},
	}
	keepVersion(entry, stored)
	return nil, stored
end

function MockDataStore._throughputId(self: MockDataStore, key: string): string
	return `{self.name}/{self.scope}/{key}`
end

--// adapter

function MockDataStore.get(
	self: MockDataStore,
	key: string,
	options: Types.ReadOptions?
): Types.Result<Types.Read>
	-- a cached answer never reaches the backend, so it costs no budget
	local cached = if options == nil or options.useCache ~= false
		then self:_cachedRead(key)
		else nil
	if cached then
		return Errors.ok(cached)
	end
	local err = self:_enter("get", key)
	if err then
		return Errors.failWith(err)
	end
	local entry = self._entries[key]
	local stored = latest(entry)
	local readError = Context.useThroughput(
		self._context.shared,
		self:_throughputId(key),
		if stored then stored.value else nil,
		false
	)
	if readError then
		return Errors.failWith(readError)
	end
	local read = readOf(entry, latest(entry))
	self:_remember(key, read)
	return Errors.ok(read)
end

function MockDataStore.set(
	self: MockDataStore,
	key: string,
	value: unknown,
	options: Types.WriteOptions?
): Types.Result<string>
	local err, _, landed = self:_enter("set", key)
	if err then
		return Errors.failWith(err)
	end
	local writeError, stored = self:_write(key, value, options)
	if writeError or stored == nil then
		return Errors.failWith(writeError :: Types.AdapterError)
	end
	self:_remember(key, readOf(self._entries[key], stored))
	if landed then
		return Errors.failWith(landed)
	end
	return Errors.ok(stored.version)
end

function MockDataStore.update(
	self: MockDataStore,
	key: string,
	transform: Types.Transform
): Types.Result<Types.Update>
	local err, foreign, landed = self:_enter("update", key)
	if err then
		return Errors.failWith(err)
	end

	local cache = self._context.shared.dataStoreCache
	if foreign == nil and cache and cache.cancelledUpdates then
		local cached = self:_cachedRead(key)
		if cached and transform(cached.value, cached.info) == nil then
			return Errors.ok({ value = cached.value, info = cached.info, cancelled = true })
		end
	end

	if foreign then
		local before = readOf(self._entries[key], latest(self._entries[key]))
		if foreign.rerun then
			-- Our transform sees the stale value first and loses the race, like a real retry
			transform(before.value, before.info)
		end
		local foreignValue = foreign.transform(before.value)
		if foreignValue ~= nil then
			self:_write(key, foreignValue, nil)
		end
	end

	local entry = self._entries[key]
	local current = readOf(entry, latest(entry))
	local nextValue, options = transform(current.value, current.info)
	if nextValue == nil then
		self:_remember(key, current)
		return Errors.ok({ value = current.value, info = current.info, cancelled = true })
	end

	-- no metadata given: keep what the key had
	local writeOptions = options
	if current.info and (options == nil or options.metadata == nil) then
		writeOptions = {
			userIds = options and options.userIds,
			metadata = current.info.metadata,
		}
	end
	local writeError, stored = self:_write(key, nextValue, writeOptions)
	if writeError or stored == nil then
		return Errors.failWith(writeError :: Types.AdapterError)
	end
	self:_remember(key, readOf(self._entries[key], stored))
	if landed then
		return Errors.failWith(landed)
	end
	local written = self._entries[key]
	return Errors.ok({
		value = Values.clone(stored.value),
		info = infoOf(written, stored),
		cancelled = false,
	})
end

function MockDataStore.remove(self: MockDataStore, key: string): Types.Result<Types.Read>
	local err, _, landed = self:_enter("remove", key)
	if err then
		return Errors.failWith(err)
	end
	local entry = self._entries[key]
	local current = latest(entry)
	if entry == nil or current == nil then
		return Errors.ok({ value = nil, info = nil })
	end

	local previous = readOf(entry, current)
	local shared = self._context.shared
	keepVersion(entry, {
		version = Context.nextId(shared),
		value = nil,
		createdTime = Context.nowMillis(shared),
		deleted = true,
		userIds = {},
		metadata = {},
	})
	self:_remember(key, { value = nil, info = nil })
	if landed then
		return Errors.failWith(landed)
	end
	return Errors.ok(previous)
end

function MockDataStore.increment(
	self: MockDataStore,
	key: string,
	delta: number,
	options: Types.WriteOptions?
): Types.Result<number>
	local err, _, landed = self:_enter("increment", key)
	if err then
		return Errors.failWith(err)
	end
	local current = latest(self._entries[key])
	local base = if current then current.value else 0
	if type(base) ~= "number" or base % 1 ~= 0 then
		return Errors.failWith(Errors.classify(`103: Can't increment a non integer value at {key}`))
	end
	if delta % 1 ~= 0 then
		return Errors.fail("invalidValue", "increment delta must be an integer")
	end

	local writeError, stored = self:_write(key, base + delta, options)
	if writeError or stored == nil then
		return Errors.failWith(writeError :: Types.AdapterError)
	end
	self:_remember(key, readOf(self._entries[key], stored))
	if landed then
		return Errors.failWith(landed)
	end
	return Errors.ok(stored.value :: number)
end

function MockDataStore.listVersions(
	self: MockDataStore,
	key: string,
	query: Types.VersionQuery?
): Types.Result<{ Types.VersionInfo }>
	local err = self:_enter("listVersions", key)
	if err then
		return Errors.failWith(err)
	end
	local ascending = if query and query.ascending ~= nil then query.ascending else true
	local minDate = query and query.minDate
	local maxDate = query and query.maxDate
	local limit = query and query.limit or 100

	local entry = self._entries[key]
	local found: { Types.VersionInfo } = {}
	if entry then
		local versions = entry.versions
		local first, last, step = 1, #versions, 1
		if not ascending then
			first, last, step = #versions, 1, -1
		end
		for index = first, last, step do
			local version = versions[index]
			if minDate and version.createdTime < minDate then
				continue
			end
			if maxDate and version.createdTime > maxDate then
				continue
			end
			table.insert(found, {
				version = version.version,
				createdTime = version.createdTime,
				deleted = version.deleted,
			})
			if #found >= limit then
				break
			end
		end
	end
	return Errors.ok(found)
end

function MockDataStore.getVersion(
	self: MockDataStore,
	key: string,
	version: string
): Types.Result<Types.Read>
	local err = self:_enter("getVersion", key)
	if err then
		return Errors.failWith(err)
	end
	local entry = self._entries[key]
	if entry then
		for _, stored in entry.versions do
			if stored.version == version then
				if stored.deleted then
					return Errors.ok({ value = nil, info = nil })
				end
				return Errors.ok(readOf(entry, stored))
			end
		end
	end
	if entry and entry.replaced and entry.replaced[version] then
		return Errors.ok({ value = nil, info = nil })
	end
	return Errors.failWith(
		Errors.classify(
			"502: API Services rejected request with error. Error code: 25 Reason: The provided version is not valid."
		)
	)
end

return MockDataStore
