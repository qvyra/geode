--!strict

-- Shared shapes for every adapter. Real adapters and mocks implement the same types, and the
-- contract suites are written against these alone

--// results and errors

export type ErrorKind =
	"throttled"
	| "notFound"
	| "tooLarge"
	| "invalidKey"
	| "invalidValue"
	| "noAccess"
	-- The server is shutting down and the service no longer takes requests
	| "unavailable"
	| "internal"
	| "unknown"

-- each service shapes its errors differently
export type ErrorSource = "dataStore" | "memoryStore" | "messaging"

export type AdapterError = {
	kind: ErrorKind,
	code: number?,
	message: string,
}

export type Result<T> = { ok: true, value: T } | { ok: false, error: AdapterError }

--// clock

export type Clock = {
	-- wall clock seconds, comparable across servers
	now: (self: Clock) -> number,
	wait: (self: Clock, seconds: number) -> (),
	spawn: (self: Clock, fn: () -> ()) -> (),
	delay: (self: Clock, seconds: number, fn: () -> ()) -> (),
	-- Resumes a thread parked with coroutine.yield, on the next scheduler step rather than inline
	resume: (self: Clock, thread: thread) -> (),
}

--// request budget

-- Mirrors the modern Enum.DataStoreRequestType items. UpdateAsync draws on read and write at
-- once. OrderedList always reports 0 since it isn't metered, so it counts as unlimited
export type BudgetType =
	"standardRead"
	| "standardWrite"
	| "standardList"
	| "standardRemove"
	| "orderedRead"
	| "orderedWrite"
	| "orderedList"
	| "orderedRemove"

export type Budget = {
	-- how many of this type can go out right now without a throttle
	get: (self: Budget, budgetType: BudgetType) -> number,
}

--// DataStore

export type KeyInfo = {
	version: string,
	-- ms since the Unix epoch, like DataStoreKeyInfo
	createdTime: number,
	updatedTime: number,
	userIds: { number },
	metadata: { [string]: unknown },
}

export type WriteOptions = {
	userIds: { number }?,
	metadata: { [string]: unknown }?,
}

export type Read = {
	value: unknown,
	info: KeyInfo?,
}

export type Update = {
	value: unknown,
	info: KeyInfo?,
	-- The transform returned nil, so nothing was written and `value` is what it last saw
	cancelled: boolean,
}

-- nil cancels the write. May run more than once, so keep it pure
export type Transform = (current: unknown, info: KeyInfo?) -> (unknown, WriteOptions?)

export type VersionInfo = {
	version: string,
	createdTime: number,
	deleted: boolean,
}

export type VersionQuery = {
	ascending: boolean?,
	minDate: number?,
	maxDate: number?,
	limit: number?,
}

export type DataStore = {
	name: string,
	scope: string,
	get: (self: DataStore, key: string) -> Result<Read>,
	set: (self: DataStore, key: string, value: unknown, options: WriteOptions?) -> Result<string>,
	update: (self: DataStore, key: string, transform: Transform) -> Result<Update>,
	remove: (self: DataStore, key: string) -> Result<Read>,
	increment: (
		self: DataStore,
		key: string,
		delta: number,
		options: WriteOptions?
	) -> Result<number>,
	listVersions: (self: DataStore, key: string, query: VersionQuery?) -> Result<{ VersionInfo }>,
	getVersion: (self: DataStore, key: string, version: string) -> Result<Read>,
}

--// OrderedDataStore

export type OrderedEntry = {
	key: string,
	value: number,
}

export type OrderedQuery = {
	ascending: boolean?,
	limit: number?,
	min: number?,
	max: number?,
}

export type OrderedUpdate = {
	value: number?,
	cancelled: boolean,
}

export type OrderedDataStore = {
	name: string,
	scope: string,
	get: (self: OrderedDataStore, key: string) -> Result<number?>,
	set: (self: OrderedDataStore, key: string, value: number) -> Result<nil>,
	update: (
		self: OrderedDataStore,
		key: string,
		transform: (current: number?) -> number?
	) -> Result<OrderedUpdate>,
	remove: (self: OrderedDataStore, key: string) -> Result<number?>,
	increment: (self: OrderedDataStore, key: string, delta: number) -> Result<number>,
	getSorted: (self: OrderedDataStore, query: OrderedQuery?) -> Result<{ OrderedEntry }>,
}

--// MemoryStore

export type MemoryUpdate = {
	value: unknown,
	cancelled: boolean,
}

export type HashMapEntry = {
	key: string,
	value: unknown,
}

export type HashMap = {
	name: string,
	get: (self: HashMap, key: string) -> Result<unknown>,
	set: (self: HashMap, key: string, value: unknown, ttl: number) -> Result<nil>,
	update: (
		self: HashMap,
		key: string,
		transform: (current: unknown) -> unknown,
		ttl: number
	) -> Result<MemoryUpdate>,
	remove: (self: HashMap, key: string) -> Result<nil>,
	list: (self: HashMap, limit: number?) -> Result<{ HashMapEntry }>,
}

