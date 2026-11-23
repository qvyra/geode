--!strict

-- Loads profiles under a session lease and tracks the ones this server holds. One store
-- per DataStore, usually one per game for player data

local Document = require("../Matrix/Document")
local Facet = require("../Facet/Facet")
local Future = require("../Quartz/Future")
local Guards = require("../Obsidian/Guards")
local Handoff = require("./Handoff")
local Tooling = require("./Tooling")
local Bus = require("../Vein/Bus")
local GuardEvent = require("../Vein/GuardEvent")
local VeinBridge = require("../Vein/Bridge")
local VeinRegistry = require("../Vein/Registry")
local Mailbox = require("./Mailbox")
local Path = require("../Matrix/Path")
local Profile = require("./Profile")
local Prune = require("./Prune")
local Reconcile = require("./Reconcile")
local Record = require("./Record")
local Registry = require("./Registry")
local RealServices = require("../Quartz/Real/Services")
local Scheduler = require("../Quartz/Scheduler")
local Schema = require("../Obsidian/Schema")
local Signal = require("../Quartz/Signal")
local Size = require("../Obsidian/Size")
local Storable = require("../Obsidian/Storable")
local Studio = require("../Quartz/Studio")
local Transaction = require("../Matrix/Transaction")
local Tree = require("../Matrix/Tree")
local Types = require("../Quartz/Types")
local Validate = require("../Obsidian/Validate")

export type StealPolicy = "steal" | "wait" | "fail"

-- "mock" keeps Studio data in memory, "scope" uses a separate studio scope, "real" uses live data
-- and "auto" picks "scope" or "mock" by whether Studio has API access. See Quartz/Studio
export type StudioMode = Studio.Mode

-- See Options.prune and Sapphire/Prune
export type PruneOptions = Prune.Options

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
	-- What a player kicked by a guard reads, unless the guard has its own kickMessage
	kickMessage: string?,
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
	-- One system transaction just before the final save, on every release while the session is
	-- still this server's. It must not yield. An error or a rejection is reported and the
	-- release goes on
	beforeRelease: Profile.BeforeRelease?,
	studio: StudioMode?,
	sizeBudget: Size.Budget?,
	-- Seconds BindToClose waits for releases. Roblox allows about 30
	closeTimeout: number?,
	-- Seconds a load keeps retrying throttled or failing requests before giving up
	loadTimeout: number?,
	-- Release every profile on shutdown. On by default
	bindToClose: boolean?,
	-- Ask holders over MessagingService to release, and hear when they have, so server hops
	-- don't wait out retries. On by default. Correctness never depends on it
	handoff: boolean?,
	-- Take mail sent with `store:mail` and apply it on load. Off by default, so stores that never
	-- get mail never read a mailbox. Turn it on wherever the store is made, senders included
	mailbox: boolean?,
	-- Keep a commit history in a `<name>_audit` DataStore: who changed which paths and why, one
	-- key per save. Off by default
	audit: boolean?,
	-- Remove keys the template no longer has, on load, after reconciling. What goes is archived
	-- in a `<name>_pruned` DataStore first. `version` goes up with every template change, so a
	-- server never prunes a record a newer template wrote. Off by default
	prune: PruneOptions?,
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
	| "destroyed"

export type Inspection = {
	data: unknown,
	-- path -> codec name, for every codec value in `data`
	codecs: { [string]: string },
	revision: number,
	state: Profile.State,
	session: string,
}

export type LoadResult =
	-- `erasedAt` is set when the stored data had been erased and the profile starts over from the
	-- template
	{ ok: true, profile: Profile.Profile, erasedAt: number? }
	| { ok: false, error: { kind: LoadErrorKind, message: string } }

-- Why a Studio playtest on live data gave up on a held lease
local STUDIO_LIVE_HELD = 'Studio with studio = "real" never steals a lease or asks for a release, '
	.. "since it's not known whether Studio messages reach live servers. "
	.. 'Use stealPolicy = "wait" to wait it out'

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
	-- A Studio playtest working on live data. It may not be able to reach live servers over
	-- MessagingService, so it never asks a holder to release and never steals from one
	liveFromStudio: boolean,
}

type Fields = {
	name: string,
	scope: string,
	-- Fires for guard violations on any profile of this store, with the violation and the profile
	guardBroken: Signal.Signal,
	-- Fires with the key and the erasure time when a profile whose data was erased loads again
	erasedProfileLoaded: Signal.Signal,
	_services: Types.Services,
	_scheduler: Scheduler.Scheduler,
	_dataStore: Types.DataStore,
	_mailboxStore: Types.DataStore,
	-- whether loads read the mailbox, see Options.mailbox
	_mailbox: boolean,
	_template: { [string]: unknown },
	_migrations: { [number]: (tx: Transaction.Transaction) -> () },
	_userKey: (userId: number) -> string,
	_storedTemplate: unknown,
	_schema: Schema.Schema?,
	_guards: { Guards.Guard },
	_kickMessage: string?,
	_beforeRelease: Profile.BeforeRelease?,
	_prune: Prune.Config?,
	_pruneMark: Prune.Mark?,
	_prunedStore: Types.DataStore,
	-- a template that changed under the same prune.version is reported once per store
	_destroyed: boolean,
	_facets: Facet.FacetSet,
	_ops: { string }?,
	_config: Config,
	_open: { [string]: Profile.Profile },
	_loading: { [string]: boolean },
	-- mail delivery of each profile open here, in stores with a mailbox
	_mail: { [string]: MailState },
	-- keys that heard of new mail while they loaded, looked at again once the load is done
	_mailHeard: { [string]: boolean },
	-- player of each open profile, so we can kick them when another server asks for it
	_owners: { [string]: number },
	_handoff: Handoff.Handoff,
	_audit: Types.DataStore?,
	-- rollbacks sent to another server and waiting on its answer, by request id
	_pendingRollbacks: { [string]: { thread: thread, done: boolean, ok: boolean, message: string? } },
	_pendingEdits: { [string]: { thread: thread, done: boolean, answer: EditResult? } },
	-- Answers to edits this server applied for other servers, by edit id, oldest first in
	-- _appliedOrder. A repeat of the same id gets the same answer instead of a second edit
	_appliedEdits: { [string]: EditResult },
	_appliedOrder: { string },
	_veinHandle: VeinRegistry.Handle,
	_report: (message: string) -> (),
}

--[=[
	@class ProfileStore

	A store of session locked player profiles. Made with `Geode.Profile.store`, and reachable as
	`PlayerData.store` from the beginner layer
]=]
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
	closeTimeout = 25,
	loadTimeout = 30,
	receiptHistory = 50,
	-- DS limit is 4,194,304 per key. The hard budget stays below it since this JSON estimate
	-- can differ from HttpService's escaping
	sizeBudget = { soft = 3000000, hard = 4000000 },
}

-- same as Profile, UpdateAsync waits on the read and the write budget
local UPDATE_BUDGET: { Types.BudgetType } = { "standardRead", "standardWrite" }

