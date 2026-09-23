--!strict

-- Leaderboards. All-time boards live in an OrderedDataStore and last forever. Windowed ones
-- (daily, weekly or any length) get a MS sorted map per window that expires a grace period
-- after the window closes. Top N reads are cached so a busy lobby doesn't burn quota

local RealServices = require("../Quartz/Real/Services")
local Registry = require("../Vein/Registry")
local Scheduler = require("../Quartz/Scheduler")
local Types = require("../Quartz/Types")

export type Mode = "max" | "min" | "sum" | "latest"
export type Window = "daily" | "weekly" | number

export type Options = {
	-- How a new score combines with the stored one. Defaults to "max"
	mode: Mode?,
	-- Seconds a top list is served from cache. Defaults to 30
	cacheTtl: number?,
	services: Types.Services?,
	scheduler: Scheduler.Scheduler?,
}

-- Spelled out rather than built on Options, so a literal `window = "daily"` type checks
export type WindowedOptions = {
	mode: Mode?,
	cacheTtl: number?,
	services: Types.Services?,
	scheduler: Scheduler.Scheduler?,
	-- "daily" and "weekly" follow UTC, with weeks starting on Monday. A number is a length in
	-- seconds counted from the Unix epoch
	window: Window,
	-- Seconds a closed window stays readable. Defaults to one hour
	grace: number?,
}

export type Entry = {
	userId: number,
	score: number,
}

type Fields = {
	name: string,
	_services: Types.Services,
	_scheduler: Scheduler.Scheduler,
	_mode: Mode,
	_cacheTtl: number,
	_ordered: Types.OrderedDataStore?,
	_window: number?,
	_offset: number,
	_grace: number,
	_cache: { [string]: { at: number, entries: { Entry } } },
	_handle: Registry.Handle,
}

local Leaderboard = {}
Leaderboard.__index = Leaderboard

export type Leaderboard = typeof(setmetatable({} :: Fields, Leaderboard))

local DAY = 86400
local WEEK = 7 * DAY
-- The Unix epoch fell on a Thursday, so weeks starting Monday begin 4 days into it
local MONDAY_OFFSET = 4 * DAY
-- 45 days, the longest a MemoryStore item may live
local MAX_TTL = 3888000
-- The most one GetRangeAsync returns, and the most GetSortedAsync returns per page
local MAX_TOP = 100

-- ordered UpdateAsync both reads and writes, so it waits on both budgets
local ORDERED_UPDATE_BUDGET: { Types.BudgetType } = { "orderedRead", "orderedWrite" }

local Ranked = {}

local function combine(mode: Mode, current: number?, score: number): number?
	if current == nil then
		return score
	elseif mode == "max" then
		return if score > current then score else nil
	elseif mode == "min" then
		return if score < current then score else nil
	elseif mode == "sum" then
		return current + score
	end
	return score
end

local function new(name: string, options: Options?): Leaderboard
	assert(type(name) == "string" and name ~= "", "a leaderboard needs a name")
	local services = options and options.services or RealServices.live()
	return setmetatable(
		{
			name = name,
			_services = services,
			_scheduler = options and options.scheduler
				or Scheduler.new({ clock = services.clock, budget = services.budget }),
			_mode = options and options.mode or "max",
			_cacheTtl = options and options.cacheTtl or 30,
			_ordered = nil,
			_window = nil,
			_offset = 0,
			_grace = 3600,
			_cache = {},
			_handle = nil :: any,
		} :: Fields,
		Leaderboard
	)
end

--[=[
	A board that never resets, on an OrderedDataStore. Scores must be whole numbers

	@within Ranked
]=]
function Ranked.allTime(name: string, options: Options?): Leaderboard
	local board = new(name, options)
	board._ordered = board._services.orderedDataStore(name)
	board._handle = Registry.register("leaderboard", name, function()
		return { kind = "allTime", mode = board._mode }
	end)
	return board
end

--[=[
	A board that starts over every window, on MemoryStore sorted maps

	@within Ranked
]=]
function Ranked.windowed(name: string, options: WindowedOptions): Leaderboard
	local board = new(name, options)
	local window = options.window
	if window == "daily" then
		board._window = DAY
	elseif window == "weekly" then
		board._window = WEEK
		board._offset = MONDAY_OFFSET
	else
		assert(
			type(window) == "number" and window > 0,
			"window must be daily, weekly or a positive number of seconds"
		)
		board._window = window
	end
	board._grace = options.grace or 3600
	board._handle = Registry.register("leaderboard", name, function()
		return { kind = "windowed", window = board._window, mode = board._mode }
	end)
	return board
end

--// windows

--[=[
	The index of the window that holds time `at`, or of the current one
]=]
function Leaderboard.windowIndex(self: Leaderboard, at: number?): number
	local window = self._window :: number
	local now = at or self._services.clock:now()
	return math.floor((now - self._offset) / window)
