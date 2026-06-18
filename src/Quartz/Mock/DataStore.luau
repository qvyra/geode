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
	}
	return setmetatable(self, MockDataStore)
end

--// helpers

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

function MockDataStore._enter(
	self: MockDataStore,
	method: string,
	key: string
): (Types.AdapterError?, Faults.ForeignWrite?)
	local err, foreign = Context.enter(self._context, SERVICE, self.name, method, key)
	if err then
		return err, nil
	end
	return Context.checkKey(self._context.shared, key), foreign
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
	table.insert(entry.versions, stored)
	return nil, stored
end

--// adapter

function MockDataStore.get(self: MockDataStore, key: string): Types.Result<Types.Read>
	local err = self:_enter("get", key)
	if err then
		return Errors.failWith(err)
	end
	local entry = self._entries[key]
	return Errors.ok(readOf(entry, latest(entry)))
end

function MockDataStore.set(
	self: MockDataStore,
	key: string,
	value: unknown,
	options: Types.WriteOptions?
): Types.Result<string>
	local err = self:_enter("set", key)
	if err then
		return Errors.failWith(err)
	end
	local writeError, stored = self:_write(key, value, options)
	if writeError or stored == nil then
		return Errors.failWith(writeError :: Types.AdapterError)
	end
	return Errors.ok(stored.version)
end

function MockDataStore.update(
	self: MockDataStore,
	key: string,
	transform: Types.Transform
): Types.Result<Types.Update>
	local err, foreign = self:_enter("update", key)
	if err then
		return Errors.failWith(err)
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
		return Errors.ok({ value = current.value, info = current.info, cancelled = true })
	end

	local writeError, stored = self:_write(key, nextValue, options)
	if writeError or stored == nil then
		return Errors.failWith(writeError :: Types.AdapterError)
	end
	local written = self._entries[key]
	return Errors.ok({
		value = Values.clone(stored.value),
		info = infoOf(written, stored),
		cancelled = false,
	})
end

function MockDataStore.remove(self: MockDataStore, key: string): Types.Result<Types.Read>
	local err = self:_enter("remove", key)
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
	table.insert(entry.versions, {
		version = Context.nextId(shared),
		value = nil,
		createdTime = Context.nowMillis(shared),
		deleted = true,
		userIds = {},
		metadata = {},
	})
	return Errors.ok(previous)
end

function MockDataStore.increment(
	self: MockDataStore,
	key: string,
	delta: number,
	options: Types.WriteOptions?
): Types.Result<number>
	local err = self:_enter("increment", key)
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
	-- Unverified: what GetVersionAsync does for a version that never existed. Treated like a
	-- missing key for now
	return Errors.ok({ value = nil, info = nil })
end

return MockDataStore