-- The stores on each server by name and scope, see ProfileStore._siblings. Weak all the way, so a
-- dropped mock server or store takes its entry with it
local siblings: { [any]: { [string]: { [string]: { [any]: boolean } } } } = setmetatable(
	{},
	{ __mode = "k" }
) :: any

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
	Studio.check(options.studio)
	Studio.checkScope(options.scope)
	local mode: Studio.Mode = Studio.mode(options.studio)
	local services: Types.Services, studio: Studio.Resolved =
		Studio.resolve(givenServices, mode, report)
	local scope = Studio.scope(options.scope, studio)

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
	Guards.checkKickMessage(options.kickMessage)
	assert(
		options.beforeRelease == nil or type(options.beforeRelease) == "function",
		"beforeRelease must be a function"
	)
	local prune = if options.prune then Prune.config(options.prune) else nil

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
		liveFromStudio = studio == "real" and givenServices.lifecycle:isStudio(),
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
		erasedProfileLoaded = Signal.new(report),
		_services = services,
		_scheduler = options.scheduler
			or Scheduler.new({ clock = services.clock, budget = services.budget }),
		_dataStore = services.dataStore(options.name, scope),
		_mailboxStore = services.dataStore(`{options.name}_mailbox`, scope),
		_mailbox = options.mailbox == true,
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
		_kickMessage = options.kickMessage,
		_beforeRelease = options.beforeRelease,
		_prune = prune,
		_pruneMark = if prune
			then { version = prune.version, shape = Prune.shape(options.template, prune.keep) }
			else nil,
		-- made for every store, so an erase also clears the archive of a store that once pruned
		_prunedStore = services.dataStore(`{options.name}_pruned`, scope),
		_destroyed = false,
		_facets = facets,
		_ops = options.ops,
		_config = config,
		_open = {},
		_loading = {},
		_mail = {},
		_mailHeard = {},
		_owners = {},
		_handoff = Handoff.new(services, options.name, options.handoff ~= false, report),
		_pendingRollbacks = {},
		_pendingEdits = {},
		_appliedEdits = {},
		_appliedOrder = {},
		_audit = if options.audit then services.dataStore(`{options.name}_audit`, scope) else nil,
		_veinHandle = nil :: any,
		_report = report,
	}
	local store = setmetatable(self, ProfileStore)
	store._handoff:onRequest(function(key: string, _from: string, session: string?)
		store:_releaseRequested(key, session)
	end)
	store._handoff:on("mail", function(message: Handoff.Message)
		store:_mailArrived(message.key, nil)
	end)
	store:_joinSiblings()
	store._handoff:on("rollback", function(message: Handoff.Message)
		store:_rollbackRequested(message)
	end)
	store._handoff:on("rollbackDone", function(message: Handoff.Message)
		store:_rollbackAnswered(message)
	end)
	store._handoff:on("op", function(message: Handoff.Message)
		store:_opRequested(message)
	end)
	store._handoff:on("opDone", function(message: Handoff.Message)
		store:_editAnswered(message)
	end)
	store._veinHandle = VeinRegistry.register("profileStore", options.name, function()
		return { scope = scope, open = store:openCount() }
	end, {
		keys = function(): { string }
			return store:openKeys()
		end,
		inspect = function(key: string): unknown
			return store:inspect(key)
		end,
		services = givenServices,
		-- the mode in use, so "auto" shows what it picked
		studio = studio :: string,
		ops = function(): unknown
			return Tooling.ops(store._ops)
		end,
		schemaAt = function(path: unknown): unknown
			return Tooling.schemaAt(store._schema, path)
		end,
		apply = function(
			key: string,
			op: string,
			args: { unknown },
			note: string,
			toolOptions: { dryRun: boolean? }?
		): unknown
			return store:_toolEdit(key, op, args, note, toolOptions)
		end,
	})
	VeinBridge.ensure(givenServices)
	-- The registry holds stores loosely typed, see Registry.Erasable
	Registry.add(store :: any, givenServices, "profile")
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

-- Mail delivery for a profile open here. Pings and sends on this server all go through it, so
-- one read of the mailbox runs at a time
type MailState = {
	-- a read of the mailbox is under way
	busy: boolean,
	-- more mail was heard of during that read, so read once more after it
	again: boolean,
	-- why messages failed, by seq, until a trim archives them
	failures: { [number]: string },
	-- the mailbox holds nothing at or before this cursor any more
	trimmed: number,
}

