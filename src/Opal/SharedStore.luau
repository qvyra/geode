--!strict

-- Data many servers write at once, like global config, guilds or an auction. No lease. Every
-- write is an UpdateAsync transform that runs the whole transaction pipeline on the freshest
-- stored value, so guards, bundles and reactions judge what is really there. Reads come from a
-- short lived cache; invalidation messages only make it fresher sooner

local Document = require("../Matrix/Document")
local Facet = require("../Facet/Facet")
local Guards = require("../Obsidian/Guards")
local Path = require("../Matrix/Path")
local RealServices = require("../Quartz/Real/Services")
local VeinBridge = require("../Vein/Bridge")
local GuardEvent = require("../Vein/GuardEvent")
local Reconcile = require("../Sapphire/Reconcile")
local Registry = require("../Vein/Registry")
local Scheduler = require("../Quartz/Scheduler")
local Schema = require("../Obsidian/Schema")
local Size = require("../Obsidian/Size")
local Transaction = require("../Matrix/Transaction")
local Types = require("../Quartz/Types")
local Validate = require("../Obsidian/Validate")

type PathLike = Path.PathLike

export type Options = {
	name: string,
	template: { [string]: unknown },
	services: Types.Services?,
	scope: string?,
	scheduler: Scheduler.Scheduler?,
	schema: Schema.Schema?,
	schemaVersion: number?,
	guards: { Guards.Guard }?,
	bundles: { Facet.Bundle }?,
	reactions: { Facet.Reaction }?,
	derived: { Facet.Derived }?,
	maxReactionDepth: number?,
	ops: { string }?,
	-- Seconds a cached value is served before reads fetch it again. Defaults to 30
	cacheTtl: number?,
	-- Tell other servers over MessagingService when a key changes. On by default
	invalidate: boolean?,
	sizeBudget: Size.Budget?,
	reportError: ((message: string) -> ())?,
}

export type ErrorKind = Transaction.TxErrorKind | "adapter" | "corrupt" | "tooLarge"

export type WriteResult =
	{ ok: true, record: Document.CommitRecord? }
	| { ok: false, error: { kind: ErrorKind, message: string, guard: string? } }

export type ReadResult = { ok: true, value: unknown } | { ok: false, error: Types.AdapterError }

export type Stored = {
	data: unknown,
	meta: { schemaVersion: number, revision: number, updatedAt: number },
}

type Cached = {
	document: Document.Document,
	revision: number,
	fetchedAt: number,
}

type Fields = {
	name: string,
	scope: string,
	_services: Types.Services,
	_scheduler: Scheduler.Scheduler,
	_dataStore: Types.DataStore,
	_template: { [string]: unknown },
	_schema: Schema.Schema?,
	_schemaVersion: number,
	_facets: Facet.FacetSet,
	_guards: Guards.GuardSet,
	_ops: { string }?,
	_cacheTtl: number,
	_invalidate: boolean,
	_subscribed: boolean,
	_topic: string,
	_sizeBudget: Size.Budget,
	_report: (message: string) -> (),
	-- The key whose held callbacks are running, for guard telemetry
	_guardKey: string?,
	_cache: { [string]: Cached },
}

--[=[
	@class SharedStore

	A store any server may write. Made with `Geode.Shared.store`
]=]
local SharedStore = {}
SharedStore.__index = SharedStore

export type SharedStore = typeof(setmetatable({} :: Fields, SharedStore))

local DEFAULT_CACHE_TTL = 30
local DEFAULT_SIZE_BUDGET: Size.Budget = { soft = 3000000, hard = 4000000 }
local UPDATE_BUDGET: { Types.BudgetType } = { "standardRead", "standardWrite" }

local function writeFailure(kind: ErrorKind, message: string): WriteResult
	return { ok = false, error = { kind = kind, message = message } }
end

local function isStored(value: unknown): boolean
	if type(value) ~= "table" then
		return false
	end
	local meta = (value :: { meta: unknown }).meta
	return type(meta) == "table" and type((meta :: { revision: unknown }).revision) == "number"
end

