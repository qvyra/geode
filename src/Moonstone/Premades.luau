--!strict

-- Ready made cross-server tools on MemoryStore: presence, locks, counters, rate limits and job
-- queues. Each one only costs quota once created, reports a cost estimate, and registers itself
-- for tooling

local RealServices = require("../Quartz/Real/Services")
local Registry = require("../Vein/Registry")
local Scheduler = require("../Quartz/Scheduler")
local Types = require("../Quartz/Types")

export type Options = {
	services: Types.Services?,
	scheduler: Scheduler.Scheduler?,
}

-- 45 days, the MS item maximum
local MAX_TTL = 3888000
local MINUTE = 60

local Premades = {}

--// shared plumbing

-- Requests a premade made over the last minute. estimatedCost reports this for work that
-- only happens on demand
type Meter = {
	clock: Types.Clock,
	calls: { number },
}

local function meter(clock: Types.Clock): Meter
	return { clock = clock, calls = {} }
end

local function record(m: Meter)
	table.insert(m.calls, m.clock:now())
end

local function perMinute(m: Meter): number
	local cutoff = m.clock:now() - MINUTE
	while m.calls[1] and m.calls[1] <= cutoff do
		table.remove(m.calls, 1)
	end
	return #m.calls
end

local function resolve(options: Options?): (Types.Services, Scheduler.Scheduler)
	local services = options and options.services or RealServices.live()
	local scheduler = options and options.scheduler
		or Scheduler.new({ clock = services.clock, budget = services.budget })
	return services, scheduler
end

local function call<T>(
	scheduler: Scheduler.Scheduler,
	m: Meter,
	priority: Scheduler.Priority,
	run: () -> Types.Result<T>
): Types.Result<T>
	return scheduler:submit({
		priority = priority,
		run = function()
			record(m)
			return run()
		end,
	})
end

--// ================================================================ //--
--//  Presence                                                        //--
--// ================================================================ //--

export type PresenceOptions = Options & {
	name: string?,
	-- Seconds an entry lives without a heartbeat. Defaults to 60
	ttl: number?,
	-- Seconds between heartbeats for players this server tracks. Defaults to 20
	heartbeat: number?,
}

export type Location = {
	jobId: string,
	placeId: number,
}

type PresenceFields = {
	name: string,
	_services: Types.Services,
	_scheduler: Scheduler.Scheduler,
	_map: Types.HashMap,
	_ttl: number,
	_heartbeat: number,
	_tracked: { [number]: number },
	_meter: Meter,
	_handle: Registry.Handle,
}

local Presence = {}
Presence.__index = Presence

export type Presence = typeof(setmetatable({} :: PresenceFields, Presence))

--[=[
	Tracks which server each player is on

	@within Presence
]=]
function Premades.presence(options: PresenceOptions?): Presence
	local services, scheduler = resolve(options)
	local name = options and options.name or "presence"
	local ttl = options and options.ttl or 60
	local heartbeat = options and options.heartbeat or 20
	assert(heartbeat < ttl, "the heartbeat must come more often than entries expire")
	local self = setmetatable(
		{
			name = name,
			_services = services,
			_scheduler = scheduler,
			_map = services.hashMap(`geode_presence_{name}`),
			_ttl = ttl,
			_heartbeat = heartbeat,
			_tracked = {},
			_meter = meter(services.clock),
			_handle = nil :: any,
		} :: PresenceFields,
		Presence
	)
	self._handle = Registry.register("presence", name, function()
		return { tracked = self:trackedCount(), estimatedCost = self:estimatedCost() }
	end)
	return self
end

function Presence._write(self: Presence, userId: number): Types.Result<nil>
	local services = self._services
	return call(self._scheduler, self._meter, "background", function()
		return self._map:set(
			tostring(userId),
			{ jobId = services.jobId, placeId = services.placeId },
			self._ttl
		)
	end)
end

--[=[
	Marks a player as on this server and keeps the entry alive until `clear`
]=]
function Presence.set(self: Presence, userId: number): Types.Result<nil>
	local generation = (self._tracked[userId] or 0) + 1
	self._tracked[userId] = generation
	local result = self:_write(userId)
	local clock = self._services.clock
	local function beat()
		if self._tracked[userId] ~= generation then
			return
		end
		self:_write(userId)
		clock:delay(self._heartbeat, beat)
	end
	clock:delay(self._heartbeat, beat)
	return result
end

function Presence.clear(self: Presence, userId: number): Types.Result<nil>
	self._tracked[userId] = nil
	return call(self._scheduler, self._meter, "background", function()
		return self._map:remove(tostring(userId))
	end)