type Attempt = {
	outcome: "acquired" | "held" | "corrupt",
	record: Record.Record?,
	holder: Record.Lease?,
	erasedAt: number?,
	-- whether the record may be pruned, judged from its meta before this load marked it
	prune: Prune.Verdict?,
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

				if record.meta.erasedAt and record.data == nil then
					-- The player's data was erased and they're back. They start over from the
					-- template, and erasedAt stays so history from before it is never served again
					record.data = copy(self._storedTemplate)
					record.meta.schemaVersion = config.schemaVersion
					attempt.erasedAt = record.meta.erasedAt
				end

				local state = Record.leaseState(record, now, config.leaseTimeout, owner)
				if state == "held" and not force then
					attempt.holder = record.meta.lease
					return nil
				end
				local mark = self._pruneMark
				if mark then
					attempt.prune = Prune.verdict(record.meta, mark)
					-- Studio on live data never marks, or its template could stop live servers
					-- from pruning
					if not config.liveFromStudio then
						Prune.mark(record.meta, mark)
					end
				end
				record.meta.lease = {
					jobId = owner.jobId,
					placeId = services.placeId,
					session = owner.session,
					acquiredAt = now,
					renewedAt = now,
				}
				record.meta.format = Record.FORMAT
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

-- Reads the record past this server's cache after a release announcement. Live hops showed
-- UpdateAsync retries answering in under 10 ms with the lease still held, for about 4 seconds
-- after the first try, as if a transform that writes nothing were fed this server's cached copy
-- of the key. Roblox documents that 4 second cache for GetAsync only. A fresh GetAsync gets the
-- real record and refreshes the copy: in live hops the UpdateAsync right after it saw the
-- release every time, and hops went from about 5 s to about 0.6 s. That's observed, not
-- documented. Returns a held attempt when the lease really is still held, nil when the
-- UpdateAsync should go ahead
function ProfileStore._peekLease(self: ProfileStore, key: string, owner: Record.Owner): Attempt?
	local read = self._scheduler:submit({
		priority = "load",
		budget = "standardRead",
		key = self:_schedulerKey(key),
		run = function()
			return self._dataStore:get(key, { useCache = false })
		end,
	})
	if not read.ok or not Record.isRecord(read.value.value) then
		return nil
	end
	local record = read.value.value :: Record.Record
	local now = self._services.clock:now()
	if Record.leaseState(record, now, self._config.leaseTimeout, owner) ~= "held" then
		return nil
	end
	return { outcome = "held", record = nil, holder = record.meta.lease }
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
				record.meta.format = Record.FORMAT
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
	if self._destroyed then
		return loadFailure("destroyed", `the profile store {self.name} was destroyed`)
	end
	if self._open[key] or self._loading[key] then
		return loadFailure("alreadyLoaded", `profile {key} is already loaded on this server`)
	end
	self._loading[key] = true
	local result = self:_load(key, options)
	self._loading[key] = nil
	self._mailHeard[key] = nil
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

	self._handoff:start()
	local requested = false
	local started = services.clock:now()
	local force = false
	local tries = 0
	local record: Record.Record
	local erasedAt: number? = nil
	local pruneVerdict: Prune.Verdict? = nil
	local mailRead: Future.Future? = nil
	-- set when a read past the cache found the lease still held, so the next turn skips the
	-- UpdateAsync that would only find the same
	local peeked: Attempt? = nil
	while true do
		local attempt: Attempt?, adapterError: Types.AdapterError?
		if peeked then
			attempt, peeked = peeked, nil
		else
			-- The mailbox is read next to each attempt rather than after it, so a load costs one
			-- round trip. Reading before the lease is ours is safe: the cursor in the record we
			-- get decides what applies, and mail the read missed waits for the next load. A read
			-- still running from the last attempt is kept, a finished one is redone to pick up
			-- newer mail
			if self._mailbox and (mailRead == nil or mailRead:isDone()) then
				mailRead = self:_readMailbox(key)
			end
			attempt, adapterError = self:_tryAcquire(key, owner, userIds, force)
		end
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
			erasedAt = attempt.erasedAt
			pruneVerdict = attempt.prune
			break
		end

		local holder = attempt.holder :: Record.Lease
		local waited = services.clock:now() - started
		if waited >= config.stealAfter then
			-- Studio on live data turns a steal into a failure, see liveFromStudio
			local policy: StealPolicy = if config.liveFromStudio
					and config.stealPolicy == "steal"
				then "fail"
				else config.stealPolicy
			if policy == "fail" then
				return loadFailure(
					"leaseHeld",
					if config.liveFromStudio
						then `profile {key} is in use on server {holder.jobId}. {STUDIO_LIVE_HELD}`
						else `profile {key} is in use on server {holder.jobId}`
				)
			elseif policy == "steal" then
				force = true
				continue
			end
		end
		if not requested and not config.liveFromStudio then
			requested = true
			self._handoff:request(key, holder.session)
		end
		tries += 1
		-- Wakes early on the holder's release announcement. The handoff key backs that message
		-- up until the steal window closes
		local announced = self._handoff:wait(
			key,
			math.min(RETRY_BASE * 2 ^ (tries - 1), RETRY_MAX),
			holder.session,
			waited < config.stealAfter
		)
		if announced then
			peeked = self:_peekLease(key, owner)
		end
	end

	local data, problem, problemMessage = self:_decodeStored(key, record)
	if problem then
		self:_abandon(key, owner)
		return loadFailure(problem :: LoadErrorKind, problemMessage :: string)
	end

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
		kickMessage = self._kickMessage,
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
		beforeRelease = self._beforeRelease,
		templateMark = if config.liveFromStudio then nil else self._pruneMark,
		report = self._report,
		onClosed = function(closed: unknown)
			if (self._open[key] :: unknown) == closed then
				self._open[key] = nil
				self._owners[key] = nil
				self._mail[key] = nil
			end
		end,
	})
	guardSet.broken:connect(function(violation: Guards.Violation)
		self.guardBroken:fire(violation, profile)
		GuardEvent.publish(
			self.name,
			"profile",
			key,
			violation,
			self._schema,
			services.json,
			services.clock:now()
		)
	end)
	Bus.publish("profileLoaded", { store = self.name, key = key }, services.clock:now())
	profile.released:connect(function()
		Bus.publish("profileReleased", { store = self.name, key = key }, services.clock:now())
	end)
	profile.sessionLost:connect(function(reason: string)
		Bus.publish(
			"sessionLost",
			{ store = self.name, key = key, reason = reason },
			services.clock:now()
		)
	end)
	profile.saved:connect(function(revision: number)
		Bus.publish(
			"profileSaved",
			{ store = self.name, key = key, revision = revision },
			services.clock:now()
		)
	end)
	self:_publishCommits(key, profile)
	if self._audit then
		self:_auditProfile(key, profile)
	end
	profile.released:connect(function()
		services.clock:spawn(function()
			self._handoff:announce(key, profile:revision(), owner.session)
		end)
	end)
	if pruneVerdict then
		self:_pruneOnLoad(key, document, pruneVerdict, userIds)
	end
	local mailState: MailState? = nil
	if self._mailbox then
		local state: MailState =
			{ busy = false, again = false, failures = {}, trimmed = profile:mailboxCursor() }
		mailState = state
		profile.saved:connect(function()
			self:_trimMailbox(key, profile, state)
		end)
	end
	if mailRead then
		self:_deliverMail(
			key,
			profile,
			mailRead:await() :: Types.Result<Types.Read>,
			mailState :: MailState
		)
	end
	self._open[key] = profile
	if mailState then
		self._mail[key] = mailState
	end
	if self._mailHeard[key] then
		-- mail landed after this load read the mailbox, look again now it's open
		self._mailHeard[key] = nil
		self:_mailArrived(key, nil)
	end
	if userId then
		self._owners[key] = userId
	end
	if erasedAt then
		self.erasedProfileLoaded:fire(key, erasedAt)
	end
	return { ok = true, profile = profile, erasedAt = erasedAt }
end

-- Another server wants `key`. Its player has moved on, so release it and kick them if they're
-- somehow still here
function ProfileStore._releaseRequested(self: ProfileStore, key: string, session: string?)
	local open: unknown = self._open[key]
	if open == nil then
		return
	end
	local profile = self._open[key]
	if not profile:isActive() then
		return
	end
	-- A late request may name a session this server already dropped and replaced. Only the
	-- session it names gets released
	if session ~= nil and profile:sessionId() ~= session then
		return
	end
	local services = self._services
	local userId = self._owners[key]
	services.clock:spawn(function()
		-- the closing values first, while the player is still here, then the kick and the save
		profile:_beforeRelease("handoff")
		if userId and services.players:isPresent(userId) then
			services.players:kick(userId, "Your data was opened on another server. Please rejoin.")
		end
		profile:release("handoff")
	end)
end

-- The live data in a stored record: migrated, decoded and filled in from the template. On failure
-- returns nil with the load error kind and a message
function ProfileStore._decodeStored(
	self: ProfileStore,
	key: string,
	record: Record.Record
): (unknown, LoadErrorKind?, string?)
	local config = self._config
	local storedVersion = record.meta.schemaVersion
	if storedVersion > config.schemaVersion then
		return nil,
			"newerData",
			`profile {key} was saved by schema version {storedVersion}, newer than this server's {config.schemaVersion}`
	end

	local data = record.data
	if storedVersion < config.schemaVersion then
		local migrated, migrationError = self:_migrate(data, storedVersion)
		if migrationError then
			return nil, "migrationFailed", `profile {key}: {migrationError}`
		end
		data = migrated
	end

	if self._schema then
		local ok, decoded = Validate.decode(self._schema, data)
		if not ok then
			local issues = (decoded :: { issues: { { path: string, message: string } } }).issues
			return nil,
				"invalidData",
				`profile {key} can't be decoded: {issues[1].path} {issues[1].message}`
		end
		data = decoded
	end
	return Reconcile.fill(data, self._template), nil, nil
end

-- Removes the keys the template dropped, see Options.prune. The archive write comes first, and
-- when it fails nothing is removed
function ProfileStore._pruneOnLoad(
	self: ProfileStore,
	key: string,
	document: Document.Document,
	verdict: Prune.Verdict,
	userIds: { number }
)
	local prune = self._prune :: Prune.Config
	if verdict == "newer" then
		return
	end
	if verdict == "mismatch" then
		-- every load it holds back, so a clash that lasts keeps showing up
		local held = {}
		for _, path in Prune.find(document:snapshot(), self._template, prune.keep) do
			table.insert(held, Path.format(path))
		end
		local named = if #held > 0 then ` It kept {table.concat(held, ", ")}.` else ""
		self._report(
			`profile {key} was saved with another template under the same prune.version {prune.version}, so nothing was pruned from it.{named} `
				.. "Nothing is pruned from it until a server with a higher prune.version saves it. Raise prune.version with every template change"
		)
		return
	end
	if document:isReadOnly() then
		return
	end
	local found = Prune.find(document:snapshot(), self._template, prune.keep)
	if #found == 0 then
		return
	end
	-- Studio on live data only ever reports what would go
	local dryRun = prune.dryRun or self._config.liveFromStudio
	if not dryRun then
		local snapshot = document:snapshot()
		local stored = if self._schema then Validate.encode(self._schema, snapshot) else snapshot
		local values = {}
		for _, path in found do
			table.insert(values, { path = path, value = Tree.get(stored, path) })
		end
		local archived = self:_archivePruned(key, values, userIds)
		if not archived.ok then
			self._report(
				`couldn't archive the keys prune would remove from profile {key}, so nothing was removed: {archived.error.message}`
			)
			return
		end
		local removed = document:transact(function(tx)
			for _, path in found do
				tx:remove(path)
			end
		end, { source = "system", note = "prune" })
		if not removed.ok then
			self._report(
				`prune didn't remove the keys the template dropped from profile {key}: {removed.error.message}`
			)
			return
		end
	end
	local paths = {}
	for _, path in found do
		table.insert(paths, Path.format(path))
	end
	Bus.publish("pruned", {
		store = self.name,
		key = key,
		paths = paths,
		version = prune.version,
		dryRun = dryRun,
	}, self._services.clock:now())
