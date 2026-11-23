--!strict

-- Where a store's data lives in Studio. `Geode.setup` sets one mode and one scope that every
-- store starts from, and a store's own options still win. Live servers always use the services
-- they're given
--
-- "mock" takes DataStore, MemoryStore and messaging from one in-memory server per services
-- table, on the real clock. "scope" keeps the real services and keeps Studio apart: stores put
-- their DataStore data under a studio_ scope, and MemoryStore names and messaging topics get a
-- studio_ prefix, so a Studio session never talks to live servers. "real" uses live data.
-- "auto" checks API access once and picks "scope" with it, "mock" without. A store that isn't
-- given a mode, with none from Geode.setup either, uses "mock", so a playtest only reaches live
-- data when the game asks for it

local Universe = require("./Mock/Universe")
local Types = require("./Types")

export type Mode = "mock" | "scope" | "real" | "auto"
-- What a store ends up using. "auto" always settles on one of these
export type Resolved = "mock" | "scope" | "real"

local Studio = {}

local MODES: { [string]: boolean } = { mock = true, scope = true, real = true, auto = true }
local DEFAULT_MODE: Mode = "mock"

-- A cheap read nothing ever writes
local PROBE_STORE = "geode_studio_access"
local PROBE_KEY = "probe"
local PREFIX = "studio_"

type Probe = {
	done: boolean,
	mode: Resolved,
	waiting: { thread },
}

type State = {
	mode: Mode?,
	scope: string?,
	used: boolean,
	-- keyed by the services table a store was given, weakly, so they go with it
	memory: { [Types.Services]: Types.Services },
	apart: { [Types.Services]: Types.Services },
	probes: { [Types.Services]: Probe },
	-- services tables this module built, which pass through untouched. A matchmaker hands its
	-- services to its mutex, and that mutex must not get a second memory server
	built: { [Types.Services]: Resolved },
}

local function weak<K, V>(): { [K]: V }
	return setmetatable({}, { __mode = "k" }) :: any
end

local function fresh(): State
	return {
		mode = nil,
		scope = nil,
		used = false,
		memory = weak(),
		apart = weak(),
		probes = weak(),
		built = weak(),
	}
end

local state = fresh()

-- Fails unless `mode` is nil or one of the four modes
function Studio.check(mode: unknown)
	assert(
		mode == nil or (type(mode) == "string" and MODES[mode]),
		`studio must be "mock", "scope", "real" or "auto", got {tostring(mode)}`
	)
end

-- Fails unless `scope` is nil or a non-empty string
function Studio.checkScope(scope: unknown)
	assert(
		scope == nil or (type(scope) == "string" and scope ~= ""),
		"scope must be a non-empty string"
	)
end

-- Geode.setup's mode and scope, nil when it didn't set them
function Studio.setDefaults(mode: Mode?, scope: string?)
	Studio.check(mode)
	Studio.checkScope(scope)
	state.mode = mode
	state.scope = scope
end

-- The mode a store uses: its own, else Geode.setup's, else "mock"
function Studio.mode(given: Mode?): Mode
	return given or state.mode or DEFAULT_MODE
end

function Studio.defaultScope(): string?
	return state.scope
end

-- Whether any store resolved its services yet, so a late Geode.setup can say it came too late
function Studio.wasUsed(): boolean
	return state.used
end

-- The scope a store's DataStore data goes under
function Studio.scope(scope: string?, resolved: Resolved): string
	local base = scope or state.scope or "global"
	if resolved == "scope" then
		return `{PREFIX}{base}`
	end
	return base
end

local function memory(services: Types.Services): Types.Services
	local cached = state.memory[services]
	if cached then
		return cached
	end
	local universe = Universe.new({ clock = services.clock :: any })
	local mock =
		universe:server({ jobId = services.jobId, placeId = services.placeId, studio = true })
	-- Only the data lives in memory. Players, purchases, shutdown, teleports, remotes and the
	-- bridge stay real. The budget is the mock's, since these requests never reach Roblox
	local mixed = table.clone(services)
	mixed.dataStore = mock.dataStore
	mixed.orderedDataStore = mock.orderedDataStore
	mixed.hashMap = mock.hashMap
	mixed.sortedMap = mock.sortedMap
	mixed.queue = mock.queue
	mixed.messaging = mock.messaging
	mixed.budget = mock.budget
	state.memory[services] = mixed
	state.built[mixed] = "mock"
	return mixed
end

local function apart(services: Types.Services): Types.Services
	local cached = state.apart[services]
	if cached then
		return cached
	end
	local messaging = services.messaging
	local wrapped = table.clone(services)
	wrapped.hashMap = function(name: string): Types.HashMap
		return services.hashMap(`{PREFIX}{name}`)
	end
	wrapped.sortedMap = function(name: string): Types.SortedMap
		return services.sortedMap(`{PREFIX}{name}`)
	end
	wrapped.queue = function(name: string, invisibilityTimeout: number?): Types.Queue
		return services.queue(`{PREFIX}{name}`, invisibilityTimeout)
	end
	wrapped.messaging = {
		publish = function(_self: Types.Messaging, topic: string, data: unknown)
			return messaging:publish(`{PREFIX}{topic}`, data)
		end,
		subscribe = function(_self: Types.Messaging, topic: string, handler: Types.MessageHandler)
			return messaging:subscribe(`{PREFIX}{topic}`, handler)
		end,
	} :: any
	state.apart[services] = wrapped
	state.built[wrapped] = "scope"
	return wrapped
end

-- One API access check per services table. Stores made while it runs wait for its answer
local function probe(services: Types.Services, report: (message: string) -> ()): Resolved
	local running = state.probes[services]
	if running then
		if not running.done then
			table.insert(running.waiting, coroutine.running())
			coroutine.yield()
		end
		return running.mode
	end
	local entry: Probe = { done = false, mode = "mock", waiting = {} }
	state.probes[services] = entry
	local mode: Resolved
	if services.placeId == 0 then
		-- a place that was never published has no data stores to reach
		mode = "mock"
	else
		-- TODO(verify): the error table words 403 as a write error ("Can't write to DataStore
		-- from Studio because API access is not enabled"). Whether a GetAsync without API access
		-- gets the same 403 isn't stated. Any failure lands on "mock", so a wrong guess can only
		-- keep data in memory, never reach live data
		local result = services.dataStore(PROBE_STORE):get(PROBE_KEY)
		if result.ok then
			mode = "scope"
		else
			mode = "mock"
			if result.error.kind ~= "noAccess" then
				report(
					`couldn't tell whether Studio has API access, so Studio data stays in memory: {result.error.message}`
				)
			end
		end
	end
	entry.mode = mode
	entry.done = true
	local waiting = entry.waiting
	entry.waiting = {}
	for _, thread in waiting do
		services.clock:resume(thread)
	end
	return mode
end

-- The services a store uses and the mode it ends up in. Outside Studio that's always the given
-- services and "real". "auto" yields for one DataStore read the first time, in Studio only
function Studio.resolve(
	services: Types.Services,
	mode: Mode,
	report: (message: string) -> ()
): (Types.Services, Resolved)
	Studio.check(mode)
	state.used = true
	local built: Resolved? = state.built[services]
	if built then
		return services, built
	end
	if not services.lifecycle:isStudio() then
		return services, "real"
	end
	local resolved: Resolved = if mode == "auto" then probe(services, report) else mode :: Resolved
	if resolved == "mock" then
		return memory(services), "mock"
	elseif resolved == "scope" then
		return apart(services), "scope"
	end
	return services, "real"
end

-- tests only
function Studio._reset()
	state = fresh()
end

return Studio
