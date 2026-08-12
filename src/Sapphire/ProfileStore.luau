--!strict

-- Loads profiles under a session lease and tracks the ones this server holds. One store
-- per DataStore, usually one per game for player data

local Document = require("../Matrix/Document")
local Facet = require("../Facet/Facet")
local Guards = require("../Obsidian/Guards")
local Mailbox = require("./Mailbox")
local Profile = require("./Profile")
local Reconcile = require("./Reconcile")
local Record = require("./Record")
local Registry = require("./Registry")
local RealServices = require("../Quartz/Real/Services")
local Scheduler = require("../Quartz/Scheduler")
local Schema = require("../Obsidian/Schema")
local Signal = require("../Quartz/Signal")
local Size = require("../Obsidian/Size")
local Storable = require("../Obsidian/Storable")
local Transaction = require("../Matrix/Transaction")
local Types = require("../Quartz/Types")
local Universe = require("../Quartz/Mock/Universe")
local Validate = require("../Obsidian/Validate")

export type StealPolicy = "steal" | "wait" | "fail"

-- "mock" keeps Studio data in memory, "scope" uses a separate studio scope, "real" uses live data
export type StudioMode = "mock" | "scope" | "real"

export type Options = {
	name: string,
	template: { [string]: unknown },
	services: Types.Services?,
	scope: string?,
	scheduler: Scheduler.Scheduler?,
	schema: Schema.Schema?,
	schemaVersion: number?,
	-- Keyed by the version each one upgrades to. They run on the stored form, oldest first
	migrations: { [number]: (tx: Transaction.Transaction) -> () }?,
	-- How a player's user id maps to their key here. Defaults to the id as a string
	userKey: ((userId: number) -> string)?,
	-- How many recent purchase ids each profile keeps to refuse repeats. Defaults to 50
	receiptHistory: number?,
	guards: { Guards.Guard }?,
	bundles: { Facet.Bundle }?,
	reactions: { Facet.Reaction }?,
	derived: { Facet.Derived }?,
	maxReactionDepth: number?,
	ops: { string }?,
	autosaveInterval: number?,
	leaseTimeout: number?,
	stealAfter: number?,
	stealPolicy: StealPolicy?,
	onSessionLost: Profile.SessionLostPolicy?,
	studio: StudioMode?,
	sizeBudget: Size.Budget?,
	-- Seconds BindToClose waits for releases. Roblox allows about 30
	closeTimeout: number?,
	-- Seconds a load keeps retrying throttled or failing requests before giving up
	loadTimeout: number?,
	-- Release every profile on shutdown. On by default
	bindToClose: boolean?,
	reportError: ((message: string) -> ())?,
}

export type LoadOptions = {
	userId: number?,
	userIds: { number }?,
}

export type LoadErrorKind =
	"leaseHeld"
	| "adapter"
	| "corrupt"
	| "invalidData"
	| "alreadyLoaded"
	| "newerData"
	| "migrationFailed"

export type LoadResult =
	{ ok: true, profile: Profile.Profile }
	| { ok: false, error: { kind: LoadErrorKind, message: string } }

type Config = {
	autosaveInterval: number,
	leaseTimeout: number,
	stealAfter: number,
	stealPolicy: StealPolicy,
	onSessionLost: Profile.SessionLostPolicy,
	sizeBudget: Size.Budget,
	closeTimeout: number,
	loadTimeout: number,
	schemaVersion: number,
	receiptHistory: number,
}

type Fields = {
	name: string,
	scope: string,
	-- Fires for guard violations on any profile of this store, with the violation and the profile
	guardBroken: Signal.Signal,
	_services: Types.Services,
	_scheduler: Scheduler.Scheduler,
	_dataStore: Types.DataStore,
	_mailboxStore: Types.DataStore,
	_template: { [string]: unknown },
	_migrations: { [number]: (tx: Transaction.Transaction) -> () },
	_userKey: (userId: number) -> string,
	_storedTemplate: unknown,
	_schema: Schema.Schema?,
	_guards: { Guards.Guard },
	_facets: Facet.FacetSet,
	_ops: { string }?,
	_config: Config,
	_open: { [string]: Profile.Profile },
	_loading: { [string]: boolean },
	_report: (message: string) -> (),
}

local ProfileStore = {}
ProfileStore.__index = ProfileStore

export type ProfileStore = typeof(setmetatable({} :: Fields, ProfileStore))

