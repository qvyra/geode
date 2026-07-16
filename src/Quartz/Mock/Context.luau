--!strict

-- State shared by every mock adapter. `Shared` is the universe, the backing data all mock servers
-- see. `Context` is one server's view of it, with that server's faults

local Errors = require("../Errors")
local Faults = require("./Faults")
local MockClock = require("./Clock")
local Types = require("../Types")

export type Limits = {
	-- 50 char cap on DataStore key names, not verified yet
	keyLength: number,
	-- needs both set. Wire a JSON length in to mimic the real value size cap
	valueSize: number?,
	measure: ((value: unknown) -> number)?,
}

export type StoredVersion = {
	version: string,
	value: unknown,
	createdTime: number,
	deleted: boolean,
	userIds: { number },
	metadata: { [string]: unknown },
}

export type DataStoreEntry = {
	createdTime: number,
	versions: { StoredVersion },
}

export type MemoryItem = {
	value: unknown,
	sortKey: Types.SortKey?,
	expiresAt: number,
}

export type QueueItem = {
	seq: number,
	value: unknown,
	priority: number,
	expiresAt: number,
	invisibleUntil: number,
	readId: string?,
}

export type Subscription = {
	jobId: string,
	handler: Types.MessageHandler,
	connected: boolean,
	isAlive: () -> boolean,
}

export type TeleportRecord = {
	fromJobId: string,
	placeId: number,
	players: { unknown },
	options: Types.TeleportOptions?,
}

export type KickRecord = {
	jobId: string,
	userId: number,
	reason: string,
}

export type Shared = {
	clock: MockClock.MockClock,
	limits: Limits,
	messagingLatency: number,
	dataStores: { [string]: { [string]: DataStoreEntry } },
	orderedDataStores: { [string]: { [string]: number } },
	hashMaps: { [string]: { [string]: MemoryItem } },
	sortedMaps: { [string]: { [string]: MemoryItem } },
	queues: { [string]: { QueueItem } },
	topics: { [string]: { Subscription } },
	teleports: { TeleportRecord },
	kicks: { KickRecord },
	sequence: number,
}

export type BudgetState = {
	amount: number,
	refillPerSecond: number,
	updatedAt: number,
}

export type Context = {
	shared: Shared,
	faults: Faults.Faults,
	budgets: { [Types.BudgetType]: BudgetState },
	jobId: string,
	placeId: number,
	alive: boolean,
}

local Context = {}

-- Which budget each call draws from.
-- TODO(verify): best guess at how Roblox charges calls, esp. RemoveAsync, GetVersionAsync
-- and the ordered store writes
local BUDGET_TYPES: { [string]: { [string]: Types.BudgetType } } = {
	dataStore = {
		get = "get",
		set = "setIncrement",
		increment = "setIncrement",
		remove = "setIncrement",
		update = "update",
		listVersions = "list",
		getVersion = "get",
	},
	orderedDataStore = {
		get = "get",
		set = "setIncrementSorted",
		increment = "setIncrementSorted",
		remove = "setIncrementSorted",
		update = "update",
		getSorted = "getSorted",
	},
}

--[=[
	The current budget, refilled for the time since it was last read
]=]
function Context.budget(context: Context, budgetType: Types.BudgetType): number
	local state = context.budgets[budgetType]
	if state == nil then
		return math.huge
	end
	local now = context.shared.clock:now()
	state.amount += (now - state.updatedAt) * state.refillPerSecond
	state.updatedAt = now
	return state.amount
end

local function consume(context: Context, service: string, method: string): Types.AdapterError?
	local byMethod = BUDGET_TYPES[service]
	local budgetType: Types.BudgetType? = if byMethod then byMethod[method] else nil
	if budgetType == nil or context.budgets[budgetType] == nil then
		return nil
	end
	if Context.budget(context, budgetType) < 1 then
		local code = Errors.THROTTLE_CODES[method] or 304
		return Errors.classify(`{code}: {method} request dropped, {budgetType} budget exhausted`)
	end
	context.budgets[budgetType].amount -= 1
	return nil
end

function Context.nextId(shared: Shared): string
	shared.sequence += 1
	return string.format("%010d", shared.sequence)
end

function Context.nowMillis(shared: Shared): number
	return math.floor(shared.clock:now() * 1000)
end

--[=[
	Runs at the start of every mock call. Refuses calls from a crashed server, then applies any
	injected faults
]=]
function Context.enter(
	context: Context,
	service: string,
	store: string,
	method: string,
	key: string?
): (Types.AdapterError?, Faults.ForeignWrite?)
	if not context.alive then
		-- crashed server: the thread never gets an answer, same as a dead process
		coroutine.yield()
	end
	-- MockClock is a Clock at runtime, but Luau won't accept its method types as Clock's
	local clock = context.shared.clock :: any
	local err, foreign = context.faults:apply(clock, service, store, method, key)
	if err then
		return err, nil
	end
	local budgetError = consume(context, service, method)
	if budgetError then
		return budgetError, nil
	end
	return nil, foreign
end

function Context.checkKey(shared: Shared, key: string): Types.AdapterError?
	if key == "" then
		return Errors.classify("101: Key name can't be empty")
	end
	if #key > shared.limits.keyLength then
		return Errors.classify(
			`102: Key name exceeds the {shared.limits.keyLength} character limit`
		)
	end
	return nil
end

function Context.checkSize(shared: Shared, value: unknown): Types.AdapterError?
	local limit, measure = shared.limits.valueSize, shared.limits.measure
	if limit and measure and measure(value) > limit then
		return Errors.classify(`105: Serialized value exceeds the {limit} limit`)
	end
	return nil
end

return Context
