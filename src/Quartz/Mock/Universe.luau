--!strict

-- A fake Roblox experience. Every server made from one universe shares DataStores,
-- MemoryStores and topics, so cross-server behavior is testable in one process

local Context = require("./Context")
local Faults = require("./Faults")
local Json = require("../Json")
local MockClock = require("./Clock")
local MockDataStore = require("./DataStore")
local MockHashMap = require("./HashMap")
local MockMessaging = require("./Messaging")
local MockOrderedDataStore = require("./OrderedDataStore")
local MockQueue = require("./Queue")
local MockPlayers = require("./Players")
local MockSortedMap = require("./SortedMap")
local MockTeleport = require("./Teleport")
local Types = require("../Types")

export type UniverseOptions = {
	clock: MockClock.MockClock?,
	limits: {
		keyLength: number?,
		nameLength: number?,
		valueSize: number?,
		measure: ((value: unknown) -> number)?,
		keyThroughput: boolean?,
	}?,
	messagingLatency: number?,
}

export type ServerOptions = {
	jobId: string?,
	placeId: number?,
	studio: boolean?,
}

export type MockServer = {
	jobId: string,
	placeId: number,
	guid: () -> string,
	clock: Types.Clock,
	budget: Types.Budget,
	json: Types.Json,
	players: Types.Players,
	marketplace: Types.Marketplace,
	lifecycle: Types.Lifecycle,
	dataStore: (name: string, scope: string?) -> Types.DataStore,
	orderedDataStore: (name: string, scope: string?) -> Types.OrderedDataStore,
	hashMap: (name: string) -> Types.HashMap,
	sortedMap: (name: string) -> Types.SortedMap,
	queue: (name: string, invisibilityTimeout: number?) -> Types.Queue,
	messaging: Types.Messaging,
	teleport: Types.Teleport,

	--[=[
		Adds a fault rule for calls made from this server
	]=]
	inject: (self: MockServer, rule: Faults.FaultRule) -> (),
	--[=[
		Caps a request budget for this server. Every matching call uses one, and the budget
		refills at `refillPerSecond`. Budgets that were never set are unlimited
	]=]
	setBudget: (
		self: MockServer,
		budgetType: Types.BudgetType,
		amount: number,
		refillPerSecond: number?
	) -> (),
	clearFaults: (self: MockServer) -> (),
	--[=[
		Brings a player into this server. Join handlers each run in their own thread, so advance
		the clock to let them finish
	]=]
	join: (self: MockServer, userId: number, name: string?) -> MockPlayers.MockPlayer,
	leave: (self: MockServer, userId: number) -> (),
	--[=[
		Runs the ProcessReceipt callback like a purchase would and returns its decision. Yields
	]=]
	purchase: (self: MockServer, info: unknown) -> unknown,
	--[=[
		Kills the server. Its pending calls never return and its subscribers stop hearing
		messages, like a process that died mid flight
	]=]
	crash: (self: MockServer) -> (),
	isAlive: (self: MockServer) -> boolean,
	--[=[
		Starts a shutdown: every bindToClose callback runs in its own clock thread. Advance the
		clock to let them finish
	]=]
	shutdown: (self: MockServer) -> (),
}

type Fields = {
	clock: MockClock.MockClock,
	teleports: { Context.TeleportRecord },
	kicks: { Context.KickRecord },
	_shared: Context.Shared,
	_servers: number,
}

local Universe = {}
Universe.__index = Universe

export type Universe = typeof(setmetatable({} :: Fields, Universe))

local DEFAULT_KEY_LENGTH = 50

--[=[
	Creates an empty universe

	@within Testing
	@param options UniverseOptions?
	@return Universe
]=]
function Universe.new(options: UniverseOptions?): Universe
	local clock = options and options.clock or MockClock.new()
	local limits = options and options.limits
	local shared: Context.Shared = {
		clock = clock,
		limits = {
			keyLength = limits and limits.keyLength or DEFAULT_KEY_LENGTH,
			nameLength = limits and limits.nameLength or DEFAULT_KEY_LENGTH,
			valueSize = limits and limits.valueSize,
			measure = limits and limits.measure,
			keyThroughput = limits and limits.keyThroughput,
		},
		messagingLatency = options and options.messagingLatency or 0,
		dataStores = {},
		orderedDataStores = {},
		hashMaps = {},
		sortedMaps = {},
		queues = {},
		topics = {},
		teleports = {},
		kicks = {},
		sequence = 0,
		throughput = {},
	}
	local self: Fields = {
		clock = clock,
		teleports = shared.teleports,
		kicks = shared.kicks,
		_shared = shared,
		_servers = 0,
	}
	return setmetatable(self, Universe)
