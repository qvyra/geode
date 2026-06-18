--!strict

local Context = require("./Context")
local Errors = require("../Errors")
local Types = require("../Types")

type Context = Context.Context

type Fields = {
	_context: Context,
}

local MockTeleport = {}
MockTeleport.__index = MockTeleport

export type MockTeleport = typeof(setmetatable({} :: Fields, MockTeleport))

local SERVICE = "teleport"

function MockTeleport.new(context: Context): MockTeleport
	return setmetatable({ _context = context } :: Fields, MockTeleport)
end

function MockTeleport.reserveServer(
	self: MockTeleport,
	placeId: number
): Types.Result<Types.ReservedServer>
	local err = Context.enter(self._context, SERVICE, tostring(placeId), "reserveServer", nil)
	if err then
		return Errors.failWith(err)
	end
	local id = Context.nextId(self._context.shared)
	return Errors.ok({ code = `reserved-{placeId}-{id}`, serverId = `server-{id}` })
end

--[=[
	Records the teleport in the universe for tests to assert on. Nobody actually moves
]=]
function MockTeleport.teleport(
	self: MockTeleport,
	placeId: number,
	players: { unknown },
	options: Types.TeleportOptions?
): Types.Result<nil>
	local err = Context.enter(self._context, SERVICE, tostring(placeId), "teleport", nil)
	if err then
		return Errors.failWith(err)
	end
	table.insert(self._context.shared.teleports, {
		fromJobId = self._context.jobId,
		placeId = placeId,
		players = table.clone(players),
		options = options,
	})
	return Errors.ok(nil)
end

return MockTeleport