--[=[
	Creates a shared store. The template and facets are checked right away

	Every write runs inside an UpdateAsync transform, so custom guards, bundles and reactions on a
	shared store must be synchronous. One that yields fails the write with an error

	@function store
	@within Shared
	@param options SharedStoreOptions
	@return SharedStore

	```lua
	local Guilds = Geode.Shared.store({
		name = "Guilds",
		template = { members = {}, bank = 0 },
	})
	Guilds:increment("guild_42", "bank", 500)
	```
]=]
function SharedStore.new(options: Options): SharedStore
	assert(type(options.name) == "string" and options.name ~= "", "a shared store needs a name")
	assert(type(options.template) == "table", "a shared store needs a template table")
	local report = options.reportError or function(message: string)
		warn(message)
	end
	local services = options.services or RealServices.live()
	VeinBridge.ensure(services)
	local scope = options.scope or "global"

	if options.schema then
		local check = Validate.validate(options.schema, options.template, { root = "template" })
		if not check.ok then
			local issue = check.issues[1]
			error(`the template doesn't match the schema: {issue.path} {issue.message}`, 2)
		end
	end

	local guardList: { Guards.Guard } = if options.guards then table.clone(options.guards) else {}
	if options.schema then
		table.insert(guardList, 1, Guards.schema(options.schema))
	end
	local guards = Guards.set({
		guards = guardList,
		clock = services.clock,
		players = services.players,
		reportError = report,
	})
	local facets = Facet.set({
		bundles = options.bundles,
		reactions = options.reactions,
		derived = options.derived,
		maxDepth = options.maxReactionDepth,
	})
	facets:attach(Document.new({ data = options.template, reportError = report }))

	local cacheTtl = options.cacheTtl or DEFAULT_CACHE_TTL
	assert(cacheTtl >= 0, "cacheTtl can't be negative")

	local self: Fields = {
		name = options.name,
		scope = scope,
		_services = services,
		_scheduler = options.scheduler
			or Scheduler.new({ clock = services.clock, budget = services.budget }),
		_dataStore = services.dataStore(options.name, scope),
		_template = options.template,
		_schema = options.schema,
		_schemaVersion = options.schemaVersion or 1,
		_facets = facets,
		_guards = guards,
		_ops = options.ops,
		_cacheTtl = cacheTtl,
		_invalidate = options.invalidate ~= false,
		_subscribed = false,
		_topic = `geode_invalidate_{options.name}`,
		_sizeBudget = options.sizeBudget or DEFAULT_SIZE_BUDGET,
		_report = report,
		_cache = {},
	}
	local store = setmetatable(self, SharedStore)
	guards.broken:connect(function(violation: Guards.Violation)
		GuardEvent.publish(
			options.name,
			"shared",
			store._guardKey,
			violation,
			options.schema,
			services.json,
			services.clock:now()
		)
	end)
	Registry.register("sharedStore", options.name, function()
		local cached = 0
		for _ in store._cache do
			cached += 1
		end
		return { scope = scope, cachedKeys = cached }
	end)
	return store
end

-- Stored form

-- The live data in a stored value, filled in from the template. Nil and an error for anything
-- that isn't a shared record
function SharedStore._decode(self: SharedStore, value: unknown): (unknown, number?, string?)
	if value == nil then
		return Reconcile.fill({}, self._template), 0, nil
	end
	if not isStored(value) then
		return nil, nil, "it holds something that isn't a shared record"
	end
	local stored = value :: Stored
	if stored.meta.schemaVersion > self._schemaVersion then
		return nil,
			nil,
			`it was saved by schema version {stored.meta.schemaVersion}, newer than this server's`
	end
	local data = stored.data
	if self._schema then
		local ok, decoded = Validate.decode(self._schema, data)
		if not ok then
			local issues = (decoded :: { issues: { { path: string, message: string } } }).issues
			return nil, nil, `it can't be decoded: {issues[1].path} {issues[1].message}`
		end
		data = decoded
	end
	return Reconcile.fill(data, self._template), stored.meta.revision, nil
end