end

-- Adds one entry to the profile's prune archive: when, under which version, and each removed
-- path with its stored value
function ProfileStore._archivePruned(
	self: ProfileStore,
	key: string,
	values: { { path: Path.Path, value: unknown } },
	userIds: { number }
): Types.Result<unknown>
	local now = self._services.clock:now()
	local version = (self._prune :: Prune.Config).version
	return self._scheduler:submit({
		priority = "load",
		budget = UPDATE_BUDGET,
		key = self:_prunedKey(key),
		write = true,
		run = function()
			return self._prunedStore:update(key, function(current: unknown)
				local entries = {}
				if type(current) == "table" and type((current :: any).entries) == "table" then
					entries = copy((current :: any).entries) :: { unknown }
				end
				table.insert(entries, { at = now, version = version, values = values })
				return { entries = entries }, { userIds = userIds }
			end)
		end,
	})
end

function ProfileStore._prunedKey(self: ProfileStore, key: string): string
	return `dataStore/{self.name}_pruned/{self.scope}/{key}`
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

-- Reads the mailbox of `key` on its own thread. The future settles with the read's result
function ProfileStore._readMailbox(self: ProfileStore, key: string): Future.Future
	local clock = self._services.clock
	local future = Future.new(clock)
	clock:spawn(function()
		future:resolve(self._scheduler:submit({
			priority = "load",
			budget = "standardRead",
			key = self:_mailboxKey(key),
			run = function()
				return self._mailboxStore:get(key)
			end,
		}))
	end)
	return future
end

-- Applies everything after the saved cursor, one mailbox transaction per message, then trims
-- what earlier sessions already saved as applied. Failed messages are archived, not dropped
function ProfileStore._deliverMail(
	self: ProfileStore,
	key: string,
	profile: Profile.Profile,
	read: Types.Result<Types.Read>,
	state: MailState
)
	local savedCursor = profile:mailboxCursor()
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

	self:_applyMail(key, profile, Mailbox.pending(box, savedCursor), state)
	local failures = state.failures

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

-- Applies messages past the profile's cursor in order, one mailbox transaction each. Only one
-- read runs per profile at a time, and each message is still checked against the cursor right
-- before it applies, so whichever path brought it, it applies once. A profile that is no longer
-- active keeps the rest for its next load
function ProfileStore._applyMail(
	self: ProfileStore,
	key: string,
	profile: Profile.Profile,
	messages: { Mailbox.Message },
	state: MailState
)
	for _, message in messages do
		if message.seq <= profile:mailboxCursor() then
			continue
		end
		if profile:state() ~= "active" then
			return
		end
		local result = profile:transact(function(tx)
			Mailbox.apply(tx, message)
		end, { source = "mailbox", note = `mail {message.seq}` })
		if not result.ok then
			if result.error.kind == "readOnly" then
				return
			end
			state.failures[message.seq] = result.error.message
			self._report(`mail {message.seq} for {key} couldn't be applied: {result.error.message}`)
		end
		profile:_advanceMailbox(message.seq)
	end
end

-- New mail for `key` was sent from this server or heard of in a ping. `message` is set when this
-- server sent it. A profile open here takes it now: as it is when it's the next one in line,
-- from a read of the mailbox otherwise. A ping is only a hint, the mailbox is what applies
function ProfileStore._mailArrived(self: ProfileStore, key: string, message: Mailbox.Message?)
	local profile = self._open[key]
	if not profile then
		if self._loading[key] then
			-- the load may have read the mailbox before this mail landed
			self._mailHeard[key] = true
		end
		return
	end
	local state = self._mail[key]
	if state == nil then
		return
	end
	if state.busy then
		state.again = true
		return
	end
	if message and message.seq == profile:mailboxCursor() + 1 then
		self:_applyMail(key, profile, { message }, state)
		return
	end
	state.busy = true
	self._services.clock:spawn(function()
		repeat
			state.again = false
			local read = self._scheduler:submit({
				priority = "background",
				budget = "standardRead",
				key = self:_mailboxKey(key),
				run = function()
					-- past the cache, which may still hold the box from before this mail
					return self._mailboxStore:get(key, { useCache = false })
				end,
			})
			if (self._open[key] :: any) ~= profile then
				break
			end
			if not read.ok then
				self._report(
					`couldn't read the mailbox of {key} for new mail, it will be delivered on a later load: {read.error.message}`
				)
				break
			end
			local box = Mailbox.read(read.value.value)
			if box == nil then
				self._report(`the mailbox of {key} is malformed and was left untouched`)
				break
			end
			self:_applyMail(key, profile, Mailbox.pending(box, profile:mailboxCursor()), state)
		until not state.again
		state.busy = false
	end)
end

-- After a save lands, drops the mail it saved as applied and archives the failures among it.
-- Only a saved cursor may trim: mail applied in memory still has to apply again if this server
-- dies before saving
function ProfileStore._trimMailbox(
	self: ProfileStore,
	key: string,
	profile: Profile.Profile,
	state: MailState
)
	local saved = profile:_savedMailbox()
	if saved <= state.trimmed then
		return
	end
	local before = state.trimmed
	state.trimmed = saved
	local trimming: { [number]: string } = {}
	for seq, reason in state.failures do
		if seq <= saved then
			trimming[seq] = reason
			state.failures[seq] = nil
		end
	end
	self._services.clock:spawn(function()
		local result = self._scheduler:submit({
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
					return Mailbox.prune(latest, saved, trimming)
				end)
			end,
		})
		if not result.ok then
			-- the next save tries again. Load trims what's left in any case
			state.trimmed = math.min(state.trimmed, before)
			for seq, reason in trimming do
				state.failures[seq] = reason
			end
		end
	end)
end

-- Every store on this server with the same DataStore name and scope, this one included. Mail
-- sent through one of them reaches a profile another has open
function ProfileStore._siblings(self: ProfileStore): { any }
	local list = {}
	local byScope = (siblings[self._services] or {})[self.name]
	for store in (byScope and byScope[self.scope]) or {} do
		table.insert(list, store)
	end
	return list
end

function ProfileStore._joinSiblings(self: ProfileStore)
	local byName = siblings[self._services]
	if byName == nil then
		byName = {}
		siblings[self._services] = byName
	end
	local byScope = byName[self.name]
	if byScope == nil then
		byScope = {}
		byName[self.name] = byScope
	end
	local set = byScope[self.scope]
	if set == nil then
		set = setmetatable({}, { __mode = "k" }) :: any
		byScope[self.scope] = set
	end
	set[self] = true
end

function ProfileStore._leaveSiblings(self: ProfileStore)
	local byScope = (siblings[self._services] or {})[self.name]
	local set = byScope and byScope[self.scope]
	if set then
		set[self] = nil
	end
end

function ProfileStore._mailboxKey(self: ProfileStore, key: string): string
	return `dataStore/{self.name}_mailbox/{self.scope}/{key}`
end

