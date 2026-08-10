--!strict

-- Per key throughput over a rolling window. There's no fixed cooldown between writes to a
-- key: Roblox checks what each key read and wrote over the last 60s (25 MB reads, 4 MB
-- writes) and rounds every request up to the next KB

local Throughput = {}

Throughput.WINDOW = 60
Throughput.READ_LIMIT_KB = 25 * 1024
Throughput.WRITE_LIMIT_KB = 4 * 1024

type Use = { at: number, kilobytes: number }

type Fields = {
	limit: number,
	window: number,
	_uses: { Use },
	_total: number,
}

local Tracker = {}
Tracker.__index = Tracker

export type Tracker = typeof(setmetatable({} :: Fields, Tracker))

--[=[
	What a request of `bytes` costs. Every request costs at least one kilobyte
]=]
function Throughput.kilobytes(bytes: number): number
	return math.max(1, math.ceil(bytes / 1024))
end

--[=[
	A tracker for one key and one direction, with a limit in kilobytes per window
]=]
function Throughput.tracker(limit: number, window: number?): Tracker
	return setmetatable(
		{
			limit = limit,
			window = window or Throughput.WINDOW,
			_uses = {},
			_total = 0,
		} :: Fields,
		Tracker
	)
end

function Tracker._expire(self: Tracker, now: number)
	local uses = self._uses
	while uses[1] and uses[1].at + self.window <= now do
		self._total -= uses[1].kilobytes
		table.remove(uses, 1)
	end
end

--[=[
	Whether `kilobytes` more fit in the window now. If not, also returns when the oldest use
	leaves the window. A single request larger than the whole limit is let through once the
	window is empty, since no amount of waiting would make room for it
]=]
function Tracker.room(self: Tracker, now: number, kilobytes: number): (boolean, number?)
	self:_expire(now)
	if self._total == 0 or self._total + kilobytes <= self.limit then
		return true, nil
	end
	return false, self._uses[1].at + self.window
end

function Tracker.add(self: Tracker, now: number, kilobytes: number)
	self:_expire(now)
	table.insert(self._uses, { at = now, kilobytes = kilobytes })
	self._total += kilobytes
end

function Tracker.used(self: Tracker, now: number): number
	self:_expire(now)
	return self._total
end

return Throughput