function SharedStore._encode(self: SharedStore, data: unknown, revision: number): Stored
	return {
		data = if self._schema then Validate.encode(self._schema, data) else data,
		meta = {
			schemaVersion = self._schemaVersion,
			revision = revision,
			updatedAt = self._services.clock:now(),
		},
	}
end

function SharedStore._schedulerKey(self: SharedStore, key: string): string
	return `dataStore/{self.name}/{self.scope}/{key}`
end

-- Cache and invalidation

function SharedStore._listen(self: SharedStore)
	if self._subscribed or not self._invalidate then
		return
	end
	self._subscribed = true
	local result = self._services.messaging:subscribe(self._topic, function(data: unknown)
		if type(data) ~= "table" then
			return
		end
		local message = data :: { key: unknown, from: unknown, revision: unknown }
		if message.from == self._services.jobId or type(message.key) ~= "string" then
			return
		end
		local cached = self._cache[message.key :: string]
		local revision = if type(message.revision) == "number" then message.revision else math.huge
		if cached and cached.revision < revision then
			cached.fetchedAt = -math.huge
		end
	end)
	if not result.ok then
		self._report(
			`couldn't listen for changes to {self.name}, reads rely on the cache lifetime: {result.error.message}`
		)
	end
end

-- Puts fresh data in the cache. Observers of the key hear about whatever changed
function SharedStore._remember(
	self: SharedStore,
	key: string,
	data: unknown,
	revision: number,
	source: Transaction.SourceLike?,
	note: string?
)
	local now = self._services.clock:now()
	local cached = self._cache[key]
	if cached == nil then
		self._cache[key] = {
			document = Document.new({
				data = data,
				revision = revision,
				reportError = self._report,
			}),
			revision = revision,
			fetchedAt = now,
		}
		return
	end
	cached.fetchedAt = now
	if revision < cached.revision then
		return
	end
	cached.revision = revision
	cached.document:transact(function(tx)
		tx:set({}, data)
	end, { source = source or "system", note = note })
end

--[=[
	Drops the cached value of `key`, so the next read fetches it
]=]
function SharedStore.invalidate(self: SharedStore, key: string)
	local cached = self._cache[key]
	if cached then
		cached.fetchedAt = -math.huge
	end
end

--// reading

--[=[
	The frozen value at `path` in `key`, or the whole value with no path. Served from the cache
	while it's fresh, fetched otherwise. Yields when it fetches

	@within SharedStore
]=]
function SharedStore.get(self: SharedStore, key: string, path: PathLike?): ReadResult
	self:_listen()
	local cached = self._cache[key]
	local now = self._services.clock:now()
	if cached == nil or now - cached.fetchedAt >= self._cacheTtl then
		local fetched = self._scheduler:submit({
			priority = "read",
			budget = "standardRead",
			key = self:_schedulerKey(key),
			coalesce = self:_schedulerKey(key),
			run = function()
				return self._dataStore:get(key)
			end,
		})
		if not fetched.ok then
			-- a placeholder from observe holds the template, not anything that was read
			if cached == nil or cached.revision < 0 then
				return { ok = false, error = fetched.error }
			end
			-- serve stale rather than nothing while the DS is struggling
			self._report(
				`couldn't refresh {self.name}/{key}, serving the cached value: {fetched.error.message}`
			)
		else
			local data, revision, problem = self:_decode(fetched.value.value)
			if problem then
				return {
					ok = false,
					error = { kind = "invalidValue", message = `{self.name}/{key}: {problem}` },
				}
			end
			self:_remember(key, data, revision :: number)
		end
		cached = self._cache[key]
	end
	return { ok = true, value = cached.document:get(path) }
end

--[=[
	Calls back after changes to `path` in `key` that this server writes or reads. Changes from
	other servers arrive when the cache refreshes

	@within SharedStore
]=]
function SharedStore.observe(
	self: SharedStore,
	key: string,
	path: PathLike,
	callback: Document.Observer
): Types.Connection
	if self._cache[key] == nil then
		self._cache[key] = {
			document = Document.new({
				data = Reconcile.fill({}, self._template),
				reportError = self._report,
			}),
			revision = -1,
			fetchedAt = -math.huge,
		}
	end
	return self._cache[key].document:observe(path, callback)
