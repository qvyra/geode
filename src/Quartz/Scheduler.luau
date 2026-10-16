--!strict

-- Every DataStore request goes through here. When requests compete for budget it picks
-- releases, then saves, loads, reads, and background work last. Waiting requests age upward
-- so nothing starves, failures retry with jittered backoff, each key stays inside its
-- throughput limits, and identical reads share one call

local Future = require("./Future")
local Throughput = require("./Throughput")
local Types = require("./Types")

export type Priority = "release" | "save" | "load" | "read" | "background"

export type Request<T> = {
	priority: Priority,
	run: () -> Types.Result<T>,
	-- store qualified, e.g. "dataStore/Players/p1". Writes to one key run one at a time
	key: string?,
	write: boolean?,
	-- Budgets to draw from, waits while any is empty. UpdateAsync passes both read and write
	budget: (Types.BudgetType | { Types.BudgetType })?,
	-- same coalesce id shares one pending call. reads only
	coalesce: string?,
	-- Bytes moved, if known, counted against the key's throughput window. Writes count against
	-- both the read and write windows, like UpdateAsync
	size: number?,
}

export type Options = {
	clock: Types.Clock,
	budget: Types.Budget?,
	maxConcurrent: number?,
	maxAttempts: number?,
	baseDelay: number?,
	maxDelay: number?,
	agingInterval: number?,
	-- Min gap between two writes to one key. Off by default, Roblox limits throughput per key
	-- rather than spacing writes
	-- TODO(verify): is the old 6s cooldown between writes to one key really gone, or does it
	-- still apply on top of the throughput window for some calls?
	writeSpacing: number?,
	-- per key throughput limits, on by default
	keyThroughput: boolean?,
	budgetPollInterval: number?,
	-- in [0, 1). Tests pass a fixed sequence to pin down backoff
	random: (() -> number)?,
}

export type Stats = {
	queued: number,
	inFlight: number,
	queuedByPriority: { [string]: number },
}

type Entry = {
	seq: number,
	request: Request<unknown>,
	rank: number,
	enqueuedAt: number,
	notBefore: number,
	attempts: number,
	future: Future.Future,
}

type Config = {
	maxConcurrent: number,
	maxAttempts: number,
	baseDelay: number,
	maxDelay: number,
	agingInterval: number,
	writeSpacing: number,
	keyThroughput: boolean,
	budgetPollInterval: number,
	random: () -> number,
}

type KeyWindows = { read: Throughput.Tracker, write: Throughput.Tracker }

type Fields = {
	_clock: Types.Clock,
	_budget: Types.Budget?,
	_config: Config,
	_queue: { Entry },
	_seq: number,
	_inFlight: number,
	_writing: { [string]: boolean },
	_lastWriteAt: { [string]: number },
	_windows: { [string]: KeyWindows },
	_coalesced: { [string]: Future.Future },
	_pumping: boolean,
	_pumpAgain: boolean,
	_timerAt: number?,
	_timerToken: number,
}

--[=[
	@class Scheduler

	Runs every DataStore request in priority order within the request budgets. Made with
	`Geode.Raw.scheduler`
]=]
local Scheduler = {}
Scheduler.__index = Scheduler

export type Scheduler = typeof(setmetatable({} :: Fields, Scheduler))

local RANKS: { [Priority]: number } = {
	release = 1,
	save = 2,
	load = 3,
	read = 4,
	background = 5,
}

local RETRYABLE: { [Types.ErrorKind]: boolean } = {
	throttled = true,
	internal = true,
}

local DEFAULTS = {
	maxConcurrent = 8,
	maxAttempts = 5,
	baseDelay = 1,
	maxDelay = 30,
	agingInterval = 10,
	writeSpacing = 0,
	budgetPollInterval = 1,
}