end

--[=[
	Where a player is, or nil when no server has them
]=]
function Presence.where(self: Presence, userId: number): Types.Result<Location?>
	local result = call(self._scheduler, self._meter, "read", function()
		return self._map:get(tostring(userId))
	end)
	if not result.ok then
		return result
	end
	local value = result.value
	if type(value) ~= "table" then
		return { ok = true, value = nil }
	end
	return { ok = true, value = value :: Location }
end

function Presence.trackedCount(self: Presence): number
	local tracked = 0
	for _ in self._tracked do
		tracked += 1
	end
	return tracked
end

--[=[
	Requests per minute: heartbeats for tracked players plus what lookups used over the last minute
]=]
function Presence.estimatedCost(self: Presence): number
	return self:trackedCount() * MINUTE / self._heartbeat + perMinute(self._meter)
end

function Presence.destroy(self: Presence)
	table.clear(self._tracked)
	self._handle:unregister()
end

--// ================================================================ //--
--//  Mutex                                                           //--
--// ================================================================ //--

export type MutexOptions = Options & {
	-- Seconds a lock lasts without renewal. Defaults to 30
	lease: number?,
}

type LockState = {
	holder: string?,
	token: number,
	expiresAt: number,
}

type MutexFields = {
	name: string,
	_services: Types.Services,
	_scheduler: Scheduler.Scheduler,
	_map: Types.HashMap,
	_lease: number,
	_meter: Meter,
	_handle: Registry.Handle,
}

local Mutex = {}
Mutex.__index = Mutex

export type Mutex = typeof(setmetatable({} :: MutexFields, Mutex))

type LockFields = {
	-- Grows on every acquire. Pass it along with writes so stale holders can be refused
	token: number,
	_mutex: Mutex,
	_key: string,
	_holder: string,
	_expiresAt: number,
}

local Lock = {}
Lock.__index = Lock

export type Lock = typeof(setmetatable({} :: LockFields, Lock))

--[=[
	A lock shared by every server, with a lease and a fencing token

	@within Mutex
]=]
function Premades.mutex(name: string, options: MutexOptions?): Mutex
	local services, scheduler = resolve(options)
	local self = setmetatable(
		{
			name = name,
			_services = services,
			_scheduler = scheduler,
			_map = services.hashMap(`geode_mutex_{name}`),
			_lease = options and options.lease or 30,
			_meter = meter(services.clock),
			_handle = nil :: any,
		} :: MutexFields,
		Mutex
	)
	self._handle = Registry.register("mutex", name, function()
		return { estimatedCost = self:estimatedCost() }
	end)
	return self
end

-- Fencing token, +1 per acquire. Also never below the wall clock in ms, so it keeps growing
-- even after the stored item expired and the count started over
local function nextToken(state: LockState?, now: number): number
	return math.max((if state then state.token else 0) + 1, math.floor(now * 1000))
end

--[=[
	Takes the lock named `key`, waiting up to `wait` seconds for a holder to let go. Returns the
	lock, or nil when it stayed taken
]=]
function Mutex.acquire(self: Mutex, key: string, wait: number?): Types.Result<Lock?>
	local clock = self._services.clock
	local holder = self._services.guid()
	local deadline = clock:now() + (wait or 0)
	while true do
		local token: number? = nil
		local expiresAt = 0
		local result = call(self._scheduler, self._meter, "load", function()
			return self._map:update(key, function(current: unknown): unknown
				token = nil
				local now = clock:now()
				local state = if type(current) == "table" then current :: LockState else nil
				if state and state.holder ~= nil and state.expiresAt > now then
					return nil
				end
				token = nextToken(state, now)
				expiresAt = now + self._lease
				return { holder = holder, token = token, expiresAt = expiresAt }
			end, MAX_TTL)
		end)
		if not result.ok then
			return { ok = false, error = result.error }
		end
		if token then
			local lock = setmetatable(
				{
					token = token,
					_mutex = self,
					_key = key,
					_holder = holder,
					_expiresAt = expiresAt,
				} :: LockFields,
				Lock
			)
			return { ok = true, value = lock }
		end
		if clock:now() >= deadline then
			return { ok = true, value = nil }
		end
		clock:wait(math.min(1, deadline - clock:now()))
	end
end

function Mutex.estimatedCost(self: Mutex): number
	return perMinute(self._meter)
end

function Mutex.destroy(self: Mutex)
	self._handle:unregister()
end

