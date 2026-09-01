--!strict

-- MemoryStore structures with validation, retries and scheduling. Values are checked against
-- an optional schema before they're written, every call goes through the scheduler so throttles
-- retry with backoff, and each structure registers itself for tooling

local RealServices = require("../Quartz/Real/Services")
local Registry = require("../Vein/Registry")
local Scheduler = require("../Quartz/Scheduler")
local Schema = require("../Obsidian/Schema")
local Types = require("../Quartz/Types")
local Validate = require("../Obsidian/Validate")

export type Options = {
	services: Types.Services?,
	scheduler: Scheduler.Scheduler?,
	schema: Schema.Schema?,
}

export type QueueOptions = Options & {
	-- Seconds a read hides its items before they show up for others again. Defaults to 30
	invisibilityTimeout: number?,
}

local Ephemeral = {}

local function resolve(options: Options?): (Types.Services, Scheduler.Scheduler)
	local services = options and options.services or RealServices.live()
	local scheduler = options and options.scheduler
		or Scheduler.new({ clock = services.clock, budget = services.budget })
	return services, scheduler
end

local function run<T>(
	scheduler: Scheduler.Scheduler,
	priority: Scheduler.Priority,
	call: () -> Types.Result<T>
): Types.Result<T>
	return scheduler:submit({ priority = priority, run = call })
end

local function check(schema: Schema.Schema?, name: string, value: unknown): Types.AdapterError?
	if schema == nil then
		return nil
	end
	local result = Validate.validate(schema, value, { root = "value" })
	if result.ok then
		return nil
	end
	local issue = result.issues[1]
	return { kind = "invalidValue", message = `{name}: {issue.path} {issue.message}` }
end

-- Hash map

type HashMapFields = {
	name: string,
	_scheduler: Scheduler.Scheduler,
	_schema: Schema.Schema?,
	_handle: Registry.Handle,
	_map: Types.HashMap,
}

local HashMap = {}
HashMap.__index = HashMap

export type HashMap = typeof(setmetatable({} :: HashMapFields, HashMap))

--[=[
	A MemoryStore hash map with validation and retries

	@within Ephemeral
]=]
function Ephemeral.hashMap(name: string, options: Options?): HashMap
	local services, scheduler = resolve(options)
	return setmetatable(
		{
			name = name,
			_scheduler = scheduler,
			_schema = options and options.schema,
			_handle = Registry.register("hashMap", name),
			_map = services.hashMap(name),
		} :: HashMapFields,
		HashMap
	)
end

function HashMap.get(self: HashMap, key: string): Types.Result<unknown>
	return run(self._scheduler, "read", function()
		return self._map:get(key)
	end)
end

function HashMap.set(self: HashMap, key: string, value: unknown, ttl: number): Types.Result<nil>
	local invalid = check(self._schema, self.name, value)
	if invalid then
		return { ok = false, error = invalid }
	end
	return run(self._scheduler, "save", function()
		return self._map:set(key, value, ttl)
	end)
end

--[=[
	Changes a value atomically. Returning nil from `transform` leaves it as it was. A result the
	schema refuses cancels the update
]=]
function HashMap.update(
	self: HashMap,
	key: string,
	transform: (current: unknown) -> unknown,
	ttl: number
): Types.Result<Types.MemoryUpdate>
	local invalid: Types.AdapterError? = nil
	local result = run(self._scheduler, "save", function()
		return self._map:update(key, function(current: unknown): unknown
			invalid = nil
			local nextValue = transform(current)
			if nextValue ~= nil then
				invalid = check(self._schema, self.name, nextValue)
				if invalid then
					return nil
				end
			end
			return nextValue
		end, ttl)
	end)
	if invalid then
		return { ok = false, error = invalid }
	end
	return result
end

function HashMap.remove(self: HashMap, key: string): Types.Result<nil>
	return run(self._scheduler, "save", function()
		return self._map:remove(key)
	end)
end

function HashMap.list(self: HashMap, limit: number?): Types.Result<{ Types.HashMapEntry }>
	return run(self._scheduler, "background", function()
		return self._map:list(limit)
	end)
end

function HashMap.destroy(self: HashMap)
	self._handle:unregister()
end

-- Sorted map

