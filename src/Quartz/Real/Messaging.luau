--!strict

local Errors = require("../Errors")
local Types = require("../Types")

type Fields = {
	_service: MessagingService,
}

local RealMessaging = {}
RealMessaging.__index = RealMessaging

export type RealMessaging = typeof(setmetatable({} :: Fields, RealMessaging))

function RealMessaging.new(service: MessagingService): RealMessaging
	return setmetatable({ _service = service } :: Fields, RealMessaging)
end

function RealMessaging.publish(self: RealMessaging, topic: string, data: unknown): Types.Result<nil>
	local ok, err = pcall(function()
		self._service:PublishAsync(topic, data)
	end)
	if not ok then
		return Errors.failWith(Errors.classify(err))
	end
	return Errors.ok(nil)
end

function RealMessaging.subscribe(
	self: RealMessaging,
	topic: string,
	handler: Types.MessageHandler
): Types.Result<Types.Connection>
	local ok, connectionOrError = pcall(function()
		return self._service:SubscribeAsync(
			topic,
			function(message: { Data: unknown, Sent: number })
				handler(message.Data, message.Sent)
			end
		)
	end)
	if not ok then
		return Errors.failWith(Errors.classify(connectionOrError))
	end
	local robloxConnection = connectionOrError :: RBXScriptConnection
	local connection: Types.Connection = {
		disconnect = function()
			robloxConnection:Disconnect()
		end,
	}
	return Errors.ok(connection)
end

return RealMessaging