end

-- Writing

-- Runs a scratch document's held callbacks with the key noted, so guard telemetry can name it
function SharedStore._runHeld(
	self: SharedStore,
	key: string,
	document: Document.Document,
	outcome: Transaction.Outcome?
)
	self._guardKey = key
	local ok, problem = pcall(function()
		document:runHeld(outcome)
	end)
	self._guardKey = nil
	if not ok then
		error(problem, 0)
	end
end

--[=[
	Runs `body` as one transaction on the freshest stored value of `key`. The whole pipeline runs
	inside UpdateAsync, so bundles, reactions and guards see exactly what gets written. Yields

	Nothing inside the transaction may yield: not the body, and no custom guard, bundle or reaction
	of this store. A transaction that yields fails with an error instead of writing. Listeners and
	deferred callbacks run once, after the write, even when UpdateAsync ran the body more than once

	@within SharedStore
]=]
function SharedStore.transact(
	self: SharedStore,
	key: string,
	body: (tx: Transaction.Transaction) -> (),
	options: Document.TransactOptions?
): WriteResult
	self:_listen()
	local services = self._services

	-- Reset on every run. UpdateAsync may call the transform more than once
	local final: Document.Document? = nil
	local outcome: WriteResult? = nil
	local written: unknown = nil
	local writtenRevision = 0

	local result = self._scheduler:submit({
		priority = "save",
		budget = UPDATE_BUDGET,
		key = self:_schedulerKey(key),
		write = true,
		run = function()
			return self._dataStore:update(key, function(current: unknown)
				final, outcome, written = nil, nil, nil
				local data, revision, problem = self:_decode(current)
				if problem then
					outcome =
						writeFailure("corrupt", `{self.name}/{key} was left untouched: {problem}`)
					return nil
				end

				local document = Document.new({
					data = data,
					revision = revision,
					ops = self._ops,
					clock = services.clock,
					reportError = self._report,
					holdDeferred = true,
				})
				self._facets:attach(document)
				self._guards:attach(document)
				final = document

				-- own coroutine, so a yield anywhere in the pipeline gets caught here
				local thread = coroutine.create(function(): Document.TxResult
					return document:transact(body, options)
				end)
				local resumed, txResult = coroutine.resume(thread)
				if coroutine.status(thread) ~= "dead" then
					-- If the yield resumes later it finishes on this throwaway document. Its held
					-- callbacks never run, so nothing acts as if it committed
					final = nil
					outcome = writeFailure(
						"error",
						"a shared store transaction yielded. Its body and every custom guard, bundle and reaction must be synchronous"
					)
					return nil
				end
				if not resumed then
					outcome = writeFailure("error", tostring(txResult))
					return nil
				end
				local tx = txResult :: Document.TxResult
				if not tx.ok then
					outcome = { ok = false, error = tx.error }
					return nil
				end
				if tx.record == nil then
					outcome = { ok = true, record = nil }
					return nil
				end

				local stored = self:_encode(document:snapshot(), document:revision())
				local report = Size.check(services.json, stored, self._sizeBudget)
				if report.level == "hard" then
					outcome = writeFailure(
						"tooLarge",
						`{self.name}/{key} would be {report.size} bytes, over the hard limit`
					)
					return nil
				end
				outcome = { ok = true, record = tx.record }
				written = document:snapshot()
				writtenRevision = document:revision()
				return stored
			end)
		end,
	})

	local document = final
	if not result.ok then
		if document then
			self:_runHeld(key, document, {
				committed = false,
				record = nil,
				error = { kind = "error", message = result.error.message },
			})
		end
		return writeFailure("adapter", result.error.message)
	end
	if written ~= nil then
		local committed = outcome :: WriteResult
		local record = if committed.ok then committed.record else nil
		self:_remember(
			key,
			written,
			writtenRevision,
			record and record.source,
			record and record.note
		)
		if self._invalidate then
			services.clock:spawn(function()
				services.messaging:publish(
					self._topic,
					{ key = key, from = services.jobId, revision = writtenRevision }
				)
			end)
		end
	end
	if document then
		if written == nil then
			-- The scratch document may have committed in memory, but nothing reached the DataStore
			local failed = outcome
			self:_runHeld(key, document, {
				committed = false,
				record = nil,
				error = if failed and not failed.ok
					then { kind = "error", message = failed.error.message }
					else nil,
			})
		else
			self:_runHeld(key, document)
		end
	end
	return outcome or writeFailure("error", "the transform never ran")
