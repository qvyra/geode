--!strict

-- Players and purchases on one mock server. Tests drive joins, leaves and purchases, and
-- the adapters report them the way Players and MarketplaceService would

local Context = require("./Context")
local Types = require("../Types")

export type MockPlayer = {
	UserId: number,
	Name: string,
}

type Handler = (userId: number, player: unknown) -> ()

type Fields = {
	_context: Context.Context,
	_present: { [number]: MockPlayer },
	_order: { number },
	_joinHandlers: { Handler },
	_leaveHandlers: { Handler },
	_processReceipt: ((info: unknown) -> unknown)?,
}

local MockPlayers = {}
MockPlayers.__index = MockPlayers

export type MockPlayers = typeof(setmetatable({} :: Fields, MockPlayers))

function MockPlayers.new(context: Context.Context): MockPlayers
	return setmetatable(
		{
			_context = context,
			_present = {},
			_order = {},
			_joinHandlers = {},
			_leaveHandlers = {},
			_processReceipt = nil,
		} :: Fields,
		MockPlayers
	)
end

local function connect(list: { Handler }, handler: Handler): Types.Connection
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

local function fire(self: MockPlayers, list: { Handler }, userId: number, player: unknown)
	local clock = self._context.shared.clock
	for _, handler in table.clone(list) do
		clock:spawn(function()
			handler(userId, player)
		end)
	end
end

--// adapter

function MockPlayers.kick(self: MockPlayers, userId: number, reason: string): Types.Result<nil>
	table.insert(
		self._context.shared.kicks,
		{ jobId = self._context.jobId, userId = userId, reason = reason }
	)
	self:leave(userId)
	return { ok = true, value = nil }
end

function MockPlayers.onJoin(self: MockPlayers, handler: Handler): Types.Connection
	return connect(self._joinHandlers, handler)
end

function MockPlayers.onLeave(self: MockPlayers, handler: Handler): Types.Connection
	return connect(self._leaveHandlers, handler)
end

function MockPlayers.list(self: MockPlayers): { Types.PlayerEntry }
	local entries = {}
	for _, userId in self._order do
		table.insert(entries, { userId = userId, player = self._present[userId] })
	end
	return entries
end

function MockPlayers.isPresent(self: MockPlayers, userId: number): boolean
	return self._present[userId] ~= nil
end

function MockPlayers.setProcessReceipt(self: MockPlayers, callback: (info: unknown) -> unknown)
	self._processReceipt = callback
end

--// test controls

--[=[
	Brings a player into the server and returns the player object handlers receive
]=]
function MockPlayers.join(self: MockPlayers, userId: number, name: string?): MockPlayer
	local existing = self._present[userId]
	if existing then
		return existing
	end
	local player = { UserId = userId, Name = name or `Player{userId}` }
	self._present[userId] = player
	table.insert(self._order, userId)
	fire(self, self._joinHandlers, userId, player)
	return player
end

function MockPlayers.leave(self: MockPlayers, userId: number)
	local player = self._present[userId]
	if player == nil then
		return
	end
	self._present[userId] = nil
	table.remove(self._order, table.find(self._order, userId) :: number)
	fire(self, self._leaveHandlers, userId, player)
end

--[=[
	Runs the ProcessReceipt callback as a purchase would and returns its decision, or nil when
	no callback is set. Yields while the callback runs
]=]
function MockPlayers.purchase(self: MockPlayers, info: unknown): unknown
	local callback = self._processReceipt
	if callback == nil then
		return nil
	end
	return callback(info)
end

return MockPlayers
