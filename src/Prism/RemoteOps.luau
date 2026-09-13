--!strict

-- Client intent. Clients never write state, they ask for a declared op by name and the
-- server runs it on their own profile with a player source, so every guard sees who asked.
-- Checks go cheapest first: attempt rate limit, then arguments, then the transaction
-- pipeline. Spam costs almost nothing

local Profile = require("../Sapphire/Profile")
local ProfileStore = require("../Sapphire/ProfileStore")
local RealServices = require("../Quartz/Real/Services")
local Schema = require("../Obsidian/Schema")
local Types = require("../Quartz/Types")
local Validate = require("../Obsidian/Validate")

export type RateLimit = {
	-- attempts allowed per player per window
	count: number,
	window: number,
	-- past the limit: "drop" ignores the request, "kick" removes the player
	action: ("drop" | "kick")?,
}

export type Options = {
	-- store holding the profiles this op changes (PlayerData passes its `store`)
	store: ProfileStore.ProfileStore,
	-- One schema per argument. Requests with other arguments get dropped
	args: { Schema.Schema }?,
	-- default 30 attempts per 10s, dropped past that
	rateLimit: RateLimit?,
	services: Types.Services?,
	reportError: ((message: string) -> ())?,
}

export type Outcome = "ran" | "rejected" | "limited" | "invalid" | "unknown" | "notLoaded"

type Defined = {
	store: ProfileStore.ProfileStore,
	args: { Schema.Schema },
	limit: RateLimit,
	attempts: { [number]: { number } },
}

type Dispatcher = {
	ops: { [string]: Defined },
	report: (message: string) -> (),
	-- (userId, op name, outcome) for every request. Tests and telemetry use it
	listeners: { (userId: number, name: string, outcome: Outcome) -> () },
}

local RemoteOps = {}

RemoteOps.REMOTE = "GeodeOps"

local DEFAULT_LIMIT: RateLimit = { count = 30, window = 10, action = "drop" }

-- one dispatcher per services table, so all ops of a game share one remote
local dispatchers: { [Types.Services]: Dispatcher } = setmetatable({}, { __mode = "k" }) :: any

local function allowed(defined: Defined, userId: number, now: number): boolean
	local window = defined.limit.window
	local list = defined.attempts[userId] or {}
	defined.attempts[userId] = list
	while list[1] and list[1] <= now - window do
		table.remove(list, 1)
	end
	if #list >= defined.limit.count then
		return false
	end
	table.insert(list, now)
	return true
end

local function handle(
	services: Types.Services,
	dispatcher: Dispatcher,
	userId: number,
	name: unknown,
	args: { n: number, [number]: unknown }
): Outcome
	if type(name) ~= "string" then
		return "unknown"
	end
	local defined = dispatcher.ops[name]
	if defined == nil then
		return "unknown"
	end

	if not allowed(defined, userId, services.clock:now()) then
		if defined.limit.action == "kick" then
			services.players:kick(userId, "Too many requests")
		end
		return "limited"
	end

	if args.n ~= #defined.args then
		return "invalid"
	end
	for index, schema in defined.args do
		if not Validate.validate(schema, args[index]).ok then
			return "invalid"
		end
	end

	-- unknown first, Luau won't compare the Profile class type with nil
	local found: unknown = defined.store:get(defined.store:keyForUser(userId))
	if found == nil then
		return "notLoaded"
	end
	local profile = found :: Profile.Profile
	if not profile:isActive() then
		return "notLoaded"
	end
	local result = profile:transact(function(tx)
		tx:op(name, table.unpack(args, 1, args.n))
	end, { source = { kind = "player", userId = userId } })
	return if result.ok then "ran" else "rejected"
end

local function dispatcherFor(services: Types.Services, report: (message: string) -> ()): Dispatcher
	local existing = dispatchers[services]
	if existing then
		return existing
	end
	local dispatcher: Dispatcher = { ops = {}, report = report, listeners = {} }
	dispatchers[services] = dispatcher
	services.remote(RemoteOps.REMOTE):onEvent(function(userId: number, name: unknown, ...: unknown)
		local outcome: Outcome = handle(services, dispatcher, userId, name, table.pack(...))
		for _, listener in dispatcher.listeners do
			listener(userId, if type(name) == "string" then name else "?", outcome)
		end
	end)
	return dispatcher
end

--[=[
	Lets clients request the op `name`. It must already be registered with Geode.op and enabled
	on the store. Requests run on the asking player's own profile, with a player source

	@within Geode
]=]
function RemoteOps.define(name: string, options: Options)
	local limit = options.rateLimit or DEFAULT_LIMIT
	assert(
		limit.count >= 1 and limit.window > 0,
		"the rate limit needs a positive count and window"
	)
	assert(
		limit.action == nil or limit.action == "drop" or limit.action == "kick",
		`rateLimit.action must be "drop" or "kick"`
	)
	local dispatcher = dispatcherFor(
		options.services or RealServices.live(),
		options.reportError or function(message: string)
			warn(message)
		end
	)
	assert(dispatcher.ops[name] == nil, `the remote op {name} is already defined`)
	dispatcher.ops[name] = {
		store = options.store,
		args = options.args or {},
		limit = limit,
		attempts = {},
	}
end

--[=[
	Calls back with every remote op request on `services` and how it ended
]=]
function RemoteOps.onRequest(
	services: Types.Services,
	listener: (userId: number, name: string, outcome: Outcome) -> ()
): Types.Connection
	local dispatcher = dispatcherFor(services, function(message: string)
		warn(message)
	end)
	table.insert(dispatcher.listeners, listener)
	return {
		disconnect = function(_self: Types.Connection)
			local index = table.find(dispatcher.listeners, listener)
			if index then
				table.remove(dispatcher.listeners, index)
			end
		end,
	}
end

return RemoteOps
