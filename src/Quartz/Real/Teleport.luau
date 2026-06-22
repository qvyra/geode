--!strict

local Errors = require("../Errors")
local RobloxApi = require("./RobloxApi")
local Types = require("../Types")

type Fields = {
	_service: TeleportService,
	_api: RobloxApi.RobloxApi,
}

local RealTeleport = {}
RealTeleport.__index = RealTeleport

export type RealTeleport = typeof(setmetatable({} :: Fields, RealTeleport))

function RealTeleport.new(service: TeleportService, api: RobloxApi.RobloxApi): RealTeleport
	return setmetatable({ _service = service, _api = api } :: Fields, RealTeleport)
end

function RealTeleport.reserveServer(
	self: RealTeleport,
	placeId: number
): Types.Result<Types.ReservedServer>
	local ok, code, serverId = pcall(function(): (string, string)
		local accessCode, privateServerId = self._service:ReserveServer(placeId)
		return accessCode, privateServerId
	end)
	if not ok then
		return Errors.failWith(Errors.classify(code))
	end
	return Errors.ok({ code = code, serverId = serverId })
end

function RealTeleport.teleport(
	self: RealTeleport,
	placeId: number,
	players: { unknown },
	options: Types.TeleportOptions?
): Types.Result<nil>
	local teleportOptions = if options
		then self._api.newTeleportOptions(options.reservedServerCode, options.data)
		else nil
	local ok, err = pcall(function()
		self._service:TeleportAsync(placeId, players :: { Player }, teleportOptions)
	end)
	if not ok then
		return Errors.failWith(Errors.classify(err))
	end
	return Errors.ok(nil)
end

return RealTeleport
