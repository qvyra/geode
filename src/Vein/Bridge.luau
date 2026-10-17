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

-- The protocol this bridge speaks. Bump it when a request or answer changes shape in a way old
-- tools can't read. New requests that old tools never send don't need a bump, they show up in
-- FEATURES instead
Bridge.VERSION = 1
-- The oldest protocol a tool can still use with this bridge
Bridge.MIN_VERSION = 1

-- What this bridge can do. Tools decide what to show from this, not from version numbers
Bridge.FEATURES = table.freeze({
	-- snapshot, profiles and profile requests
	"read",
	-- every telemetry message forwarded on the Telemetry event
	"telemetry",
	-- guardBroken telemetry
	"guards",
	-- the ops request
	"ops",
	-- the schemaAt request
	"schema",
	-- the apply request
	"edit",
	-- apply with dryRun = true: what an edit would change and which guards it would break
	"dryRun",
	-- profileCommitted telemetry, one message per profile commit
	"commits",
})

type Opened = {
	connection: Types.BridgeConnection,
	telemetry: Types.Connection,
}

local enabled = true
-- weak keys, so a dropped mock server takes its bridge with it
local opened: { [Types.Services]: Opened } = setmetatable({}, { __mode = "k" }) :: any

local function profileStores(services: Types.Services): { Registry.Entry }
	local stores = {}
	for _, entry in Registry.list() do
		local tooling = entry.tooling
		local owner = tooling and tooling.services
		if entry.kind == "profileStore" and tooling and (owner == nil or owner == services) then
			table.insert(stores, entry)
		end
	end
	return stores
end

local function storeTooling(services: Types.Services, name: unknown): Registry.Tooling?
	for _, entry in profileStores(services) do
		if entry.name == name then
			return entry.tooling
		end
	end
	return nil
end

local function answer(services: Types.Services, request: unknown): unknown
	if type(request) ~= "table" then
		return { error = "a request is a table with a kind" }
	end
	local fields = request :: { [string]: unknown }
	local kind = fields.kind
	if kind == "hello" then
		local protocol = fields.protocol
		local refused: string? = nil
		if protocol ~= nil and (type(protocol) ~= "number" or protocol < Bridge.MIN_VERSION) then
			refused =
				`this game's Geode needs a tool on bridge protocol {Bridge.MIN_VERSION} or newer`
		elseif protocol ~= nil and protocol > Bridge.VERSION then
			refused =
				`this game's Geode only speaks bridge protocol up to {Bridge.VERSION}, update Geode`
		end
		if refused then
			return { error = refused, bridge = Bridge.VERSION, minBridge = Bridge.MIN_VERSION }
		end
		return {
			bridge = Bridge.VERSION,
			minBridge = Bridge.MIN_VERSION,
			geode = Version,
			bus = Bus.VERSION,
			features = table.clone(Bridge.FEATURES),
		}
	elseif kind == "snapshot" then
		return Snapshot.take()
	elseif kind == "profiles" then
		local stores = {}
		for _, entry in profileStores(services) do
			local tooling = entry.tooling :: Registry.Tooling
			table.insert(
				stores,
				{ name = entry.name, keys = tooling.keys(), studio = tooling.studio }
			)
		end
		return { stores = stores }
	elseif kind == "profile" then
		for _, entry in profileStores(services) do
			if entry.name == fields.store and type(fields.key) == "string" then
				local found = (entry.tooling :: Registry.Tooling).inspect(fields.key :: string)
				return if found == nil then { missing = true } else found
			end
		end
		return { missing = true }
	elseif kind == "ops" or kind == "schemaAt" or kind == "apply" then
		local tooling = storeTooling(services, fields.store)
		if tooling == nil then
			return { error = `no profile store named {tostring(fields.store)}` }
		end
		if kind == "ops" and tooling.ops then
			return { ops = tooling.ops() }
		elseif kind == "schemaAt" and tooling.schemaAt then
			return tooling.schemaAt(fields.path)
		elseif kind == "apply" and tooling.apply then
			if type(fields.key) ~= "string" or type(fields.op) ~= "string" then
				return {
					ok = false,
					error = { kind = "badArgs", message = "apply needs a key and an op" },
				}
			end
			local args = if type(fields.args) == "table" then fields.args :: { unknown } else {}
			local note = if type(fields.note) == "string" then fields.note else ""
			return tooling.apply(
				fields.key :: string,
				fields.op :: string,
				args,
				note,
				{ dryRun = fields.dryRun == true }
			)
		end
		return { error = `this store doesn't support {kind}` }
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
		BridgeMinVersion = Bridge.MIN_VERSION,
		GeodeVersion = Version,
	}, function(request: unknown): unknown
		return answer(services, request)
	end)
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