--[=[
	Queues an op for a profile, wherever its player is, and applies it as a mailbox transaction
	exactly once. A profile open on this server takes it before `mail` returns, one open on
	another server within moments when handoff is on there, and otherwise it applies on the next
	load. Only stores made with `mailbox = true` take mail. Yields

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
	if not self._mailbox then
		-- A store without it never reads its mailbox, so the mail would sit there unapplied
		return {
			ok = false,
			error = {
				kind = "invalidValue",
				message = `{self.name} doesn't take mail, make the store with mailbox = true`,
			},
		}
	end
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
	local sentAt = 0
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
				sentAt = self._services.clock:now()
				return Mailbox.push(box, op, list, sentAt, id)
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

	-- A profile open on this server takes the mail now. Otherwise any server holding it hears
	-- of it, and a lost ping only means the mail waits for the next load
	local message: Mailbox.Message = { seq = seq, id = id, op = op, args = list, sentAt = sentAt }
	local here = false
	for _, store in self:_siblings() do
		if store._open[key] or store._loading[key] then
			here = true
			store:_mailArrived(key, message)
		end
	end
	if not here then
		self._handoff:send("mail", key, { seq = seq })
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

	Erasure is immediate for every live read. Roblox still keeps the older versions of the key
	readable through the versioning API for 30 days, and RemoveVersionAsync is deprecated, so they
	can't be purged early. History and rollback refuse versions from before the erasure

	If the player joins again, their profile starts over from the template. The load result and
	`erasedProfileLoaded` report when that happens
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
				record.meta.format = Record.FORMAT
				return record, { userIds = {} }
			end)
		end,
	})
	if not erased.ok then
		return { ok = false, message = erased.error.message }
	end

	if self._audit then
		self:_eraseAudit(key)
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

	local archive = self._scheduler:submit({
		priority = "save",
		budget = "standardRemove",
		key = self:_prunedKey(key),
		write = true,
		run = function()
			return self._prunedStore:remove(key)
		end,
	})
	if not archive.ok then
		return {
			ok = false,
			message = `the profile was erased but its prune archive wasn't: {archive.error.message}`,
		}
	end
	return { ok = true, message = nil }
end

--// ================================================================ //--
--//  History, rollback and audit                                     //--
--// ================================================================ //--

export type HistoryOptions = {
	ascending: boolean?,
	limit: number?,
}

-- What an edit from a development tool did. `via` says where it ran
export type EditResult = {
	ok: boolean,
	revision: number?,
	via: ("here" | "holder" | "loaded")?,
	-- `guard` names the guard behind a "rejected" error, when a guard raised it
	error: { kind: string, message: string, guard: string? }?,
	-- set on a dry run's answer
	dryRun: boolean?,
	-- whether the edit would commit: no guard would reject or kick
	wouldCommit: boolean?,
	-- the paths the edit would change
	paths: { string }?,
	-- every guard the edit would break, as plain data
	violations: { { [string]: unknown } }?,
}

export type RollbackResult = {
	ok: boolean,
	message: string?,
	-- "here": this server held it. "holder": sent to the server holding it. "loaded": nobody
	-- held it, so this server loaded it to apply the rollback
	via: ("here" | "holder" | "loaded")?,
}

export type AuditEntry = {
	revision: number,
	source: string,
	userId: number?,
	note: string?,
	ops: { string },
	paths: { string },
	at: number,
}

export type AuditBatch = {
	from: number,
	to: number,
	entries: { AuditEntry },
}

-- When the stored record was erased, in seconds, or 0
-- For Geode.erase
function ProfileStore._eraseUser(
	self: ProfileStore,
	userId: number
): { ok: boolean, message: string?, skipped: boolean? }
	local result = self:erase(self:keyForUser(userId))
	return { ok = result.ok, message = result.message }
end

function ProfileStore._erasedAt(self: ProfileStore, key: string): Types.Result<number>
	local read = self._scheduler:submit({
		priority = "read",
		budget = "standardRead",
		key = self:_schedulerKey(key),
		run = function()
			return self._dataStore:get(key)
		end,
	})
	if not read.ok then
		return { ok = false, error = read.error }
	end
	local value = read.value.value
	if Record.isRecord(value) then
		local erasedAt = (value :: Record.Record).meta.erasedAt
		return { ok = true, value = erasedAt or 0 }
	end
	return { ok = true, value = 0 }
end

--[=[
	The stored versions of `key`, newest last by default. Roblox keeps one version per key for
	each UTC hour, holding the last write of that hour, so history moves in hourly steps.
	The Roblox docs don't spell this out, we found it in testing. Versions from before an
	erasure are left out, since they hold data the player asked to have removed

	@within ProfileStore
]=]
function ProfileStore.history(
	self: ProfileStore,
	key: string,
	options: HistoryOptions?
): Types.Result<{ Types.VersionInfo }>
	local erased = self:_erasedAt(key)
	if not erased.ok then
		return { ok = false, error = erased.error }
	end
	local listed = self._scheduler:submit({
		priority = "read",
		budget = "standardList",
		key = self:_schedulerKey(key),
		run = function()
			return self._dataStore:listVersions(key, {
				ascending = if options then options.ascending else nil,
				limit = if options then options.limit else nil,
			})
		end,
	})
	if not listed.ok then
		return { ok = false, error = listed.error }
	end
	local cutoff = erased.value * 1000
	local versions = {}
	for _, version in listed.value do
		if version.createdTime >= cutoff then
			table.insert(versions, version)
		end
	end
	return { ok = true, value = versions }
end

--[=[
	The data a stored version of `key` holds, migrated and decoded like a load would. Refuses
	versions from before an erasure

	@within ProfileStore
]=]
function ProfileStore.version(
	self: ProfileStore,
	key: string,
	versionId: string
): Types.Result<unknown>
	local erased = self:_erasedAt(key)
	if not erased.ok then
		return { ok = false, error = erased.error }
	end
	local read = self._scheduler:submit({
		priority = "read",
		budget = "standardRead",
		key = self:_schedulerKey(key),
		run = function()
			return self._dataStore:getVersion(key, versionId)
		end,
	})
	if not read.ok then
		return { ok = false, error = read.error }
	end
	local info = read.value.info
	if info == nil or not Record.isRecord(read.value.value) then
		return {
			ok = false,
			error = { kind = "notFound", message = `version {versionId} of {key} holds no profile` },
		}
	end
	-- Versions from before the latest erasure lack the marker or carry an older one. Comparing
	-- markers instead of timestamps means server and DS clocks don't have to agree
	local versionErasedAt = (read.value.value :: Record.Record).meta.erasedAt
	if erased.value > 0 and versionErasedAt ~= erased.value then
		return {
			ok = false,
			error = {
				kind = "noAccess",
				message = `version {versionId} of {key} is from before the data was erased`,
			},
		}
	end
	local record = read.value.value :: Record.Record
	if record.data == nil then
		return {
			ok = false,
			error = { kind = "notFound", message = `version {versionId} of {key} holds no data` },
		}
	end
	local data, problem, message = self:_decodeStored(key, record)
	if problem then
		return { ok = false, error = { kind = "invalidValue", message = message :: string } }
	end
	return { ok = true, value = data }
end

local ROLLBACK_ANSWER_TIMEOUT = 10
-- edit ids a holder remembers, so a message that arrives twice is only applied once
local APPLIED_EDITS_KEPT = 200

local function rollbackFailure(message: string): RollbackResult
	return { ok = false, message = message, via = nil }
end

