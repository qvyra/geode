--!strict

local Context = require("./Context")
local Errors = require("../Errors")
local Types = require("../Types")
local Values = require("./Values")

type Context = Context.Context

type Fields = {
	_context: Context,
}

local MockMessaging = {}
MockMessaging.__index = MockMessaging

export type MockMessaging = typeof(setmetatable({} :: Fields, MockMessaging))

local SERVICE = "messaging"

function MockMessaging.new(context: Context): MockMessaging
	return setmetatable({ _context = context } :: Fields, MockMessaging)
end

function MockMessaging.publish(self: MockMessaging, topic: string, data: unknown): Types.Result<nil>
	local err = Context.enter(self._context, SERVICE, topic, "publish", nil)
	if err then
		return Errors.failWith(err)
	end
	local ok, copy = Values.copy(data)
	if not ok then
		return Errors.fail("invalidValue", tostring(copy))
	end
	local sizeError = Context.checkSize(self._context.shared, copy)
	if sizeError then
		return Errors.failWith(sizeError)
	end

	local shared = self._context.shared
	local sentAt = shared.clock:now()
	local subscriptions: { Context.Subscription } = shared.topics[topic] or {}
	for _, subscription in subscriptions do
		shared.clock:delay(shared.messagingLatency, function()
			if subscription.connected and subscription.isAlive() then
				subscription.handler(Values.clone(copy), sentAt)
			end
		end)
	end
	return Errors.ok(nil)
end

function MockMessaging.subscribe(
	self: MockMessaging,
	topic: string,
	handler: Types.MessageHandler
): Types.Result<Types.Connection>
	local err = Context.enter(self._context, SERVICE, topic, "subscribe", nil)
	if err then
		return Errors.failWith(err)
	end
	local shared = self._context.shared
	local context = self._context
	local subscription: Context.Subscription = {
		jobId = context.jobId,
		handler = handler,
		connected = true,
		isAlive = function()
			return context.alive
		end,
	}
	shared.topics[topic] = shared.topics[topic] or {}
	table.insert(shared.topics[topic], subscription)

	local connection: Types.Connection = {
		disconnect = function()
			subscription.connected = false
		end,
	}
	return Errors.ok(connection)
end

return MockMessaging