-- Changes the stored lock only while this holder still has it
function Lock._change(self: Lock, change: (state: LockState, now: number) -> LockState): boolean
	local mutex = self._mutex
	local clock = mutex._services.clock
	local kept = false
	local result = call(mutex._scheduler, mutex._meter, "save", function()
		return mutex._map:update(self._key, function(current: unknown): unknown
			kept = false
			local state = if type(current) == "table" then current :: LockState else nil
			local now = clock:now()
			if state == nil or state.holder ~= self._holder or state.expiresAt <= now then
				return nil
			end
			kept = true
			return change(state, now)
		end, MAX_TTL)
	end)
	return result.ok and kept
end

--[=[
	Extends the lease. False when the lock was already lost
]=]
function Lock.renew(self: Lock): boolean
	local lease = self._mutex._lease
	local renewed = self:_change(function(state: LockState, now: number): LockState
		self._expiresAt = now + lease
		return { holder = state.holder, token = state.token, expiresAt = now + lease }
	end)
	return renewed
end

--[=[
	Gives the lock up. The token stays stored so the next one is larger
]=]
function Lock.release(self: Lock): boolean
	local released = self:_change(function(state: LockState): LockState
		return { holder = nil, token = state.token, expiresAt = 0 }
	end)
	self._expiresAt = 0
	return released
end

--[=[
	Whether this server still holds the lock, judged by its own clock. Only the token is a real
	guarantee, so check it on writes
]=]
function Lock.isHeld(self: Lock): boolean
	return self._mutex._services.clock:now() < self._expiresAt
end

--// ================================================================ //--
--//  Counter                                                         //--
--// ================================================================ //--

export type CounterOptions = Options & {
	-- Seconds a counter lives after its last change. Defaults to the 45 day maximum
	ttl: number?,
}

type CounterFields = {
	name: string,
	_scheduler: Scheduler.Scheduler,
	_map: Types.HashMap,
	_ttl: number,
	_meter: Meter,
	_handle: Registry.Handle,
}

local Counter = {}
Counter.__index = Counter

export type Counter = typeof(setmetatable({} :: CounterFields, Counter))

--[=[
	Counters every server can change atomically

	@within Counter
]=]
function Premades.counter(name: string, options: CounterOptions?): Counter
	local services, scheduler = resolve(options)
	local self = setmetatable(
		{
			name = name,
			_scheduler = scheduler,
			_map = services.hashMap(`geode_counter_{name}`),
			_ttl = options and options.ttl or MAX_TTL,
			_meter = meter(services.clock),
			_handle = nil :: any,
		} :: CounterFields,
		Counter
	)
	self._handle = Registry.register("counter", name, function()
		return { estimatedCost = self:estimatedCost() }
	end)
	return self
end

function Counter.increment(self: Counter, key: string, delta: number?): Types.Result<number>
	local amount = delta or 1
	local result = call(self._scheduler, self._meter, "save", function()
		return self._map:update(key, function(current: unknown): unknown
			return (if type(current) == "number" then current else 0) + amount
		end, self._ttl)
	end)
	if not result.ok then
		return { ok = false, error = result.error }
	end
	return { ok = true, value = result.value.value :: number }
end

function Counter.get(self: Counter, key: string): Types.Result<number>
	local result = call(self._scheduler, self._meter, "read", function()
		return self._map:get(key)
	end)
	if not result.ok then
		return { ok = false, error = result.error }
	end
	return { ok = true, value = if type(result.value) == "number" then result.value else 0 }
end

function Counter.estimatedCost(self: Counter): number
	return perMinute(self._meter)
end

function Counter.destroy(self: Counter)
	self._handle:unregister()
end

--// ================================================================ //--
--//  Rate limiter                                                    //--
--// ================================================================ //--

export type RateLimiterOptions = Options & {
	-- per key, per window
	limit: number,
	-- Window length in seconds
	window: number,
}

type RateLimiterFields = {
	name: string,
	_services: Types.Services,
	_scheduler: Scheduler.Scheduler,
	_map: Types.HashMap,
	_limit: number,
	_window: number,
	_meter: Meter,
	_handle: Registry.Handle,
}

local RateLimiter = {}
RateLimiter.__index = RateLimiter

export type RateLimiter = typeof(setmetatable({} :: RateLimiterFields, RateLimiter))