local function applyRollback(
	profile: Profile.Profile,
	data: unknown,
	versionId: string,
	note: string?
): (boolean, string?)
	local result = profile:transact(function(tx)
		tx:set({}, data)
	end, { source = "system", note = `rollback to {versionId}{if note then `: {note}` else ""}` })
	if not result.ok then
		return false, result.error.message
	end
	local saved = profile:save()
	if not saved.ok then
		return false, saved.error.message
	end
	return true, nil
end

--[=[
	Puts `key` back to a stored version. A profile open here is changed directly. One held by
	another server gets the rollback sent to that server, which applies it to its open profile,
	since writing behind the holder's back would be lost on its next save. When nobody holds it,
	this server takes the lease, applies it and releases. Yields

	@within ProfileStore
]=]
function ProfileStore.rollback(
	self: ProfileStore,
	key: string,
	versionId: string,
	note: string?
): RollbackResult
	local version = self:version(key, versionId)
	if not version.ok then
		return rollbackFailure(version.error.message)
	end

	local open: unknown = self._open[key]
	if open ~= nil then
		local ok, message = applyRollback(self._open[key], version.value, versionId, note)
		return { ok = ok, message = message, via = if ok then "here" else nil }
	end

	local peek = self._scheduler:submit({
		priority = "read",
		budget = "standardRead",
		key = self:_schedulerKey(key),
		run = function()
			return self._dataStore:get(key)
		end,
	})
	if not peek.ok then
		return rollbackFailure(peek.error.message)
	end
	local current = peek.value.value
	if Record.isRecord(current) then
		local record = current :: Record.Record
		local now = self._services.clock:now()
		local nobody = { jobId = "", session = "" }
		if Record.leaseState(record, now, self._config.leaseTimeout, nobody) == "held" then
			local holder = (record.meta.lease :: Record.Lease).jobId
			if holder == self._services.jobId then
				-- This server holds the lease but hasn't opened the profile yet, or is releasing it
				return rollbackFailure(
					`profile {key} is being loaded or released on this server, try again`
				)
			end
			return self:_rollbackThroughHolder(key, holder, versionId, note)
		end
	end

	local userIds = if peek.value.info then peek.value.info.userIds else nil
	local loaded = self:load(key, { userIds = userIds })
	if not loaded.ok then
		return rollbackFailure(loaded.error.message)
	end
	local ok, message = applyRollback(loaded.profile, version.value, versionId, note)
	-- a tool's load isn't a play session, so the game's closing values stay out of it
	loaded.profile:_skipBeforeRelease()
	local released = loaded.profile:release()
	if ok and not released.ok then
		return rollbackFailure(released.error.message)
	end
	return { ok = ok, message = message, via = if ok then "loaded" else nil }
end

function ProfileStore._rollbackRequested(self: ProfileStore, message: Handoff.Message)
	if message.to ~= self._services.jobId or type(message.version) ~= "string" then
		return
	end
	local note = if type(message.note) == "string" then message.note else nil
	local function answer(ok: boolean, text: string?)
		self._handoff:send(
			"rollbackDone",
			message.key,
			{ id = message.id, ok = ok, message = text }
		)
	end
	local open: unknown = self._open[message.key]
	if open == nil then
		answer(false, `profile {message.key} was released before the rollback arrived`)
		return
	end
	self._services.clock:spawn(function()
		local result = self:rollback(message.key, message.version :: string, note)
		if not result.ok then
			self._report(`a rollback of {message.key} sent here failed: {result.message}`)
		end
		answer(result.ok, result.message)
	end)
end

-- Sends a rollback to the server holding the profile and waits for its answer. A holder that
-- crashed or never heard it doesn't answer, and the rollback is reported as not applied
function ProfileStore._rollbackThroughHolder(
	self: ProfileStore,
	key: string,
	holder: string,
	versionId: string,
	note: string?
): RollbackResult
	-- The answer comes back on the handoff topic, which this store may not listen to yet
	self._handoff:start()
	local clock = self._services.clock
	local id = self._services.guid()
	local pending =
		{ thread = coroutine.running(), done = false, ok = false, message = nil :: string? }
	self._pendingRollbacks[id] = pending
	local sent = self._handoff:send(
		"rollback",
		key,
		{ id = id, to = holder, version = versionId, note = note }
	)
	if not sent then
		self._pendingRollbacks[id] = nil
		return rollbackFailure(
			`profile {key} is held by server {holder} and the rollback couldn't be sent there`
		)
	end
	clock:delay(ROLLBACK_ANSWER_TIMEOUT, function()
		if not pending.done then
			pending.done = true
			pending.message = `server {holder} holds profile {key} but didn't answer the rollback`
			self._pendingRollbacks[id] = nil
			clock:resume(pending.thread)
		end
	end)
	coroutine.yield()
	return {
		ok = pending.ok,
		message = pending.message,
		via = if pending.ok then "holder" else nil,
	}
end

function ProfileStore._rollbackAnswered(self: ProfileStore, message: Handoff.Message)
	local id = message.id
	if type(id) ~= "string" then
		return
	end
	local pending = self._pendingRollbacks[id]
	if pending == nil or pending.done then
		return
	end
	self._pendingRollbacks[id] = nil
	pending.done = true
	pending.ok = message.ok == true
	pending.message = if type(message.message) == "string" then message.message else nil
	self._services.clock:resume(pending.thread)
end

--[=[
	Runs an op on the profile under `key` wherever it's held, with a plugin source. Tooling uses
	this so edits to a leased profile go through its holder instead of around it. Returns false
	when the op couldn't be applied here and couldn't be sent

	@within ProfileStore
]=]
function ProfileStore.sendOp(self: ProfileStore, key: string, name: string, ...: any): boolean
	local args = table.pack(...)
	local open: unknown = self._open[key]
	if open ~= nil then
		local result = self._open[key]:transact(function(tx)
			tx:op(name, table.unpack(args, 1, args.n))
		end, { source = "plugin" })
		return result.ok
	end
	return self._handoff:send("op", key, { name = name, args = table.move(args, 1, args.n, 1, {}) })
end

function ProfileStore._opRequested(self: ProfileStore, message: Handoff.Message)
	if type(message.id) == "string" then
		self:_editRequested(message)
		return
	end
	local open: unknown = self._open[message.key]
	if open == nil or type(message.name) ~= "string" or type(message.args) ~= "table" then
		return
	end
	local args = message.args :: { unknown }
	local result = self._open[message.key]:transact(function(tx)
		tx:op(message.name :: string, table.unpack(args))
	end, { source = "plugin" })
	if not result.ok then
		self._report(`an op sent to {message.key} failed: {result.error.message}`)
	end
end

-- Edits from development tools

local function editFailure(kind: string, message: string): EditResult
	return { ok = false, error = { kind = kind, message = message } }
end

local function callOp(tx: Transaction.Transaction, op: string, list: { unknown }, count: number)
	if Tooling.isBuiltIn(op) then
		-- built-ins are methods on the transaction, only custom ops go through tx:op
		(tx :: any)[op](tx, table.unpack(list, 1, count))
	else
		tx:op(op, table.unpack(list, 1, count))
	end
end

-- Runs a tool's edit on a profile open here, with a plugin source and the tool's note
function ProfileStore._editHere(
	self: ProfileStore,
	key: string,
	op: string,
	args: { unknown },
	note: string
): EditResult
	local profile = self._open[key]
	local decoded, values, count = Tooling.decodeArgs(self._schema, op, args)
	if not decoded then
		return editFailure("badArgs", values :: string)
	end
	local list = values :: { unknown }
	local result = profile:transact(function(tx)
		callOp(tx, op, list, count)
	end, { source = "plugin", note = note })
	if not result.ok then
		local failed = editFailure(result.error.kind, result.error.message);
		(failed.error :: any).guard = result.error.guard
		return failed
	end
	return { ok = true, revision = profile:revision(), via = "here" }