-- Every default here can be overridden through the options
local DEFAULTS = {
	autosaveInterval = 60,
	leaseTimeout = 300,
	stealAfter = 15,
	stealPolicy = "steal" :: StealPolicy,
	onSessionLost = "kick" :: Profile.SessionLostPolicy,
	studio = "mock" :: StudioMode,
	closeTimeout = 25,
	loadTimeout = 30,
	receiptHistory = 50,
	-- DS limit is 4,194,304 per key. The hard budget stays below it since this JSON estimate
	-- can differ from HttpService's escaping
	sizeBudget = { soft = 3000000, hard = 4000000 },
}

-- same as Profile, UpdateAsync waits on the read and the write budget
local UPDATE_BUDGET: { Types.BudgetType } = { "standardRead", "standardWrite" }

local RETRY_BASE = 1
local RETRY_MAX = 5

local function copy(value: unknown): unknown
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value :: { [unknown]: unknown } do
		result[key] = copy(child)
	end
	return result
end

local function studioServices(
	services: Types.Services,
	mode: StudioMode,
	scope: string?
): (Types.Services, string)
	local resolvedScope = scope or "global"
	if not services.lifecycle:isStudio() or mode == "real" then
		return services, resolvedScope
	end
	if mode == "scope" then
		return services, `studio_{resolvedScope}`
	end
	-- in-memory universe running on the real clock
	local universe = Universe.new({ clock = services.clock :: any })
	local mock =
		universe:server({ jobId = services.jobId, placeId = services.placeId, studio = true })
	return mock, resolvedScope
end

--[=[
	Creates a profile store. Checks the template against the schema and the facets for cycles
	right away, so mistakes show up when the game starts, not when a player joins

	@within Profile
	@param options ProfileStoreOptions
	@return ProfileStore

	```lua
	local PlayerData = Geode.Profile.store({
		name = "PlayerData",
		template = { coins = 0, xp = 0, level = 1, inventory = {} },
	})
	```
]=]
function ProfileStore.new(options: Options): ProfileStore
	assert(type(options.name) == "string" and options.name ~= "", "a profile store needs a name")
	assert(type(options.template) == "table", "a profile store needs a template table")
	local report = options.reportError or function(message: string)
		warn(message)
	end

	local givenServices = options.services or RealServices.live()
	local services, scope =
		studioServices(givenServices, options.studio or DEFAULTS.studio, options.scope)

	if options.schema then
		local check = Validate.validate(options.schema, options.template, { root = "template" })
		if not check.ok then
			local issue = check.issues[1]
			error(`the template doesn't match the schema: {issue.path} {issue.message}`, 2)
		end
	end

	local guards: { Guards.Guard } = if options.guards then table.clone(options.guards) else {}
	if options.schema then
		table.insert(guards, 1, Guards.schema(options.schema))
	end

	local facets = Facet.set({
		bundles = options.bundles,
		reactions = options.reactions,
		derived = options.derived,
		maxDepth = options.maxReactionDepth,
	})
	-- a throwaway document catches derived names that clash with the template
	facets:attach(Document.new({ data = options.template, reportError = report }))

	local config: Config = {
		autosaveInterval = options.autosaveInterval or DEFAULTS.autosaveInterval,
		leaseTimeout = options.leaseTimeout or DEFAULTS.leaseTimeout,
		stealAfter = options.stealAfter or DEFAULTS.stealAfter,
		stealPolicy = options.stealPolicy or DEFAULTS.stealPolicy,
		onSessionLost = options.onSessionLost or DEFAULTS.onSessionLost,
		sizeBudget = options.sizeBudget or DEFAULTS.sizeBudget,
		closeTimeout = options.closeTimeout or DEFAULTS.closeTimeout,
		loadTimeout = options.loadTimeout or DEFAULTS.loadTimeout,
		schemaVersion = options.schemaVersion or 1,
		receiptHistory = options.receiptHistory or DEFAULTS.receiptHistory,
	}
	assert(config.autosaveInterval > 0, "autosaveInterval must be positive")
	assert(
		config.leaseTimeout > config.autosaveInterval,
		"leaseTimeout must be longer than autosaveInterval"
	)
	assert(config.stealAfter >= 0, "stealAfter can't be negative")
	assert(config.receiptHistory >= 1, "receiptHistory must be at least 1")

	local migrations: { [number]: (tx: Transaction.Transaction) -> () } = options.migrations or {}
	for version, migration in migrations do
		assert(
			type(version) == "number" and version % 1 == 0 and version >= 2,
			"migrations are keyed by the whole version number they upgrade to, starting at 2"
		)
		assert(
			version <= config.schemaVersion,
			`a migration to version {version} is newer than schemaVersion {config.schemaVersion}`
		)
		assert(type(migration) == "function", `the migration to version {version} isn't a function`)
	end

	local self: Fields = {
		name = options.name,
		scope = scope,
		guardBroken = Signal.new(report),
		_services = services,
		_scheduler = options.scheduler
			or Scheduler.new({ clock = services.clock, budget = services.budget }),
		_dataStore = services.dataStore(options.name, scope),
		_mailboxStore = services.dataStore(`{options.name}_mailbox`, scope),
		_template = copy(options.template) :: { [string]: unknown },
		_migrations = migrations,
		_userKey = options.userKey or function(userId: number): string
			return tostring(userId)
		end,
		_storedTemplate = if options.schema
			then Validate.encode(options.schema, options.template)
			else copy(options.template),
		_schema = options.schema,
		_guards = guards,
		_facets = facets,
		_ops = options.ops,
		_config = config,
		_open = {},
		_loading = {},
		_report = report,
	}
	local store = setmetatable(self, ProfileStore)
	-- The registry holds stores loosely typed, see Registry.Erasable
	Registry.add(store :: any, givenServices)
	if options.bindToClose ~= false then
		services.lifecycle:bindToClose(function()
			store:releaseAll()
		end)
	end
	return store