--[=[
	Creates a scheduler

	@within Scheduler
	@param options Options
	@return Scheduler

	```lua
	local scheduler = Geode.Raw.scheduler({ clock = services.clock, budget = services.budget })
	local result = scheduler:submit({
		priority = "load",
		budget = "standardRead",
		run = function()
			return store:get("player_1")
		end,
	})
	```
]=]
function Scheduler.new(options: Options): Scheduler
	local config: Config = {
		maxConcurrent = options.maxConcurrent or DEFAULTS.maxConcurrent,
		maxAttempts = options.maxAttempts or DEFAULTS.maxAttempts,
		baseDelay = options.baseDelay or DEFAULTS.baseDelay,
		maxDelay = options.maxDelay or DEFAULTS.maxDelay,
		agingInterval = options.agingInterval or DEFAULTS.agingInterval,
		writeSpacing = options.writeSpacing or DEFAULTS.writeSpacing,
		keyThroughput = options.keyThroughput ~= false,
		budgetPollInterval = options.budgetPollInterval or DEFAULTS.budgetPollInterval,
		random = options.random or math.random,
	}
	assert(config.maxConcurrent >= 1, "maxConcurrent must be at least 1")
	assert(config.maxAttempts >= 1, "maxAttempts must be at least 1")
	assert(config.agingInterval > 0, "agingInterval must be positive")

	local self: Fields = {
		_clock = options.clock,
		_budget = options.budget,
		_config = config,
		_queue = {},
		_seq = 0,
		_inFlight = 0,
		_writing = {},
		_lastWriteAt = {},
		_windows = {},
		_coalesced = {},
		_pumping = false,
		_pumpAgain = false,
		_timerAt = nil,
		_timerToken = 0,
	}
	return setmetatable(self, Scheduler)
end

--// ================================================================ //--
--//  Picking the next request                                        //--
--// ================================================================ //--

function Scheduler._effectiveRank(self: Scheduler, entry: Entry, now: number): number
	local promotions = math.floor((now - entry.enqueuedAt) / self._config.agingInterval)
	return math.max(1, entry.rank - promotions)
end

-- Can the entry start now? If not, also the earliest time worth checking again. nil there
-- means only another request finishing can unblock it
function Scheduler._readiness(self: Scheduler, entry: Entry, now: number): (boolean, number?)
	if entry.notBefore > now then
		return false, entry.notBefore
	end

	local request = entry.request
	if request.write and request.key then
		if self._writing[request.key] then
			return false, nil
		end
		local lastWrite = self._lastWriteAt[request.key]
		if lastWrite and now < lastWrite + self._config.writeSpacing then
			return false, lastWrite + self._config.writeSpacing
		end
	end

	local windows = self:_windowsFor(request)
	if windows then
		local kilobytes = Throughput.kilobytes(request.size :: number)
		local readRoom, readAt = windows.read:room(now, kilobytes)
		if not readRoom then
			return false, readAt
		end
		if request.write then
			local writeRoom, writeAt = windows.write:room(now, kilobytes)
			if not writeRoom then
				return false, writeAt
			end
		end
	end

	local budget = self._budget
	if request.budget and budget then
		local budgetTypes: { Types.BudgetType } = if type(request.budget) == "table"
			then request.budget
			else { request.budget }
		for _, budgetType: Types.BudgetType in budgetTypes do
			if budget:get(budgetType) < 1 then
				return false, now + self._config.budgetPollInterval
			end
		end
	end
	return true, nil
end

function Scheduler._windowsFor(self: Scheduler, request: Request<unknown>): KeyWindows?
	local key = request.key
	if not self._config.keyThroughput or key == nil or request.size == nil then
		return nil
	end
	local windows = self._windows[key]
	if windows == nil then
		windows = {
			read = Throughput.tracker(Throughput.READ_LIMIT_KB),
			write = Throughput.tracker(Throughput.WRITE_LIMIT_KB),
		}
		self._windows[key] = windows
	end
	return windows
end

-- Linear scan. One entry per pending request on one server, so a heap wouldn't pay off yet
function Scheduler._pick(self: Scheduler, now: number): (number?, number?)
	local bestIndex: number? = nil
	local bestRank = math.huge
	local bestSeq = math.huge
	local wakeAt: number? = nil

	for index, entry in self._queue do
		local ready, retryAt = self:_readiness(entry, now)
		if ready then
			local rank = self:_effectiveRank(entry, now)
			if rank < bestRank or (rank == bestRank and entry.seq < bestSeq) then
				bestIndex, bestRank, bestSeq = index, rank, entry.seq
			end
		elseif retryAt and (wakeAt == nil or retryAt < wakeAt) then
			wakeAt = retryAt
		end
	end
	return bestIndex, wakeAt
end

--// ================================================================ //--
--//  Running                                                         //--
--// ================================================================ //--

