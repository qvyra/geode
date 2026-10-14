--!strict

-- Studio bridge for development tools to read a running game. Opens through the services'
-- tooling bridge the first time a store is made in a Studio playtest, answers read only
-- requests and forwards every telemetry message. Answers are plain data since they cross a
-- Bindable

local Bus = require("./Bus")
local Registry = require("./Registry")
local Snapshot = require("./Snapshot")
local Types = require("../Quartz/Types")
local Version = require("../Version")

local Bridge = {}

-- bump whenever a request or answer changes shape, tools check it before reading anything
Bridge.VERSION = 1

type Opened = {
	connection: Types.BridgeConnection,
	telemetry: Types.Connection,
}

local enabled = true
-- weak keys, so a dropped mock server takes its bridge with it
local opened: { [Types.Services]: Opened } = setmetatable({}, { __mode = "k" }) :: any

local function profileStores(): { Registry.Entry }
	local stores = {}
	for _, entry in Registry.list() do
		if entry.kind == "profileStore" and entry.tooling then
			table.insert(stores, entry)
		end
	end
	return stores
end

local function answer(request: unknown): unknown
	if type(request) ~= "table" then
		return { error = "a request is a table with a kind" }
	end
	local fields = request :: { [string]: unknown }
	local kind = fields.kind
	if kind == "hello" then
		return { bridge = Bridge.VERSION, geode = Version, bus = Bus.VERSION }
	elseif kind == "snapshot" then
		return Snapshot.take()
	elseif kind == "profiles" then
		local stores = {}
		for _, entry in profileStores() do
			local tooling = entry.tooling :: Registry.Tooling
			table.insert(stores, { name = entry.name, keys = tooling.keys() })
		end
		return { stores = stores }
	elseif kind == "profile" then
		for _, entry in profileStores() do
			if entry.name == fields.store and type(fields.key) == "string" then
				local found = (entry.tooling :: Registry.Tooling).inspect(fields.key :: string)
				return if found == nil then { missing = true } else found
			end
		end
		return { missing = true }
	end
	return { error = `unknown request {tostring(kind)}` }
end

-- Opens the bridge on `services` if this is a Studio playtest and it isn't open yet.
-- Stores call it when they're made
function Bridge.ensure(services: Types.Services)
	if not enabled or opened[services] or not services.bridge:isAvailable() then
		return
	end
	local connection = services.bridge:open({
		BridgeVersion = Bridge.VERSION,
		GeodeVersion = Version,
	}, answer)
	opened[services] = {
		connection = connection,
		telemetry = Bus.subscribe(function(message: Bus.Message)
			connection:publish(message)
		end),
	}
end

function Bridge.setEnabled(on: boolean)
	enabled = on
	if on then
		return
	end
	for services, open in opened do
		open.telemetry:disconnect()
		open.connection:close()
		opened[services] = nil
	end
end

function Bridge.isEnabled(): boolean
	return enabled
end

return Bridge