end

--// ================================================================ //--
--//  Loading                                                         //--
--// ================================================================ //--

local function loadFailure(kind: LoadErrorKind, message: string): LoadResult
	return { ok = false, error = { kind = kind, message = message } }
end

type Attempt = {
	outcome: "acquired" | "held" | "corrupt",
	record: Record.Record?,
	holder: Record.Lease?,
}

-- One try at taking the lease. Free, stale and already held leases are taken. A live holder is
-- only displaced when `force` is set
function ProfileStore._tryAcquire(
	self: ProfileStore,
	key: string,
	owner: Record.Owner,
	userIds: { number },
	force: boolean
): (Attempt?, Types.AdapterError?)
	local services = self._services
	local config = self._config
	local attempt: Attempt = { outcome = "held", record = nil, holder = nil }

	local result = self._scheduler:submit({
		priority = "load",
		budget = UPDATE_BUDGET,
		key = self:_schedulerKey(key),
		write = true,
		run = function()
			return self._dataStore:update(key, function(current: unknown)
				attempt = { outcome = "held", record = nil, holder = nil }
				local now = services.clock:now()
				local record: Record.Record
				if current == nil then
					record = Record.new(self._storedTemplate, now, config.schemaVersion)
				elseif Record.isRecord(current) then
					record = Record.copy(current :: Record.Record)
				else
					attempt.outcome = "corrupt"
					return nil
				end

				local state = Record.leaseState(record, now, config.leaseTimeout, owner)
				if state == "held" and not force then
					attempt.holder = record.meta.lease
					return nil
				end
				record.meta.lease = {
					jobId = owner.jobId,
					placeId = services.placeId,
					session = owner.session,
					acquiredAt = now,
					renewedAt = now,
				}
				record.meta.updatedAt = now
				record.meta.lastSession =
					{ session = owner.session, revision = record.meta.revision }
				attempt.outcome = "acquired"
				attempt.record = record
				return record, { userIds = userIds }
			end)
		end,
	})
	if not result.ok then
		return nil, result.error
	end
	return attempt, nil
end

function ProfileStore._abandon(self: ProfileStore, key: string, owner: Record.Owner)
	self._scheduler:submit({
		priority = "release",
		budget = UPDATE_BUDGET,
		key = self:_schedulerKey(key),
		write = true,
		run = function()
			return self._dataStore:update(key, function(current: unknown)
				if not Record.isRecord(current) then
					return nil
				end
				local record = Record.copy(current :: Record.Record)
				if
					Record.leaseState(record, self._services.clock:now(), math.huge, owner)
					~= "mine"
				then
					return nil
				end
				record.meta.lease = nil
				return record
			end)
		end,
	})
end

function ProfileStore._schedulerKey(self: ProfileStore, key: string): string
	return `dataStore/{self.name}/{self.scope}/{key}`
end

