--!strict

-- Remote events between one mock server and its mock clients. Messages arrive on the next clock
-- step as copies, the way Roblox delivers them a frame later by value. A client only hears its
-- server while its player is on that server

local Context = require("./Context")
local Types = require("../Types")
local Values = require("./Values")

type Handler = (...any) -> ()

type Channel = {
	serverHandlers: { (userId: number, ...any) -> () },
	clientHandlers: { [number]: { Handler } },
}

type Fields = {
	_context: Context.Context,
	_channels: { [string]: Channel },
	_isPresent: (userId: number) -> boolean,
}

local MockRemotes = {}
MockRemotes.__index = MockRemotes

export type MockRemotes = typeof(setmetatable({} :: Fields, MockRemotes))

function MockRemotes.new(
	context: Context.Context,
	isPresent: (userId: number) -> boolean
): MockRemotes
	return setmetatable(
		{
			_context = context,
			_channels = {},
			_isPresent = isPresent,
		} :: Fields,
		MockRemotes
	)
end

function MockRemotes._channel(self: MockRemotes, name: string): Channel
	local channel = self._channels[name]
	if channel == nil then
		channel = { serverHandlers = {}, clientHandlers = {} }
		self._channels[name] = channel
	end
	return channel
end

local function connect<T>(list: { T }, handler: T): Types.Connection
	table.insert(list, handler)
	return {
		disconnect = function(_self: Types.Connection)
			local index = table.find(list, handler)
			if index then
				table.remove(list, index)
			end
		end,
	}
end

-- args are copied now and delivered on the next step
function MockRemotes._deliver(
	self: MockRemotes,
	handlers: { any },
	args: { n: number, [number]: any },
	before: { any }
)
	local copied = {}
	for index = 1, args.n do
		copied[index] = Values.clone(args[index])
	end
	local count = args.n
	self._context.shared.clock:delay(0, function()
		if not self._context.alive then
			return
		end
		for _, handler in table.clone(handlers) do
			local all = table.clone(before)
			for index = 1, count do
				all[#before + index] = copied[index]
			end
			handler(table.unpack(all, 1, #before + count))
		end
	end)
end

function MockRemotes.server(self: MockRemotes, name: string): Types.ServerRemote
	local channel = self:_channel(name)
	return {
		fire = function(_remote: Types.ServerRemote, userId: number, ...: any)
			if not self._isPresent(userId) then
				return
			end
			local handlers = channel.clientHandlers[userId]
			if handlers then
				self:_deliver(handlers, table.pack(...), {})
			end
		end,
		onEvent = function(_remote: Types.ServerRemote, handler: (userId: number, ...any) -> ())
			return connect(channel.serverHandlers, handler)
		end,
	}
end

function MockRemotes.client(self: MockRemotes, userId: number, name: string): Types.ClientRemote
	local channel = self:_channel(name)
	local handlers = channel.clientHandlers[userId] or {}
	channel.clientHandlers[userId] = handlers
	return {
		fire = function(_remote: Types.ClientRemote, ...: any)
			if not self._isPresent(userId) then
				return
			end
			self:_deliver(channel.serverHandlers, table.pack(...), { userId })
		end,
		onEvent = function(_remote: Types.ClientRemote, handler: Handler)
			return connect(handlers, handler)
		end,
	}
end

return MockRemotes