export type SortKey = string | number

export type SortedEntry = {
	key: string,
	value: unknown,
	sortKey: SortKey?,
}

-- Bounds are exclusive and absolute, whatever the direction
export type SortedBound = {
	key: string?,
	sortKey: SortKey?,
}

export type SortedRange = {
	descending: boolean?,
	count: number,
	lower: SortedBound?,
	upper: SortedBound?,
}

export type SortedUpdate = {
	value: unknown,
	sortKey: SortKey?,
	cancelled: boolean,
}

export type SortedTransform = (current: unknown, sortKey: SortKey?) -> (unknown, SortKey?)

export type SortedMap = {
	name: string,
	get: (self: SortedMap, key: string) -> Result<SortedEntry?>,
	set: (
		self: SortedMap,
		key: string,
		value: unknown,
		ttl: number,
		sortKey: SortKey?
	) -> Result<nil>,
	update: (
		self: SortedMap,
		key: string,
		transform: SortedTransform,
		ttl: number
	) -> Result<SortedUpdate>,
	remove: (self: SortedMap, key: string) -> Result<nil>,
	getRange: (self: SortedMap, range: SortedRange) -> Result<{ SortedEntry }>,
}

export type QueueReadOptions = {
	count: number,
	allOrNothing: boolean?,
	-- 0 or nil returns immediately
	waitTimeout: number?,
}

export type QueueRead = {
	items: { unknown },
	-- Pass to remove once the items are handled. Nil when nothing was read
	id: string?,
}

export type Queue = {
	name: string,
	invisibilityTimeout: number,
	add: (self: Queue, value: unknown, ttl: number, priority: number?) -> Result<nil>,
	read: (self: Queue, options: QueueReadOptions) -> Result<QueueRead>,
	remove: (self: Queue, id: string) -> Result<nil>,
}

--// messaging and teleport

export type Connection = {
	disconnect: (self: Connection) -> (),
}

export type MessageHandler = (data: unknown, sentAt: number) -> ()

export type Messaging = {
	publish: (self: Messaging, topic: string, data: unknown) -> Result<nil>,
	subscribe: (self: Messaging, topic: string, handler: MessageHandler) -> Result<Connection>,
}

export type ReservedServer = {
	code: string,
	serverId: string,
}

export type TeleportOptions = {
	reservedServerCode: string?,
	data: unknown?,
}

export type Teleport = {
	reserveServer: (self: Teleport, placeId: number) -> Result<ReservedServer>,
	-- Players are Player instances in Roblox and plain values in mocks
	teleport: (
		self: Teleport,
		placeId: number,
		players: { unknown },
		options: TeleportOptions?
	) -> Result<nil>,
}

--// players

export type PlayerEntry = {
	userId: number,
	player: unknown,
}

export type PlayerHandler = (userId: number, player: unknown) -> ()

export type Players = {
	-- not an error if they already left
	kick: (self: Players, userId: number, reason: string) -> Result<nil>,
	-- Handlers run for players who join or leave from now on, each in its own thread
	onJoin: (self: Players, handler: PlayerHandler) -> Connection,
	onLeave: (self: Players, handler: PlayerHandler) -> Connection,
	-- Players on this server right now, in the order they joined
	list: (self: Players) -> { PlayerEntry },
	isPresent: (self: Players, userId: number) -> boolean,
}

export type Marketplace = {
	-- Sets MarketplaceService.ProcessReceipt. One per game, a second call replaces it
	setProcessReceipt: (self: Marketplace, callback: (info: unknown) -> unknown) -> (),
}

--// lifecycle

export type Lifecycle = {
	-- Runs on shutdown. Roblox only gives these callbacks a limited window
	bindToClose: (self: Lifecycle, callback: () -> ()) -> (),
	isStudio: (self: Lifecycle) -> boolean,
}

--// JSON

-- encode only, for size estimates
export type Json = {
	encode: (self: Json, value: unknown) -> string,
}

--// services

-- Everything a server needs from Roblox. Stores take one, so the same code runs on
-- `Geode.Raw.services()` in a game and on a mock server in tests
export type Services = {
	jobId: string,
	placeId: number,
	-- unique across every call anywhere, like HttpService:GenerateGUID
	guid: () -> string,
	clock: Clock,
	budget: Budget,
	json: Json,
	players: Players,
	marketplace: Marketplace,
	lifecycle: Lifecycle,
	dataStore: (name: string, scope: string?) -> DataStore,
	orderedDataStore: (name: string, scope: string?) -> OrderedDataStore,
	hashMap: (name: string) -> HashMap,
	sortedMap: (name: string) -> SortedMap,
	queue: (name: string, invisibilityTimeout: number?) -> Queue,
	messaging: Messaging,
	teleport: Teleport,
}

return nil