end

-- Mocks match the adapter types at runtime, but their methods are typed against the concrete
-- class and Luau won't take that where the interface is expected
local function asAdapter<T>(adapter: unknown): T
	return adapter :: any
end

--[=[
	Adds a server to the universe. Adapters are created once per name, so faults and state
	stick to them across calls
]=]
function Universe.server(self: Universe, options: ServerOptions?): MockServer
	self._servers += 1
	local context: Context.Context = {
		shared = self._shared,
		faults = Faults.new(),
		budgets = {},
		jobId = options and options.jobId or `job-{self._servers}`,
		placeId = options and options.placeId or 1,
		alive = true,
	}

	local closeCallbacks: { () -> () } = {}
	local players = MockPlayers.new(context)
	local studio: boolean = if options and options.studio then true else false

	local cache: { [string]: unknown } = {}
	local function memo<T>(id: string, make: () -> T): T
		if cache[id] == nil then
			cache[id] = make()
		end
		return cache[id] :: T
	end

	local server: MockServer = {
		jobId = context.jobId,
		placeId = context.placeId,
		guid = function(): string
			return `guid-{Context.nextId(self._shared)}`
		end,
		clock = asAdapter(self.clock),
		budget = {
			get = function(_self: Types.Budget, budgetType: Types.BudgetType): number
				return math.floor(Context.budget(context, budgetType))
			end,
		},
		json = Json.adapter(),
		players = asAdapter(players),
		marketplace = asAdapter(players),
		lifecycle = {
			bindToClose = function(_self: Types.Lifecycle, callback: () -> ())
				table.insert(closeCallbacks, callback)
			end,
			isStudio = function(_self: Types.Lifecycle): boolean
				return studio
			end,
		},
		dataStore = function(name: string, scope: string?): Types.DataStore
			local resolved = scope or "global"
			return memo(`dataStore\0{name}\0{resolved}`, function()
				return asAdapter(MockDataStore.new(context, name, resolved))
			end)
		end,
		orderedDataStore = function(name: string, scope: string?): Types.OrderedDataStore
			local resolved = scope or "global"
			return memo(`orderedDataStore\0{name}\0{resolved}`, function()
				return asAdapter(MockOrderedDataStore.new(context, name, resolved))
			end)
		end,
		hashMap = function(name: string): Types.HashMap
			return memo(`hashMap\0{name}`, function()
				return asAdapter(MockHashMap.new(context, name))
			end)
		end,
		sortedMap = function(name: string): Types.SortedMap
			return memo(`sortedMap\0{name}`, function()
				return asAdapter(MockSortedMap.new(context, name))
			end)
		end,
		queue = function(name: string, invisibilityTimeout: number?): Types.Queue
			return memo(`queue\0{name}`, function()
				return asAdapter(MockQueue.new(context, name, invisibilityTimeout))
			end)
		end,
		messaging = asAdapter(MockMessaging.new(context)),
		teleport = asAdapter(MockTeleport.new(context)),

		inject = function(_self: MockServer, rule: Faults.FaultRule)
			context.faults:add(rule)
		end,
		setBudget = function(
			_self: MockServer,
			budgetType: Types.BudgetType,
			amount: number,
			refillPerSecond: number?
		)
			context.budgets[budgetType] = {
				amount = amount,
				refillPerSecond = refillPerSecond or 0,
				updatedAt = self.clock:now(),
			}
		end,
		clearFaults = function(_self: MockServer)
			context.faults:clear()
		end,
		join = function(_self: MockServer, userId: number, name: string?)
			return players:join(userId, name)
		end,
		leave = function(_self: MockServer, userId: number)
			players:leave(userId)
		end,
		purchase = function(_self: MockServer, info: unknown): unknown
			return players:purchase(info)
		end,
		crash = function(_self: MockServer)
			context.alive = false
		end,
		isAlive = function(_self: MockServer)
			return context.alive
		end,
		shutdown = function(_self: MockServer)
			for _, callback in closeCallbacks do
				self.clock:spawn(callback)
			end
		end,
	}
	return server
end

return Universe
