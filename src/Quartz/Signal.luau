--!strict

-- Minimal event. Handlers run in connection order; one that errors gets reported and the
-- rest still run

local Types = require("./Types")

type Handler = {
	callback: (...any) -> (),
	connected: boolean,
}

type Fields = {
	_handlers: { Handler },
	_reportError: (message: string) -> (),
}

local Signal = {}
Signal.__index = Signal

export type Signal = typeof(setmetatable({} :: Fields, Signal))

function Signal.new(reportError: ((message: string) -> ())?): Signal
	local self: Fields = {
		_handlers = {},
		_reportError = reportError or function(message: string)
			warn(message)
		end,
	}
	return setmetatable(self, Signal)
end

function Signal.connect(self: Signal, callback: (...any) -> ()): Types.Connection
	local handler: Handler = { callback = callback, connected = true }
	table.insert(self._handlers, handler)
	return {
		disconnect = function()
			handler.connected = false
			local index = table.find(self._handlers, handler)
			if index then
				table.remove(self._handlers, index)
			end
		end,
	}
end

function Signal.fire(self: Signal, ...: any)
	local args = table.pack(...)
	for _, handler in table.clone(self._handlers) do
		if not handler.connected then
			continue
		end
		local ok, err = pcall(function()
			handler.callback(table.unpack(args, 1, args.n))
		end)
		if not ok then
			self._reportError(`signal handler error: {tostring(err)}`)
		end
	end
end

function Signal.handlerCount(self: Signal): number
	return #self._handlers
end

return Signal
