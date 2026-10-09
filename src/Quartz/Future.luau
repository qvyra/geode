--!strict

-- A value that arrives later. Waiters park with coroutine.yield and get resumed through the
-- clock, so real and mock clocks behave the same

local Types = require("./Types")

type Fields = {
	_clock: Types.Clock,
	_done: boolean,
	_value: unknown,
	_waiting: { thread },
}

local Future = {}
Future.__index = Future

export type Future = typeof(setmetatable({} :: Fields, Future))

function Future.new(clock: Types.Clock): Future
	local self: Fields = {
		_clock = clock,
		_done = false,
		_value = nil,
		_waiting = {},
	}
	return setmetatable(self, Future)
end

function Future.isDone(self: Future): boolean
	return self._done
end

-- settles once, later calls are ignored
function Future.resolve(self: Future, value: unknown)
	if self._done then
		return
	end
	self._done = true
	self._value = value
	local waiting = self._waiting
	self._waiting = {}
	for _, thread in waiting do
		self._clock:resume(thread)
	end
end

function Future.await(self: Future): unknown
	if not self._done then
		table.insert(self._waiting, coroutine.running())
		coroutine.yield()
	end
	return self._value
end

return Future
