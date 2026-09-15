--!strict

-- Telemetry bus. Everything tooling should know about goes out here as a versioned message:
-- `{ v = 1, type = "...", at = seconds, ... }`. Fields are only added within a version, so a
-- consumer written for v1 keeps working until the version changes

local Signal = require("../Quartz/Signal")
local Types = require("../Quartz/Types")

export type Message = { [string]: unknown }

local Bus = {}

Bus.VERSION = 1

local signal = Signal.new(function(message: string)
	warn(message)
end)

--[=[
	Publishes a message of `kind` with `fields`. Costs next to nothing when nobody listens
]=]
-- fields typed loosely, Luau won't match a literal record against a map of unknowns
function Bus.publish(kind: string, fields: { [string]: any }?, at: number?)
	if signal:handlerCount() == 0 then
		return
	end
	local message: Message = if fields then table.clone(fields) else {}
	message.v = Bus.VERSION
	message.type = kind
	message.at = at or os.time()
	signal:fire(table.freeze(message))
end

--[=[
	Calls back with every message from now on
]=]
function Bus.subscribe(callback: (message: Message) -> ()): Types.Connection
	return signal:connect(callback)
end

return Bus