function Scheduler._backoff(self: Scheduler, attempts: number): number
	local config = self._config
	local ceiling = math.min(config.maxDelay, config.baseDelay * 2 ^ (attempts - 1))
	return config.random() * ceiling
end

function Scheduler._finish(self: Scheduler, entry: Entry, result: Types.Result<unknown>)
	local id = entry.request.coalesce
	if id and self._coalesced[id] == entry.future then
		self._coalesced[id] = nil
	end
	entry.future:resolve(result)
end

function Scheduler._start(self: Scheduler, entry: Entry)
	local request = entry.request
	local clock = self._clock
	self._inFlight += 1
	entry.attempts += 1
	if request.write and request.key then
		self._writing[request.key] = true
		self._lastWriteAt[request.key] = clock:now()
	end
	local windows = self:_windowsFor(request)
	if windows then
		local kilobytes = Throughput.kilobytes(request.size :: number)
		windows.read:add(clock:now(), kilobytes)
		if request.write then
			windows.write:add(clock:now(), kilobytes)
		end
	end

	clock:spawn(function()
		local ran, outcome = pcall(request.run)
		local result: Types.Result<unknown> = if ran
			then outcome
			else { ok = false, error = { kind = "unknown", message = tostring(outcome) } }

		self._inFlight -= 1
		if request.write and request.key then
			self._writing[request.key] = nil
		end

		local retry = not result.ok
			and RETRYABLE[result.error.kind]
			and entry.attempts < self._config.maxAttempts
		if retry then
			entry.notBefore = clock:now() + self:_backoff(entry.attempts)
			table.insert(self._queue, entry)
		else
			self:_finish(entry, result)
		end
		self:_pump()
	end)
end

function Scheduler._armTimer(self: Scheduler, wakeAt: number)
	if self._timerAt and self._timerAt <= wakeAt then
		return
	end
	self._timerToken += 1
	local token = self._timerToken
	self._timerAt = wakeAt
	self._clock:delay(math.max(0, wakeAt - self._clock:now()), function()
		if token ~= self._timerToken then
			return
		end
		self._timerAt = nil
		self:_pump()
	end)
end

-- Starts everything that can start. Re-entrant calls (a request finishing synchronously mid
-- pump) fold into one more pass
function Scheduler._pump(self: Scheduler)
	if self._pumping then
		self._pumpAgain = true
		return
	end
	self._pumping = true
	repeat
		self._pumpAgain = false
		local wakeAt: number? = nil
		while self._inFlight < self._config.maxConcurrent do
			local index, nextWake = self:_pick(self._clock:now())
			wakeAt = nextWake
			if index == nil then
				break
			end
			self:_start(table.remove(self._queue, index) :: Entry)
		end
		if #self._queue > 0 and wakeAt then
			self:_armTimer(wakeAt)
		end
	until not self._pumpAgain
	self._pumping = false
end

--[=[
	Queues a request and yields until it settles, retries included. Errors other than
	throttling or internal failures come back right away

	@param request Request<T>
	@return Result<T>
]=]
function Scheduler.submit<T>(self: Scheduler, request: Request<T>): Types.Result<T>
	assert(RANKS[request.priority], `unknown priority {request.priority}`)
	assert(
		not (request.coalesce and request.write),
		"writes can't be coalesced, two writes are never the same request"
	)

	local id = request.coalesce
	local shared = if id then self._coalesced[id] else nil
	if shared then
		return shared:await() :: Types.Result<T>
	end

	self._seq += 1
	local now = self._clock:now()
	local entry: Entry = {
		seq = self._seq,
		request = request :: Request<unknown>,
		rank = RANKS[request.priority],
		enqueuedAt = now,
		notBefore = now,
		attempts = 0,
		future = Future.new(self._clock),
	}
	if id then
		self._coalesced[id] = entry.future
	end
	table.insert(self._queue, entry)
	self:_pump()
	return entry.future:await() :: Types.Result<T>
end

--[=[
	A snapshot of the queue for tooling
]=]
function Scheduler.stats(self: Scheduler): Stats
	local byPriority: { [string]: number } = {
		release = 0,
		save = 0,
		load = 0,
		read = 0,
		background = 0,
	}
	for _, entry in self._queue do
		local priority = entry.request.priority
		byPriority[priority] += 1
	end
	return {
		queued = #self._queue,
		inFlight = self._inFlight,
		queuedByPriority = byPriority,
	}
end

return Scheduler
