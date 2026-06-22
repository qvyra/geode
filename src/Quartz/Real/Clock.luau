--!strict

local Types = require("../Types")

local RealClock = {}

--[=[
	Clock backed by the task library and wall time. Wall time is used over os.clock because lease
	timestamps get compared between servers
]=]
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

	return clock :: Types.Clock
end

return RealClock