--[=[
	Takes the session lease on `key` and opens its profile. Yields. A lease held by another live
	server is retried with backoff until `stealAfter`, then the steal policy decides

	@param key string
	@param options LoadOptions?
	@return LoadResult
]=]
function ProfileStore.load(self: ProfileStore, key: string, options: LoadOptions?): LoadResult
	if self._open[key] or self._loading[key] then
		return loadFailure("alreadyLoaded", `profile {key} is already loaded on this server`)
	end
	self._loading[key] = true
	local result = self:_load(key, options)
	self._loading[key] = nil
	return result
end

function ProfileStore._load(self: ProfileStore, key: string, options: LoadOptions?): LoadResult
	local services = self._services
	local config = self._config
	local owner: Record.Owner = { jobId = services.jobId, session = services.guid() }
	local userId = options and options.userId
	local userIds: { number } = if options and options.userIds
		then options.userIds
		elseif userId then { userId }
		else {}

	local started = services.clock:now()
	local force = false
	local tries = 0
	local record: Record.Record
	while true do
		local attempt, adapterError = self:_tryAcquire(key, owner, userIds, force)
		if attempt == nil then
			local err = adapterError :: Types.AdapterError
			local retryable = err.kind == "throttled" or err.kind == "internal"
			if not retryable or services.clock:now() - started >= config.loadTimeout then
				-- the failed acquire may still have landed, give the lease back if so
				self:_abandon(key, owner)
				return loadFailure("adapter", err.message)
			end
			tries += 1
			services.clock:wait(math.min(RETRY_BASE * 2 ^ (tries - 1), RETRY_MAX))
			continue
		end
		if attempt.outcome == "corrupt" then
			return loadFailure(
				"corrupt",
				`profile {key} holds data that isn't a profile record, it was left untouched`
			)
		end
		if attempt.outcome == "acquired" then
			record = attempt.record :: Record.Record
			break
		end

		local holder = attempt.holder :: Record.Lease
		if services.clock:now() - started >= config.stealAfter then
			if config.stealPolicy == "fail" then
				return loadFailure("leaseHeld", `profile {key} is in use on server {holder.jobId}`)
			elseif config.stealPolicy == "steal" then
				force = true
				continue
			end
		end
		tries += 1
		services.clock:wait(math.min(RETRY_BASE * 2 ^ (tries - 1), RETRY_MAX))
	end

	local storedVersion = record.meta.schemaVersion
	if storedVersion > config.schemaVersion then
		self:_abandon(key, owner)
		return loadFailure(
			"newerData",
			`profile {key} was saved by schema version {storedVersion}, newer than this server's {config.schemaVersion}`
		)
	end

	local data = record.data
	if storedVersion < config.schemaVersion then
		local migrated, migrationError = self:_migrate(data, storedVersion)
		if migrationError then
			self:_abandon(key, owner)
			return loadFailure("migrationFailed", `profile {key}: {migrationError}`)
		end
		data = migrated
	end

	if self._schema then
		local ok, decoded = Validate.decode(self._schema, data)
		if not ok then
			self:_abandon(key, owner)
			local issues = (decoded :: { issues: { { path: string, message: string } } }).issues
			return loadFailure(
				"invalidData",
				`profile {key} can't be decoded: {issues[1].path} {issues[1].message}`
			)
		end
		data = decoded
	end
	data = Reconcile.fill(data, self._template)

	local document = Document.new({
		data = data,
		revision = record.meta.revision,
		ops = self._ops,
		clock = services.clock,
		reportError = self._report,
	})
	self._facets:attach(document)

	local guardSet = Guards.set({
		guards = self._guards,
		clock = services.clock,
		players = services.players,
		reportError = self._report,
	})
	guardSet:attach(document)

	local profile = Profile.new(document, {
		key = key,
		schedulerKey = self:_schedulerKey(key),
		dataStore = self._dataStore,
		scheduler = self._scheduler,
		clock = services.clock,
		json = services.json,
		players = services.players,
		owner = owner,
		placeId = services.placeId,
		userIds = userIds,
		userId = userId,
		schema = self._schema,
		schemaVersion = config.schemaVersion,
		template = self._template,
		receipts = if type(record.meta.receipts) == "table" then record.meta.receipts else {},
		receiptHistory = config.receiptHistory,
		mailboxCursor = if type(record.meta.mailboxCursor) == "number"
			then record.meta.mailboxCursor
			else 0,
		sizeBudget = config.sizeBudget,
		autosaveInterval = config.autosaveInterval,
		onSessionLost = config.onSessionLost,
		report = self._report,
		onClosed = function(closed: unknown)
			if (self._open[key] :: unknown) == closed then
				self._open[key] = nil
			end
		end,
	})
	guardSet.broken:connect(function(violation: Guards.Violation)
		self.guardBroken:fire(violation, profile)
	end)
	self:_deliverMail(key, profile)
	self._open[key] = profile
	return { ok = true, profile = profile }
