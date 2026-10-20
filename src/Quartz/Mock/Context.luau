--!strict

-- State shared by every mock adapter. `Shared` is the universe, the backing data all mock servers
-- see. `Context` is one server's view of it, with that server's faults

local Errors = require("../Errors")
local Faults = require("./Faults")
local MockClock = require("./Clock")
local Throughput = require("../Throughput")
local Types = require("../Types")

export type Limits = {
	-- 50 chars each for keys, store names and scopes
	keyLength: number,
	nameLength: number,
	-- needs both set. Wire a JSON length in to mimic the real value size cap
	valueSize: number?,
	measure: ((value: unknown) -> number)?,
	-- Throttle keys that go past Roblox's per key throughput. Needs `measure`
	keyThroughput: boolean?,
}

-- Off unless a test turns it on. Each server's DataStore keeps a copy of every key it reads or
-- writes for `seconds`, and a GetAsync that may use the cache returns that copy, as Roblox
-- documents. `cancelledUpdates` also answers an UpdateAsync from the copy when its transform
-- writes nothing, which is what the live bench timings look like but isn't documented.
-- A read that skips the cache refreshes the copy here. The docs say "all GetAsync calls that
-- retrieve a value ... from the backend update the cache", and live hops behave that way
export type DataStoreCache = {
	seconds: number,
	cancelledUpdates: boolean?,
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
	-- Versions a later write in the same hour replaced. They read as empty, not unknown
	replaced: { [string]: boolean }?,
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
	dataStoreCache: DataStoreCache?,
	dataStores: { [string]: { [string]: DataStoreEntry } },
	orderedDataStores: { [string]: { [string]: number } },
	hashMaps: { [string]: { [string]: MemoryItem } },
	sortedMaps: { [string]: { [string]: MemoryItem } },
	queues: { [string]: { QueueItem } },
	topics: { [string]: { Subscription } },
	teleports: { TeleportRecord },
	kicks: { KickRecord },
	sequence: number,
	throughput: { [string]: { read: Throughput.Tracker, write: Throughput.Tracker } },
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

-- UpdateAsync reads and writes, so it draws from both
local BUDGET_TYPES: { [string]: { [string]: { Types.BudgetType } } } = {
	dataStore = {
		get = { "standardRead" },
		set = { "standardWrite" },
		increment = { "standardWrite" },
		remove = { "standardRemove" },
		update = { "standardRead", "standardWrite" },
		listVersions = { "standardList" },
		getVersion = { "standardRead" },
	},
	orderedDataStore = {
		get = { "orderedRead" },
		set = { "orderedWrite" },
		increment = { "orderedWrite" },
		remove = { "orderedRemove" },
		update = { "orderedRead", "orderedWrite" },
		getSorted = { "orderedList" },
	},
}

function Context.budget(context: Context, budgetType: Types.BudgetType): number
	local state = context.budgets[budgetType]
	if state == nil or budgetType == "orderedList" then
		return math.huge
	end
	local now = context.shared.clock:now()
	state.amount += (now - state.updatedAt) * state.refillPerSecond
	state.updatedAt = now
	return state.amount
end

local function consume(context: Context, service: string, method: string): Types.AdapterError?
	local byMethod = BUDGET_TYPES[service]
	local budgetTypes = if byMethod then byMethod[method] else nil
	if budgetTypes == nil then
		return nil
	end
	for _, budgetType: Types.BudgetType in budgetTypes do
		if Context.budget(context, budgetType) < 1 then
			local code = Errors.THROTTLE_CODES[method] or 304
			return Errors.classify(
				`{code}: {method} request dropped, {budgetType} budget exhausted`
			)
		end
	end
	for _, budgetType: Types.BudgetType in budgetTypes do
		local state = context.budgets[budgetType]
		if state and budgetType ~= "orderedList" then
			state.amount -= 1
		end
	end
	return nil
end

function Context.nextId(shared: Shared): string
	shared.sequence += 1
	return string.format("%010d", shared.sequence)
end

function Context.nowMillis(shared: Shared): number
	return math.floor(shared.clock:now() * 1000)
end

function Context.enter(
	context: Context,
	service: string,
	store: string,
	method: string,
	key: string?
): (Types.AdapterError?, Faults.ForeignWrite?, Types.AdapterError?)
	if not context.alive then
		-- crashed server: the thread never gets an answer, same as a dead process
		coroutine.yield()
	end
	-- MockClock is a Clock at runtime, but Luau won't accept its method types as Clock's
	local clock = context.shared.clock :: any
	local err, foreign, landed = context.faults:apply(clock, service, store, method, key)
	if err then
		return err, nil, nil
	end
	local budgetError = consume(context, service, method)
	if budgetError then
		return budgetError, nil, nil
	end
	return nil, foreign, landed
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

-- Off unless the universe sets `keyThroughput` and a `measure`. `id` is store qualified
function Context.useThroughput(
	shared: Shared,
	id: string,
	value: unknown,
	write: boolean
): Types.AdapterError?
	local measure = shared.limits.measure
	if not shared.limits.keyThroughput or measure == nil then
		return nil
	end
	local windows = shared.throughput[id]
	if windows == nil then
		windows = {
			read = Throughput.tracker(Throughput.READ_LIMIT_KB),
			write = Throughput.tracker(Throughput.WRITE_LIMIT_KB),
		}
		shared.throughput[id] = windows
	end
	local now = shared.clock:now()
	local kilobytes = Throughput.kilobytes(if value == nil then 0 else measure(value))
	local tracker = if write then windows.write else windows.read
	if not tracker:room(now, kilobytes) then
		local direction = if write then "write" else "read"
		return Errors.classify(`KeyThrottled: {direction} throughput on {id} is over its limit`)
	end
	tracker:add(now, kilobytes)
	return nil
end

function Context.checkStoreName(shared: Shared, name: string, scope: string): Types.AdapterError?
	local limit = shared.limits.nameLength
	if #name > limit then
		return { kind = "invalidKey", message = `store name exceeds the {limit} character limit` }
	end
	if #scope > limit then
		return { kind = "invalidKey", message = `scope exceeds the {limit} character limit` }
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