end

-- An edit from a development tool. Values arrive in stored form and are decoded with the
-- schema here, or on the holder when another server has the profile open. Nobody holding it
-- means this server takes the lease, edits and releases, the same as a rollback
function ProfileStore._toolEdit(
	self: ProfileStore,
	key: string,
	op: string,
	args: { unknown },
	note: string,
	options: { dryRun: boolean? }?
): EditResult
	local dryRun = options ~= nil and options.dryRun == true
	-- a dry run changes nothing, so it needs no note
	if not dryRun and (type(note) ~= "string" or note == "") then
		return editFailure("noteRequired", "edits from a development tool need a note saying why")
	end
	if type(key) ~= "string" or type(op) ~= "string" then
		return editFailure("badArgs", "an edit needs a key and an op name")
	end
	if not self._services.bridge:isAvailable() then
		return editFailure(
			"unavailable",
			"edits from development tools only run in a Studio playtest"
		)
	end
	local list: { unknown } = if type(args) == "table" then args else {}
	if dryRun then
		return self:_dryRun(key, op, list)
	end
	local open: unknown = self._open[key]
	if open ~= nil then
		return self:_editHere(key, op, list, note)
	end

	local peek = self._scheduler:submit({
		priority = "read",
		budget = "standardRead",
		key = self:_schedulerKey(key),
		run = function()
			return self._dataStore:get(key)
		end,
	})
	if not peek.ok then
		return editFailure("adapter", peek.error.message)
	end
	local current = peek.value.value
	if Record.isRecord(current) then
		local record = current :: Record.Record
		local nobody = { jobId = "", session = "" }
		local now = self._services.clock:now()
		if Record.leaseState(record, now, self._config.leaseTimeout, nobody) == "held" then
			local holder = (record.meta.lease :: Record.Lease).jobId
			if holder == self._services.jobId then
				return editFailure(
					"busy",
					`profile {key} is being loaded or released here, try again`
				)
			end
			if self._config.liveFromStudio then
				return editFailure(
					"unreachable",
					`profile {key} is open on live server {holder}. Studio on live data never sends `
						.. "messages to live servers, since it's not known whether they arrive"
				)
			end
			return self:_editThroughHolder(key, holder, op, list, note)
		end
	end

	local userIds = if peek.value.info then peek.value.info.userIds else nil
	local loaded = self:load(key, { userIds = userIds })
	if not loaded.ok then
		return editFailure("loadFailed", loaded.error.message)
	end
	-- Load, edit and release run back to back, and the release runs whatever the edit did, so a
	-- refused edit never leaves this server holding the lease
	local result = self:_editHere(key, op, list, note)
	loaded.profile:_skipBeforeRelease()
	local released = loaded.profile:release()
	if not released.ok then
		if result.ok then
			return editFailure("saveFailed", released.error.message)
		end
		return editFailure(
			"releaseFailed",
			`the edit was refused ({(result.error :: any).message}) and releasing {key} `
				.. `failed too: {released.error.message}`
		)
	end
	if result.ok then
		result.via = "loaded"
	end
	return result
end

-- What an edit would do to a profile open here: the paths it would change and every guard it
-- would break, with the actions they'd take. Runs the whole pipeline on a draft that's thrown
-- away, so nothing commits, no guard fires or counts it, and nobody is kicked
function ProfileStore._dryRun(
	self: ProfileStore,
	key: string,
	op: string,
	args: { unknown }
): EditResult
	local function failed(kind: string, message: string, guard: string?): EditResult
		local result = editFailure(kind, message)
		result.dryRun = true
		(result.error :: any).guard = guard
		return result
	end
	local open: unknown = self._open[key]
	if open == nil then
		return failed("notOpen", `a dry run needs profile {key} open on this server`)
	end
	local profile = self._open[key]
	local decoded, values, count = Tooling.decodeArgs(self._schema, op, args)
	if not decoded then
		return failed("badArgs", values :: string)
	end
	local list = values :: { unknown }
	local result = profile:transact(function(tx)
		callOp(tx, op, list, count)
	end, { source = "plugin", dryRun = true })
	if not result.ok then
		return failed(result.error.kind, result.error.message, result.error.guard)
	end
	local found = result.dryRun :: Document.DryRun
	local violations = {}
	local wouldCommit = true
	for _, finding in found.findings do
		local violation = finding :: Guards.Violation
		if Guards.ACTION_RANK[violation.action] >= Guards.ACTION_RANK.reject then
			wouldCommit = false
		end
		table.insert(violations, GuardEvent.describe(violation, self._schema, self._services.json))
	end
	return {
		ok = true,
		dryRun = true,
		wouldCommit = wouldCommit,
		paths = found.paths,
		violations = violations,
		revision = profile:revision(),
	}
end

-- Sends an edit to the server holding the profile and waits for its answer, like a rollback
function ProfileStore._editThroughHolder(
	self: ProfileStore,
	key: string,
	holder: string,
	op: string,
	args: { unknown },
	note: string
): EditResult
	self._handoff:start()
	local clock = self._services.clock
	local id = self._services.guid()
	local pending = { thread = coroutine.running(), done = false, answer = nil :: EditResult? }
	self._pendingEdits[id] = pending
	local sent =
		self._handoff:send("op", key, { id = id, to = holder, name = op, args = args, note = note })
	if not sent then
		self._pendingEdits[id] = nil
		return editFailure(
			"unreachable",
			`profile {key} is held by server {holder} and the edit couldn't be sent there`
		)
	end
	clock:delay(ROLLBACK_ANSWER_TIMEOUT, function()
		if not pending.done then
			pending.done = true
			self._pendingEdits[id] = nil
			clock:resume(pending.thread)
		end
	end)
	coroutine.yield()
	local answer = pending.answer
	if answer == nil then
		-- The edit may still have landed on the holder, so this isn't a failure. The last saved
		-- revision lets the tool look again before trying a second time
		local result = editFailure(
			"unknown",
			`server {holder} holds profile {key} but didn't answer in time, `
				.. "the edit may or may not have been applied"
		)
		result.revision = self:_savedRevision(key)
		return result
	end
	if answer.ok then
		answer.via = "holder"
	end
	return answer
end

function ProfileStore._editRequested(self: ProfileStore, message: Handoff.Message)
	if message.to ~= self._services.jobId then
		return
	end
	local function answer(result: EditResult)
		self._handoff:send("opDone", message.key, {
			id = message.id,
			ok = result.ok,
			revision = result.revision,
			error = result.error,
		})
	end
	local id = message.id :: string
	local earlier = self._appliedEdits[id]
	if earlier then
		answer(earlier)
		return
	end
	local note = if type(message.note) == "string" then message.note else ""
	local open: unknown = self._open[message.key]
	if open == nil then
		answer(
			editFailure("released", `profile {message.key} was released before the edit arrived`)
		)
		return
	end
	if type(message.name) ~= "string" or note == "" then
		answer(editFailure("badArgs", "an edit needs an op name and a note"))
		return
	end
	local args = if type(message.args) == "table" then message.args :: { unknown } else {}
	local result = self:_editHere(message.key, message.name :: string, args, note)
	self._appliedEdits[id] = result
	table.insert(self._appliedOrder, id)
	if #self._appliedOrder > APPLIED_EDITS_KEPT then
		self._appliedEdits[table.remove(self._appliedOrder, 1) :: string] = nil
	end
	answer(result)
end

-- The revision of the last save of `key`, or nil when it can't be read
function ProfileStore._savedRevision(self: ProfileStore, key: string): number?
	local peek = self._scheduler:submit({
		priority = "read",
		budget = "standardRead",
		key = self:_schedulerKey(key),
		run = function()
			return self._dataStore:get(key)
		end,
	})
	if not peek.ok or not Record.isRecord(peek.value.value) then
		return nil
	end
	return (peek.value.value :: Record.Record).meta.revision
