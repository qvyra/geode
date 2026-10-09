--!strict

-- Virtual time for tests. Nothing moves until `advance` or `run`, so timing heavy code runs
-- instantly and the same way every time. Plain coroutines, so Lune and Roblox behave alike

type Sleeper = {
	at: number,
	seq: number,
	thread: thread?,
	fn: (() -> ())?,
}

type Fields = {
	_now: number,
	_seq: number,
	_sleepers: { Sleeper },
	_owned: { [thread]: boolean },
}

local MockClock = {}
MockClock.__index = MockClock

export type MockClock = typeof(setmetatable({} :: Fields, MockClock))

local function resume(thread: thread)
	local ok, err = coroutine.resume(thread)
	if not ok then
		error(debug.traceback(thread, tostring(err)), 0)
	end
end

function MockClock.new(start: number?): MockClock
	local self: Fields = {
		_now = start or 0,
		_seq = 0,
		_sleepers = {},
		-- weak keys, finished threads can be collected
		_owned = setmetatable({}, { __mode = "k" }) :: any,
	}
	return setmetatable(self, MockClock)
end

function MockClock.now(self: MockClock): number
	return self._now
end

function MockClock._schedule(self: MockClock, seconds: number, thread: thread?, fn: (() -> ())?)
	self._seq += 1
	table.insert(self._sleepers, {
		at = self._now + math.max(seconds, 0),
		seq = self._seq,
		thread = thread,
		fn = fn,
	})
end

-- Only works inside a thread the clock started. Nothing else would ever resume it
function MockClock.wait(self: MockClock, seconds: number)
	local thread = coroutine.running()
	if not self._owned[thread] then
		error("MockClock:wait must run inside clock:spawn or clock:run", 2)
	end
	self:_schedule(seconds, thread, nil)
	coroutine.yield()
end

function MockClock.spawn(self: MockClock, fn: () -> ())
	local thread = coroutine.create(fn)
	self._owned[thread] = true
	resume(thread)
end

function MockClock.delay(self: MockClock, seconds: number, fn: () -> ())
	self:_schedule(seconds, nil, fn)
end

-- Like task.defer for a thread parked with coroutine.yield. It counts as a clock thread from
-- then on, so it's allowed to wait
function MockClock.resume(self: MockClock, thread: thread)
	self._owned[thread] = true
	self:_schedule(0, thread, nil)
end

function MockClock._popDue(self: MockClock, target: number): Sleeper?
	local bestIndex: number? = nil
	for index, sleeper in self._sleepers do
		if sleeper.at <= target then
			local best = if bestIndex then self._sleepers[bestIndex] else nil
			if
				best == nil
				or sleeper.at < best.at
				or (sleeper.at == best.at and sleeper.seq < best.seq)
			then
				bestIndex = index
			end
		end
	end
	if bestIndex == nil then
		return nil
	end
	return table.remove(self._sleepers, bestIndex)
end

-- wakes due sleepers in order
function MockClock.advance(self: MockClock, seconds: number)
	local target = self._now + seconds
	while true do
		local sleeper = self:_popDue(target)
		if sleeper == nil then
			break
		end
		self._now = math.max(self._now, sleeper.at)
		if sleeper.thread then
			resume(sleeper.thread)
		elseif sleeper.fn then
			self:spawn(sleeper.fn)
		end
	end
	self._now = target
end

function MockClock.pending(self: MockClock): number
	return #self._sleepers
end

-- Runs `fn` in a clock thread, jumping from one wake up to the next until it returns. Errors
-- if `fn` waits on something the clock will never wake
function MockClock.run<T...>(self: MockClock, fn: () -> T...): T...
	local done = false
	local results: { [number]: any, n: number }
	self:spawn(function()
		results = table.pack(fn()) :: any
		done = true
	end)
	while not done do
		local nextAt: number? = nil
		for _, sleeper in self._sleepers do
			if nextAt == nil or sleeper.at < nextAt then
				nextAt = sleeper.at
			end
		end
		if nextAt == nil then
			error("MockClock:run function is blocked with nothing scheduled to wake it", 2)
		end
		self:advance(nextAt - self._now)
	end
	return table.unpack(results, 1, results.n)
end

return MockClock