type SortedMapFields = {
	name: string,
	_scheduler: Scheduler.Scheduler,
	_schema: Schema.Schema?,
	_handle: Registry.Handle,
	_map: Types.SortedMap,
}

local SortedMap = {}
SortedMap.__index = SortedMap

export type SortedMap = typeof(setmetatable({} :: SortedMapFields, SortedMap))

--[=[
	A MemoryStore sorted map with validation and retries

	@within Ephemeral
]=]
function Ephemeral.sortedMap(name: string, options: Options?): SortedMap
	local services, scheduler = resolve(options)
	return setmetatable(
		{
			name = name,
			_scheduler = scheduler,
			_schema = options and options.schema,
			_handle = Registry.register("sortedMap", name),
			_map = services.sortedMap(name),
		} :: SortedMapFields,
		SortedMap
	)
end

function SortedMap.get(self: SortedMap, key: string): Types.Result<Types.SortedEntry?>
	return run(self._scheduler, "read", function()
		return self._map:get(key)
	end)
end

function SortedMap.set(
	self: SortedMap,
	key: string,
	value: unknown,
	ttl: number,
	sortKey: Types.SortKey?
): Types.Result<nil>
	local invalid = check(self._schema, self.name, value)
	if invalid then
		return { ok = false, error = invalid }
	end
	return run(self._scheduler, "save", function()
		return self._map:set(key, value, ttl, sortKey)
	end)
end

function SortedMap.update(
	self: SortedMap,
	key: string,
	transform: Types.SortedTransform,
	ttl: number
): Types.Result<Types.SortedUpdate>
	local invalid: Types.AdapterError? = nil
	local result = run(self._scheduler, "save", function()
		return self._map:update(key, function(current: unknown, sortKey: Types.SortKey?)
			invalid = nil
			local nextValue, nextSortKey = transform(current, sortKey)
			if nextValue ~= nil then
				invalid = check(self._schema, self.name, nextValue)
				if invalid then
					return nil, nil
				end
			end
			return nextValue, nextSortKey
		end, ttl)
	end)
	if invalid then
		return { ok = false, error = invalid }
	end
	return result
end

function SortedMap.remove(self: SortedMap, key: string): Types.Result<nil>
	return run(self._scheduler, "save", function()
		return self._map:remove(key)
	end)
end

function SortedMap.getRange(
	self: SortedMap,
	range: Types.SortedRange
): Types.Result<{ Types.SortedEntry }>
	return run(self._scheduler, "read", function()
		return self._map:getRange(range)
	end)
end

function SortedMap.destroy(self: SortedMap)
	self._handle:unregister()
end

--// queue

type QueueFields = {
	name: string,
	_scheduler: Scheduler.Scheduler,
	_schema: Schema.Schema?,
	_handle: Registry.Handle,
	_queue: Types.Queue,
}

local Queue = {}
Queue.__index = Queue

export type Queue = typeof(setmetatable({} :: QueueFields, Queue))

--[=[
	A MemoryStore queue with validation and retries

	@within Ephemeral
]=]
function Ephemeral.queue(name: string, options: QueueOptions?): Queue
	local services, scheduler = resolve(options)
	return setmetatable(
		{
			name = name,
			_scheduler = scheduler,
			_schema = options and options.schema,
			_handle = Registry.register("queue", name),
			_queue = services.queue(name, options and options.invisibilityTimeout),
		} :: QueueFields,
		Queue
	)
end

function Queue.add(self: Queue, value: unknown, ttl: number, priority: number?): Types.Result<nil>
	local invalid = check(self._schema, self.name, value)
	if invalid then
		return { ok = false, error = invalid }
	end
	return run(self._scheduler, "save", function()
		return self._queue:add(value, ttl, priority)
	end)
end

function Queue.read(self: Queue, options: Types.QueueReadOptions): Types.Result<Types.QueueRead>
	return run(self._scheduler, "read", function()
		return self._queue:read(options)
	end)
end

function Queue.remove(self: Queue, id: string): Types.Result<nil>
	return run(self._scheduler, "save", function()
		return self._queue:remove(id)
	end)
end

function Queue.destroy(self: Queue)
	self._handle:unregister()
end

return Ephemeral