end

-- Runs each migration from the stored version up, each as its own migration transaction on the
-- stored form. Returns the migrated data, or an error and leaves nothing changed
function ProfileStore._migrate(
	self: ProfileStore,
	data: unknown,
	fromVersion: number
): (unknown, string?)
	local document = Document.new({ data = data, reportError = self._report })
	for version = fromVersion + 1, self._config.schemaVersion do
		local migration = self._migrations[version]
		if migration == nil then
			continue
		end
		local result =
			document:transact(migration, { source = "migration", note = `to version {version}` })
		if not result.ok then
			return nil, `the migration to version {version} failed: {result.error.message}`
		end
	end
	return document:snapshot(), nil
end

--// ================================================================ //--
--//  Mailbox                                                         //--
--// ================================================================ //--

-- Applies everything after the saved cursor, one mailbox transaction per message, then trims
-- what earlier sessions already saved as applied. Failed messages are archived, not dropped
function ProfileStore._deliverMail(self: ProfileStore, key: string, profile: Profile.Profile)
	local savedCursor = profile:mailboxCursor()
	local read = self._scheduler:submit({
		priority = "load",
		budget = "standardRead",
		key = self:_mailboxKey(key),
		run = function()
			return self._mailboxStore:get(key)
		end,
	})
	if not read.ok then
		self._report(
			`couldn't read the mailbox of {key}, it will be delivered on a later load: {read.error.message}`
		)
		return
	end
	local box = Mailbox.read(read.value.value)
	if box == nil then
		self._report(`the mailbox of {key} is malformed and was left untouched`)
		return
	end

	local failures: { [number]: string } = {}
	for _, message in Mailbox.pending(box, savedCursor) do
		local result = profile:transact(function(tx)
			Mailbox.apply(tx, message)
		end, { source = "mailbox", note = `mail {message.seq}` })
		if not result.ok then
			failures[message.seq] = result.error.message
			self._report(`mail {message.seq} for {key} couldn't be applied: {result.error.message}`)
		end
		profile:_advanceMailbox(message.seq)
	end

	local alreadyApplied = #box.items - #Mailbox.pending(box, savedCursor)
	if next(failures) == nil and alreadyApplied == 0 then
		return
	end
	self._scheduler:submit({
		priority = "background",
		budget = UPDATE_BUDGET,
		key = self:_mailboxKey(key),
		write = true,
		run = function()
			return self._mailboxStore:update(key, function(current: unknown)
				local latest = Mailbox.read(current)
				if latest == nil then
					return nil
				end
				return Mailbox.prune(latest, savedCursor, failures)
			end)
		end,
	})
end

function ProfileStore._mailboxKey(self: ProfileStore, key: string): string
	return `dataStore/{self.name}_mailbox/{self.scope}/{key}`
end

--[=[
	Queues an op for a profile, wherever its player is. It's applied as a mailbox transaction the
	next time the profile loads. Yields

	@param key string
	@param op string -- a built-in op other than update, or a custom op this store enables
	@return Result<number> -- the message's sequence number
]=]
function ProfileStore.mail(
	self: ProfileStore,
	key: string,
	op: string,
	...: unknown
): Types.Result<number>
	local enabled = Mailbox.isBuiltIn(op) or (self._ops ~= nil and table.find(self._ops, op) ~= nil)
	if not enabled then
		return {
			ok = false,
			error = {
				kind = "invalidValue",
				message = `{op} can't be mailed, it isn't a storable built-in op or an op this store enables`,
			},
		}
	end
	local args = table.pack(...)
	local list = table.move(args, 1, args.n, 1, {})
	local storable = Storable.check(list, "args")
	if not storable.ok then
		local issue = storable.issues[1]
		return {
			ok = false,
			error = { kind = "invalidValue", message = `{issue.path} {issue.message}` },
		}
	end

	local id = self._services.guid()
	local seq = 0
	local duplicate = false
	local result = self._scheduler:submit({
		priority = "save",
		budget = UPDATE_BUDGET,
		key = self:_mailboxKey(key),
		write = true,
		run = function()
			return self._mailboxStore:update(key, function(current: unknown)
				local box = Mailbox.read(current)
				duplicate = false
				if box == nil then
					return nil
				end
				local existing = Mailbox.find(box, id)
				if existing then
					-- earlier try landed despite reporting failure
					seq, duplicate = existing, true
					return nil
				end
				seq = box.nextSeq
				return Mailbox.push(box, op, list, self._services.clock:now(), id)
			end)
		end,
	})
	if not result.ok then
		return { ok = false, error = result.error }
	end
	if result.value.cancelled and not duplicate then
		return {
			ok = false,
			error = { kind = "invalidValue", message = `the mailbox of {key} is malformed` },
		}
	end
	return { ok = true, value = seq }