end

function Leaderboard._windowMap(self: Leaderboard, index: number): Types.SortedMap
	return self._services.sortedMap(`geode_rank_{self.name}_{index}`)
end

function Leaderboard._windowTtl(self: Leaderboard, index: number): number
	local window = self._window :: number
	local closesAt = (index + 1) * window + self._offset
	local ttl = closesAt + self._grace - self._services.clock:now()
	return math.clamp(math.ceil(ttl), 1, MAX_TTL)
end

-- Scores

--[=[
	Records a score and returns what's on the board now. `mode` overrides the board's mode for
	just this submit
]=]
function Leaderboard.submit(
	self: Leaderboard,
	userId: number,
	score: number,
	mode: Mode?
): Types.Result<number>
	local how: Mode = mode or self._mode
	local key = tostring(userId)
	local ordered = self._ordered
	if ordered then
		assert(score % 1 == 0, "all-time boards store whole numbers")
		if how == "sum" then
			return self._scheduler:submit({
				priority = "save",
				budget = "orderedWrite",
				run = function()
					return ordered:increment(key, score)
				end,
			})
		end
		local result = self._scheduler:submit({
			priority = "save",
			budget = ORDERED_UPDATE_BUDGET,
			run = function()
				return ordered:update(key, function(current: number?): number?
					return combine(how, current, score)
				end)
			end,
		})
		if not result.ok then
			return { ok = false, error = result.error }
		end
		return { ok = true, value = result.value.value :: number }
	end

	local index = self:windowIndex()
	local map = self:_windowMap(index)
	local ttl = self:_windowTtl(index)
	local result = self._scheduler:submit({
		priority = "save",
		run = function()
			return map:update(key, function(current: unknown): (unknown, Types.SortKey?)
				local stored = if type(current) == "number" then current else nil
				local nextScore = combine(how, stored, score)
				if nextScore == nil then
					return nil, nil
				end
				return nextScore, nextScore
			end, ttl)
		end,
	})
	if not result.ok then
		return { ok = false, error = result.error }
	end
	return { ok = true, value = result.value.value :: number }
end

--[=[
	A player's score on the board, or nil
]=]
function Leaderboard.get(self: Leaderboard, userId: number): Types.Result<number?>
	local key = tostring(userId)
	local ordered = self._ordered
	if ordered then
		return self._scheduler:submit({
			priority = "read",
			budget = "orderedRead",
			run = function()
				return ordered:get(key)
			end,
		})
	end
	local map = self:_windowMap(self:windowIndex())
	local result = self._scheduler:submit({
		priority = "read",
		run = function()
			return map:get(key)
		end,
	})
	if not result.ok then
		return { ok = false, error = result.error }
	end
	local entry = result.value
	return { ok = true, value = if entry then entry.value :: number else nil }
end

--[=[
	The best `count` entries, best first. Lowest scores count as best on a "min" board. Served
	from cache while it's fresh. `windowIndex` reads an earlier window that hasn't expired yet
]=]
function Leaderboard.top(
	self: Leaderboard,
	count: number,
	windowIndex: number?
): Types.Result<{ Entry }>
	assert(count >= 1 and count <= MAX_TOP, `count must be from 1 to {MAX_TOP}`)
	local index = if self._ordered then 0 else windowIndex or self:windowIndex()
	local cacheKey = `{index}:{count}`
	local now = self._services.clock:now()
	local cached = self._cache[cacheKey]
	if cached and now - cached.at < self._cacheTtl then
		return { ok = true, value = cached.entries }
	end

	local ascending = self._mode == "min"
	local entries: { Entry } = {}
	local ordered = self._ordered
	if ordered then
		local result = self._scheduler:submit({
			priority = "read",
			budget = "orderedList",
			run = function()
				return ordered:getSorted({ ascending = ascending, limit = count })
			end,
		})
		if not result.ok then
			return { ok = false, error = result.error }
		end
		for _, entry in result.value do
			table.insert(entries, { userId = tonumber(entry.key) :: number, score = entry.value })
		end
	else
		local map = self:_windowMap(index)
		local result = self._scheduler:submit({
			priority = "read",
			run = function()
				return map:getRange({ count = count, descending = not ascending })
			end,
		})
		if not result.ok then
			return { ok = false, error = result.error }
		end
		for _, entry in result.value do
			table.insert(
				entries,
				{ userId = tonumber(entry.key) :: number, score = entry.value :: number }
			)
		end
	end
	table.freeze(entries)
	self._cache[cacheKey] = { at = now, entries = entries }
	return { ok = true, value = entries }
end

--[=[
	Unregisters the board from the registry tooling reads

	@within Leaderboard
]=]
function Leaderboard.destroy(self: Leaderboard)
	self._handle:unregister()
end

return Ranked