end

function ProfileStore._editAnswered(self: ProfileStore, message: Handoff.Message)
	local id = message.id
	if type(id) ~= "string" then
		return
	end
	local pending = self._pendingEdits[id]
	if pending == nil or pending.done then
		return
	end
	self._pendingEdits[id] = nil
	pending.done = true
	local errorValue = message.error
	pending.answer = {
		ok = message.ok == true,
		revision = if type(message.revision) == "number" then message.revision else nil,
		error = if type(errorValue) == "table" then errorValue :: any else nil,
	}
	self._services.clock:resume(pending.thread)
end

local function summarize(record: Document.CommitRecord): AuditEntry
	local ops = {}
	for _, call in record.ops do
		table.insert(ops, call.name)
	end
	local paths = {}
	for path in record.diff do
		table.insert(paths, path)
	end
	table.sort(paths)
	return {
		revision = record.revision,
		source = record.source.kind,
		userId = record.source.userId,
		note = record.note,
		ops = ops,
		paths = paths,
		at = record.timestamp,
	}
end

-- Commit telemetry for change logs: revision, source, note, ops and changed paths. Built only
-- while something listens, so a game nobody inspects pays nothing for it
function ProfileStore._publishCommits(self: ProfileStore, key: string, profile: Profile.Profile)
	profile:onCommit(function(record: Document.CommitRecord)
		if not Bus.listening() then
			return
		end
		local entry = summarize(record)
		Bus.publish("profileCommitted", {
			store = self.name,
			key = key,
			revision = entry.revision,
			source = entry.source,
			player = entry.userId,
			note = entry.note,
			ops = entry.ops,
			paths = entry.paths,
		}, entry.at)
	end)
end

function ProfileStore._auditKey(_self: ProfileStore, key: string, revision: number): string
	return `{key}/{revision}`
end

-- Buffers commit summaries and writes them as one batch after each save. A batch is keyed
-- by its last revision and remembers its first, so the log can be walked back from the
-- current revision one batch at a time
function ProfileStore._auditProfile(self: ProfileStore, key: string, profile: Profile.Profile)
	local audit = self._audit :: Types.DataStore
	local pending: { AuditEntry } = {}
	profile:onCommit(function(record: Document.CommitRecord)
		table.insert(pending, summarize(record))
	end)
	profile.saved:connect(function(revision: number)
		local batch: { AuditEntry } = {}
		local kept: { AuditEntry } = {}
		for _, entry in pending do
			table.insert(if entry.revision <= revision then batch else kept, entry)
		end
		pending = kept
		if #batch == 0 then
			return
		end
		local from, to = batch[1].revision, batch[#batch].revision
		self._services.clock:spawn(function()
			local written = self._scheduler:submit({
				priority = "background",
				budget = "standardWrite",
				key = `audit/{self.name}/{key}`,
				write = true,
				run = function()
					return audit:set(
						self:_auditKey(key, to),
						{ from = from, to = to, entries = batch }
					)
				end,
			})
			if not written.ok then
				self._report(`couldn't write the audit log of {key}: {written.error.message}`)
			end
		end)
	end)
end

--[=[
	The audit log of `key`, newest batch first, walked back from the current revision. Stops at
	the first missing batch. Only stores made with `audit = true` keep one

	@within ProfileStore
]=]
function ProfileStore.auditLog(
	self: ProfileStore,
	key: string,
	maxBatches: number?
): Types.Result<{ AuditBatch }>
	local audit = self._audit
	if audit == nil then
		return {
			ok = false,
			error = { kind = "invalidValue", message = `{self.name} doesn't keep an audit log` },
		}
	end
	-- Start from the stored revision. An open profile can be ahead with unsaved commits,
	-- and those have no batch
	local revision: number
	do
		local read = self._dataStore:get(key)
		if not read.ok then
			return { ok = false, error = read.error }
		end
		if not Record.isRecord(read.value.value) then
			return { ok = true, value = {} }
		end
		revision = (read.value.value :: Record.Record).meta.revision
	end

	local batches: { AuditBatch } = {}
	local cursor = revision
	while cursor > 0 and #batches < (maxBatches or 20) do
		local read = audit:get(self:_auditKey(key, cursor))
		if not read.ok then
			return { ok = false, error = read.error }
		end
		local batch = read.value.value
		if type(batch) ~= "table" then
			-- Not saved yet, or written before auditing was on. Look one revision lower once
			if #batches == 0 and cursor == revision then
				cursor -= 1
				continue
			end
			break
		end
		table.insert(batches, batch :: AuditBatch)
		cursor = (batch :: AuditBatch).from - 1
	end
	return { ok = true, value = batches }
end

-- Best effort, removes every audit batch of `key` it can reach. The data itself is
-- already gone by now
function ProfileStore._eraseAudit(self: ProfileStore, key: string)
	local audit = self._audit :: Types.DataStore
	local queueKey = `audit/{self.name}/{key}`
	-- Wait out audit writes already queued for this key, so none lands after the removals
	self._scheduler:submit({
		priority = "background",
		key = queueKey,
		write = true,
		run = function()
			return { ok = true, value = nil }
		end,
	})
	local log = self:auditLog(key, math.huge)
	if not log.ok then
		self._report(`couldn't read the audit log of {key} to erase it: {log.error.message}`)
		return
	end
	for _, batch in log.value do
		self._scheduler:submit({
			priority = "background",
			budget = "standardRemove",
			key = queueKey,
			write = true,
			run = function()
				return audit:remove(self:_auditKey(key, batch.to))
			end,
		})
	end
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

--[=[
	The keys of every profile this server holds open in the store, sorted

	@within ProfileStore
]=]
function ProfileStore.openKeys(self: ProfileStore): { string }
	local keys = {}
	for key in self._open do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

--[=[
	What tooling may read about a profile open on this server: its data in stored form, where its
	codec values sit, its revision, state and session. The stored form crosses a Bindable intact,
	where live datatypes and some tables would not. Nil when the key isn't open here

	@within ProfileStore
]=]
function ProfileStore.inspect(self: ProfileStore, key: string): Inspection?
	local open: unknown = self._open[key]
	if open == nil then
		return nil
	end
	local profile = self._open[key]
	local snapshot = profile:snapshot()
	local schema = self._schema
	local stored = if schema then Validate.encode(schema, snapshot) else snapshot
	local codecs: { [string]: string } = if schema then Validate.codecPaths(schema, stored) else {}
	return {
		data = stored,
		codecs = codecs,
		revision = profile:revision(),
		state = profile:state(),
		session = profile:sessionId(),
	}
end

--[=[
	How many profiles this server holds open in the store

	@within ProfileStore
]=]
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

	@param reason ReleaseReason? -- what beforeRelease hears, "shutdown" by default
	@return number -- how many releases finished in time
]=]
function ProfileStore.releaseAll(self: ProfileStore, reason: Profile.ReleaseReason?): number
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
			local result = profile:release(reason or "shutdown")
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

--[=[
	Releases every open profile, with "destroy" as beforeRelease's reason, then stops listening
	for other servers' requests and refuses loads from then on. Yields until the releases finish
	or the close timeout passes

	@within ProfileStore
	@return number -- how many releases finished in time
]=]
function ProfileStore.destroy(self: ProfileStore): number
	self._destroyed = true
	self:_leaveSiblings()
	local finished = self:releaseAll("destroy")
	self._handoff:stop()
	return finished
end

return ProfileStore