end

--// ================================================================ //--
--//  Erasure                                                         //--
--// ================================================================ //--

--[=[
	The key a player's profile has in this store
]=]
function ProfileStore.keyForUser(self: ProfileStore, userId: number): string
	return self._userKey(userId)
end

--[=[
	Erases the data under `key` and its mailbox. The record keeps only an erased marker and its
	metadata, so a server elsewhere still holding the profile loses its session on the next save
	instead of writing the data back. Yields

	Overwriting a key doesn't remove its history. Older versions stay readable for 30 days, and
	RemoveVersionAsync is deprecated, so erasure is complete once those 30 days have passed
]=]
function ProfileStore.erase(self: ProfileStore, key: string): { ok: boolean, message: string? }
	local open = self._open[key]
	if open then
		open:_erased()
	end

	local erased = self._scheduler:submit({
		priority = "save",
		budget = UPDATE_BUDGET,
		key = self:_schedulerKey(key),
		write = true,
		run = function()
			return self._dataStore:update(key, function(current: unknown)
				if current == nil then
					return nil
				end
				local now = self._services.clock:now()
				local record = if Record.isRecord(current)
					then Record.copy(current :: Record.Record)
					else Record.new(nil, now, self._config.schemaVersion)
				record.data = nil
				record.meta.lease = nil
				record.meta.lastSession = nil
				record.meta.receipts = {}
				record.meta.mailboxCursor = 0
				record.meta.erasedAt = now
				record.meta.updatedAt = now
				return record, { userIds = {} }
			end)
		end,
	})
	if not erased.ok then
		return { ok = false, message = erased.error.message }
	end

	local mailbox = self._scheduler:submit({
		priority = "save",
		budget = "standardRemove",
		key = self:_mailboxKey(key),
		write = true,
		run = function()
			return self._mailboxStore:remove(key)
		end,
	})
	if not mailbox.ok then
		return {
			ok = false,
			message = `the profile was erased but its mailbox wasn't: {mailbox.error.message}`,
		}
	end
	return { ok = true, message = nil }
end

--// ================================================================ //--
--//  Open profiles                                                   //--
--// ================================================================ //--

--[=[
	The profile this server holds for `key`, if any
]=]
function ProfileStore.get(self: ProfileStore, key: string): Profile.Profile?
	return self._open[key]
end

function ProfileStore.openCount(self: ProfileStore): number
	local count = 0
	for _ in self._open do
		count += 1
	end
	return count
end

--[=[
	Releases every open profile at once, at release priority, and waits until they finish or the
	close timeout passes. Yields. Bound to BindToClose unless the store was told otherwise

	@return number -- how many releases finished in time
]=]
function ProfileStore.releaseAll(self: ProfileStore): number
	local clock = self._services.clock
	local pending = 0
	local finished = 0
	local waiter: thread? = nil

	-- keys first, then lookups. Iterating the map's values loses the profile type
	local keys: { string } = {}
	for key in self._open do
		table.insert(keys, key)
	end
	for _, key in keys do
		local profile = self._open[key]
		pending += 1
		clock:spawn(function()
			local result = profile:release()
			if result.ok then
				finished += 1
			end
			pending -= 1
			if pending == 0 and waiter then
				clock:resume(waiter)
			end
		end)
	end

	if pending > 0 then
		local timedOut = false
		local thread = coroutine.running()
		waiter = thread
		clock:delay(self._config.closeTimeout, function()
			if pending > 0 and not timedOut then
				timedOut = true
				clock:resume(thread)
			end
		end)
		coroutine.yield()
		waiter = nil
		if pending > 0 then
			self._report(`{pending} profile release(s) didn't finish within the close timeout`)
		end
	end
	return finished
end

return ProfileStore