end

-- Single-op shortcuts, one transaction each
--[=[
	Sets `path` to `value` as its own transaction in `key`, run inside UpdateAsync. Yields

	@within SharedStore
]=]
function SharedStore.set(
	self: SharedStore,
	key: string,
	path: PathLike,
	value: unknown
): WriteResult
	return self:transact(key, function(tx)
		tx:set(path, value)
	end)
end

--[=[
	Replaces the value at `path` with what `transform` returns, as its own transaction in `key`, run
	inside UpdateAsync. Yields

	@within SharedStore
]=]
function SharedStore.update(
	self: SharedStore,
	key: string,
	path: PathLike,
	transform: (current: unknown) -> unknown
): WriteResult
	return self:transact(key, function(tx)
		tx:update(path, transform)
	end)
end

--[=[
	Adds `amount` (1 by default) to the number at `path` in `key`, inside UpdateAsync. Yields

	@within SharedStore
]=]
function SharedStore.increment(
	self: SharedStore,
	key: string,
	path: PathLike,
	amount: number?
): WriteResult
	return self:transact(key, function(tx)
		tx:increment(path, amount)
	end)
end

--[=[
	Subtracts `amount` (1 by default) from the number at `path` in `key`, inside UpdateAsync.
	Yields

	@within SharedStore
]=]
function SharedStore.decrement(
	self: SharedStore,
	key: string,
	path: PathLike,
	amount: number?
): WriteResult
	return self:transact(key, function(tx)
		tx:decrement(path, amount)
	end)
end

--[=[
	Adds `value` to the end of the list at `path` in `key`, run inside UpdateAsync. Yields

	@within SharedStore
]=]
function SharedStore.append(
	self: SharedStore,
	key: string,
	path: PathLike,
	value: unknown
): WriteResult
	return self:transact(key, function(tx)
		tx:append(path, value)
	end)
end

--[=[
	Inserts `value` into the list at `path` at `index` in `key`, run inside UpdateAsync. Yields

	@within SharedStore
]=]
function SharedStore.insert(
	self: SharedStore,
	key: string,
	path: PathLike,
	index: number,
	value: unknown
): WriteResult
	return self:transact(key, function(tx)
		tx:insert(path, index, value)
	end)
end

--[=[
	Removes the value at `path` in `key`, run inside UpdateAsync. Yields

	@within SharedStore
]=]
function SharedStore.remove(self: SharedStore, key: string, path: PathLike): WriteResult
	return self:transact(key, function(tx)
		tx:remove(path)
	end)
end

--[=[
	Empties the table at `path` in `key`, or the whole value when there's no path. Runs inside
	UpdateAsync and yields

	@within SharedStore
]=]
function SharedStore.clear(self: SharedStore, key: string, path: PathLike?): WriteResult
	return self:transact(key, function(tx)
		tx:clear(path)
	end)
end

--[=[
	Copies the fields of `partial` into the table at `path` in `key`, run inside UpdateAsync. Yields

	@within SharedStore
]=]
function SharedStore.merge(
	self: SharedStore,
	key: string,
	path: PathLike?,
	partial: { [string]: unknown }
): WriteResult
	return self:transact(key, function(tx)
		tx:merge(path, partial)
	end)
end

-- `...: any` since op arguments are whatever the op declares
--[=[
	Runs the custom op `name` with the given arguments as its own transaction in `key`, run inside
	UpdateAsync. Yields

	@within SharedStore
]=]
function SharedStore.op(self: SharedStore, key: string, name: string, ...: any): WriteResult
	local args = table.pack(...)
	return self:transact(key, function(tx)
		tx:op(name, table.unpack(args, 1, args.n))
	end)
end

return SharedStore