--[=[
	A limit shared by every server, counted in fixed windows. A sliding window costs more
	requests per check, so a burst across a window edge can reach up to twice the limit

	@within RateLimiter
]=]
function Premades.rateLimiter(name: string, options: RateLimiterOptions): RateLimiter
	assert(options.limit > 0, "the limit must be positive")
	assert(options.window > 0, "the window must be positive")
	local services, scheduler = resolve(options)
	local self = setmetatable(
		{
			name = name,
			_services = services,
			_scheduler = scheduler,
			_map = services.hashMap(`geode_rate_{name}`),
			_limit = options.limit,
			_window = options.window,
			_meter = meter(services.clock),
			_handle = nil :: any,
		} :: RateLimiterFields,
		RateLimiter
	)
	self._handle = Registry.register("rateLimiter", name, function()
		return { estimatedCost = self:estimatedCost() }
	end)
	return self
end

--[=[
	Spends `cost` from `key`'s allowance. True when it fit, false when the window is used up
]=]
function RateLimiter.allow(self: RateLimiter, key: string, cost: number?): Types.Result<boolean>
	local spend = cost or 1
	local now = self._services.clock:now()
	local windowIndex = math.floor(now / self._window)
	local allowed = false
	local result = call(self._scheduler, self._meter, "read", function()
		return self._map:update(`{key}:{windowIndex}`, function(current: unknown): unknown
			allowed = false
			local used = if type(current) == "number" then current else 0
			if used + spend > self._limit then
				return nil
			end
			allowed = true
			return used + spend
		end, math.ceil(self._window * 2))
	end)
	if not result.ok then
		return { ok = false, error = result.error }
	end
	return { ok = true, value = allowed }
end

function RateLimiter.estimatedCost(self: RateLimiter): number
	return perMinute(self._meter)
end

function RateLimiter.destroy(self: RateLimiter)
	self._handle:unregister()
end

--// ================================================================ //--
--//  Job queue                                                       //--
--// ================================================================ //--

export type JobQueueOptions = Options & {
	-- Seconds a claimed job stays hidden before another server may claim it. Defaults to 30
	invisibilityTimeout: number?,
	-- Seconds a job waits to be claimed before it's dropped. Defaults to the 45 day maximum
	ttl: number?,
}

export type Claim = {
	jobs: { unknown },
	-- Removes the jobs for good once they're done
	ack: (self: Claim) -> Types.Result<nil>,
	-- Gives the jobs up. They show up again once the invisibility timeout passes
	nack: (self: Claim) -> (),
}

type JobQueueFields = {
	name: string,
	_scheduler: Scheduler.Scheduler,
	_queue: Types.Queue,
	_ttl: number,
	_meter: Meter,
	_handle: Registry.Handle,
}

local JobQueue = {}
JobQueue.__index = JobQueue

export type JobQueue = typeof(setmetatable({} :: JobQueueFields, JobQueue))

--[=[
	Jobs any server can add and exactly one server at a time can claim

	@within JobQueue
]=]
function Premades.jobQueue(name: string, options: JobQueueOptions?): JobQueue
	local services, scheduler = resolve(options)
	local self = setmetatable(
		{
			name = name,
			_scheduler = scheduler,
			_queue = services.queue(`geode_jobs_{name}`, options and options.invisibilityTimeout),
			_ttl = options and options.ttl or MAX_TTL,
			_meter = meter(services.clock),
			_handle = nil :: any,
		} :: JobQueueFields,
		JobQueue
	)
	self._handle = Registry.register("jobQueue", name, function()
		return { estimatedCost = self:estimatedCost() }
	end)
	return self
end

function JobQueue.push(self: JobQueue, job: unknown, priority: number?): Types.Result<nil>
	return call(self._scheduler, self._meter, "save", function()
		return self._queue:add(job, self._ttl, priority)
	end)
end

--[=[
	Claims up to `count` jobs, waiting up to `wait` seconds for any to show up. Nil when there were
	none
]=]
function JobQueue.claim(self: JobQueue, count: number?, wait: number?): Types.Result<Claim?>
	local read = call(self._scheduler, self._meter, "read", function()
		return self._queue:read({ count = count or 1, waitTimeout = wait })
	end)
	if not read.ok then
		return { ok = false, error = read.error }
	end
	local id = read.value.id
	if id == nil or #read.value.items == 0 then
		return { ok = true, value = nil }
	end
	local claim: Claim = {
		jobs = read.value.items,
		ack = function(_claim: Claim): Types.Result<nil>
			return call(self._scheduler, self._meter, "save", function()
				return self._queue:remove(id)
			end)
		end,
		nack = function(_claim: Claim) end,
	}
	return { ok = true, value = claim }
end

function JobQueue.estimatedCost(self: JobQueue): number
	return perMinute(self._meter)
end

function JobQueue.destroy(self: JobQueue)
	self._handle:unregister()
end

return Premades
