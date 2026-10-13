--!strict

-- Tooling bridge on a mock server. Tests send requests and read published messages like a
-- Studio plugin would. Copies are strict on purpose: a Bindable mangles mixed and sparse
-- tables, so the mock refuses them and a test catches payloads that wouldn't survive

local Types = require("../Types")

type Fields = {
	_available: boolean,
	_handler: Types.BridgeHandler?,
	_attributes: { [string]: string | number }?,
	_messages: { unknown },
}

local MockBridge = {}
MockBridge.__index = MockBridge

export type MockBridge = typeof(setmetatable({} :: Fields, MockBridge))

function MockBridge.new(available: boolean): MockBridge
	return setmetatable(
		{
			_available = available,
			_handler = nil,
			_attributes = nil,
			_messages = {},
		} :: Fields,
		MockBridge
	)
end

-- Copies a value the way a Bindable has to: plain values, arrays without holes, string-keyed
-- tables. Anything else errors with the path where it broke
function MockBridge.copy(value: unknown, path: string?): unknown
	local at = path or "value"
	local kind = type(value)
	if kind == "nil" or kind == "boolean" or kind == "number" or kind == "string" then
		return value
	end
	if kind ~= "table" then
		error(`{at} is a {typeof(value)}, which can't cross a Bindable`, 0)
	end
	local source = value :: { [unknown]: unknown }
	local count = 0
	local stringKeys = 0
	for key in source do
		count += 1
		if type(key) == "string" then
			stringKeys += 1
		end
	end
	local copy = {}
	if stringKeys == count then
		for key, child in source do
			copy[key] = MockBridge.copy(child, `{at}.{key}`)
		end
		return copy
	end
	if stringKeys > 0 or count ~= #(source :: { unknown }) then
		error(`{at} mixes key types or has holes, which a Bindable would mangle`, 0)
	end
	for index, child in ipairs(source :: { unknown }) do
		copy[index] = MockBridge.copy(child, `{at}[{index}]`)
	end
	return copy
end

--// adapter

function MockBridge.isAvailable(self: MockBridge): boolean
	return self._available
end

function MockBridge.open(
	self: MockBridge,
	attributes: { [string]: string | number },
	handler: Types.BridgeHandler
): Types.BridgeConnection
	self._handler = handler
	self._attributes = table.clone(attributes)
	return {
		publish = function(_connection: Types.BridgeConnection, message: unknown)
			table.insert(self._messages, MockBridge.copy(message, "message"))
		end,
		close = function(_connection: Types.BridgeConnection)
			self._handler = nil
			self._attributes = nil
		end,
	}
end

--// test controls

-- nil when closed, otherwise its attributes
function MockBridge.attributes(self: MockBridge): { [string]: string | number }?
	return self._attributes
end

-- sends a request like a plugin would. Both directions get copied across the bridge
function MockBridge.request(self: MockBridge, request: unknown): unknown
	local handler = self._handler
	assert(handler, "the bridge isn't open")
	return MockBridge.copy(handler(MockBridge.copy(request, "request")), "answer")
end

function MockBridge.messages(self: MockBridge): { unknown }
	return table.clone(self._messages)
end

return MockBridge
