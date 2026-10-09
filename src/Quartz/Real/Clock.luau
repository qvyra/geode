--!strict

local Types = require("../Types")

local RealClock = {}

-- task library + wall time. Not os.clock, since lease timestamps get compared across servers
function RealClock.new(): Types.Clock
	local clock = {}

	function clock.now(_self: Types.Clock): number
		return DateTime.now().UnixTimestampMillis / 1000
	end

	function clock.wait(_self: Types.Clock, seconds: number)
		task.wait(seconds)
	end

	function clock.spawn(_self: Types.Clock, fn: () -> ())
		task.spawn(fn)
	end

	function clock.delay(_self: Types.Clock, seconds: number, fn: () -> ())
		task.delay(seconds, fn)
	end

	function clock.resume(_self: Types.Clock, thread: thread)
		task.defer(thread)
	end

	return clock :: Types.Clock
end

return RealClock
