--!strict

-- In-memory state with a single write path. Every change runs as a transaction that lands whole
-- or not at all, and each landed change produces a commit record for listeners.
-- Profiles and shared stores wrap a document and add persistence

local Path = require("./Path")
local Transaction = require("./Transaction")
local Tree = require("./Tree")
local Types = require("../Quartz/Types")

type Path = Path.Path
type PathLike = Path.PathLike
type Transaction = Transaction.Transaction

export type DiffEntry = Tree.DiffEntry

export type CommitRecord = {
	revision: number,
	source: Transaction.Source,
	ops: { Transaction.OpCall },
	diff: { [string]: DiffEntry },
	timestamp: number,
	note: string?,
}

export type TxResult =
	{ ok: true, record: CommitRecord? }
	| { ok: false, error: Transaction.TxError }

export type TransactOptions = {
	source: Transaction.SourceLike?,
	note: string?,
}

-- Runs after the transaction body and before commit. It may change the draft or reject the whole
-- transaction by throwing. Guards, bundles and reactions plug in here
export type Stage = (tx: Transaction) -> ()

export type Options = {
	data: unknown?,
	revision: number?,
	ops: { string }?,
	stages: { Stage }?,
	clock: Types.Clock?,
	-- Where listener errors go. Defaults to warn
	reportError: ((message: string) -> ())?,
	-- Hold deferred callbacks until `runHeld` instead of running them after each transaction.
	-- For callers that may throw away a transaction that already committed here, e.g. a write
	-- UpdateAsync retries
	holdDeferred: boolean?,
}

type Held = {
	callbacks: { (outcome: Transaction.Outcome) -> () },
	outcome: Transaction.Outcome,
}

export type Observer = (new: unknown, old: unknown, record: CommitRecord) -> ()

-- Computed from stored state. Reads like data, but is never written or saved
type Derived = {
	name: string,
	deps: { Path },
	read: (root: unknown) -> unknown,
}

type Listener = {
	path: Path?,
	callback: (...any) -> (),
	connected: boolean,
}

type Fields = {
	_root: unknown,
	_revision: number,
	_allowed: { [string]: boolean },
	_stages: { Stage },
	_clock: Types.Clock?,
	_reportError: (message: string) -> (),
	_observers: { Listener },
	_commitListeners: { Listener },
	_busy: boolean,
	_readOnly: string?,
	_derived: { [string]: Derived },
	_holdDeferred: boolean,
	_held: { Held },
}

--[=[
	@class Document

	In-memory state with the full transaction pipeline. Profiles and shared stores are built on it,
	and `Geode.Raw.document` makes a bare one
]=]
local Document = {}
Document.__index = Document

export type Document = typeof(setmetatable({} :: Fields, Document))

--[=[
	Creates a document holding a frozen copy of `options.data`

	@within Document
	@param options DocumentOptions?
	@return Document
]=]
function Document.new(options: Options?): Document
	local allowed: { [string]: boolean } = {}
	local ops: { string } = if options and options.ops then options.ops else {}
	for _, name in ops do
		allowed[name] = true
	end
	local self: Fields = {
		_root = Tree.adopt(if options and options.data ~= nil then options.data else {}),
		_revision = options and options.revision or 0,
		_allowed = allowed,
		_stages = if options and options.stages then table.clone(options.stages) else {},
		_clock = options and options.clock,
		_reportError = options and options.reportError or function(message: string)
			warn(message)
		end,
		_observers = {},
		_commitListeners = {},
		_busy = false,
		_readOnly = nil,
		_derived = {},
		_holdDeferred = options ~= nil and options.holdDeferred == true,
		_held = {},
	}
	return setmetatable(self, Document)
end

-- Reading

--[=[
	The frozen value at a path, or the whole state with no path
]=]
function Document.get(self: Document, path: PathLike?): unknown
	local parsed = Path.parse(path)
	local derived = self:_derivedAt(parsed)
	if derived then
		return Tree.get(derived.read(self._root), table.move(parsed, 2, #parsed, 1, {}))
	end
	return Tree.get(self._root, parsed)
end

function Document._derivedAt(self: Document, path: Path): Derived?
	local first = path[1]
	return if type(first) == "string" then self._derived[first] else nil
end

--[=[
	Adds a top level field computed from `deps`. Reads like any other field through `get` and
	`observe`, but it can't be written and isn't in the snapshot. The name can't clash with a
	stored field
]=]
function Document.addDerived(
	self: Document,
	name: string,
	deps: { PathLike },
	read: (root: unknown) -> unknown
)
	assert(type(name) == "string" and name ~= "", "a derived field needs a name")
	assert(self._derived[name] == nil, `a derived field named {name} already exists`)
	assert(
		Tree.get(self._root, { name }) == nil,
		`derived field {name} clashes with a stored field of the same name`
	)
	local parsed = {}
	for _, dep in deps do
		table.insert(parsed, Path.parse(dep))
	end
	self._derived[name] = { name = name, deps = parsed, read = read }
end

--[=[
	The whole state, frozen
]=]
function Document.snapshot(self: Document): unknown
	return self._root
end

--[=[
	How many commits so far. A transaction that changed nothing doesn't count
]=]
function Document.revision(self: Document): number
	return self._revision
end

--// writing

--[=[
	Refuses every transaction from now on, with `reason` as the error. For stores that can't
	save anymore, like a profile that lost its session
]=]
function Document.setReadOnly(self: Document, reason: string)
	self._readOnly = reason
end

--[=[
	Accepts transactions again after setReadOnly
]=]
function Document.clearReadOnly(self: Document)
	self._readOnly = nil
end

--[=[
	Whether writes are refused right now

	@within Document
]=]
function Document.isReadOnly(self: Document): boolean
	return self._readOnly ~= nil
end

--[=[
	Adds a stage that runs on every transaction before it commits
]=]
function Document.addStage(self: Document, stage: Stage)
	table.insert(self._stages, stage)
end

local function failure(kind: Transaction.TxErrorKind, message: string): TxResult
	return { ok = false, error = { kind = kind, message = message } }
end

--[=[
	Runs `body` against a draft and commits the result. Anything thrown inside discards the draft
	and comes back as an error. A transaction that changes nothing commits nothing

	@param body (tx: Transaction) -> ()
	@param options TransactOptions?
	@return TxResult

	```lua
	local result = document:transact(function(tx)
		tx:decrement("coins", 100)
		tx:append("inventory", { id = "sword" })
	end, { source = "system", note = "shop purchase" })
	```
]=]
function Document.transact(
	self: Document,
	body: (tx: Transaction) -> (),
	options: TransactOptions?
): TxResult
	if self._readOnly then
		return failure("readOnly", self._readOnly)
	end
	if self._busy then
		return failure("busy", "another transaction is still running on this document")
	end

	local source = Transaction.source(options and options.source)
	local tx = Transaction.new(self._root, source, self._allowed)
	self._busy = true
	local ok, thrown = pcall(function()
		body(tx)
		for _, stage in self._stages do
			stage(tx)
		end
	end)
	self._busy = false
	tx:_close()
	if not ok then
		local err = Transaction.toError(thrown)
		self:_settle(tx, { committed = false, record = nil, error = err })
		return { ok = false, error = err }
	end

	local entries = Tree.diff(self._root, tx._root)
	for _, entry in entries do
		local derived = self:_derivedAt(entry.path)
		if derived then
			local err: Transaction.TxError = {
				kind = "rejected",
				message = `{derived.name} is a derived field and can't be written`,
			}
			self:_settle(tx, { committed = false, record = nil, error = err })
			return { ok = false, error = err }
		end
	end
	if #entries == 0 then
		self:_settle(tx, { committed = false, record = nil, error = nil })
		return { ok = true, record = nil }
	end

	local diff: { [string]: DiffEntry } = {}
	for _, entry in entries do
		diff[Path.format(entry.path)] = table.freeze({
			path = table.freeze(entry.path),
			old = entry.old,
			new = entry.new,
		})
	end

	local previous = self._root
	self._root = tx._root
	self._revision += 1
	local record: CommitRecord = table.freeze({
		revision = self._revision,
		source = source,
		ops = table.freeze(tx._ops),
		diff = table.freeze(diff),
		timestamp = if self._clock then self._clock:now() else os.time(),
		note = options and options.note,
	})
	self:_notify(previous, entries, record)
	self:_settle(tx, { committed = true, record = record, error = nil })
	return { ok = true, record = record }
end

-- Runs what stages deferred. After listeners, so a deferred write sees committed state
function Document._settle(self: Document, tx: Transaction, outcome: Transaction.Outcome)
	if self._holdDeferred then
		table.insert(self._held, { callbacks = table.clone(tx._deferred), outcome = outcome })
		return
	end
	self:_runDeferred(tx._deferred, outcome)
end

function Document._runDeferred(
	self: Document,
	callbacks: { (outcome: Transaction.Outcome) -> () },
	outcome: Transaction.Outcome
)
	for _, callback in callbacks do
		local ok, err = pcall(function()
			callback(outcome)
		end)
		if not ok then
			self._reportError(`deferred callback error: {tostring(err)}`)
		end
	end
end

--[=[
	Runs the callbacks a `holdDeferred` document kept, oldest first. `outcome` overrides the one
	they were held with, for a transaction that committed here and was then thrown away
]=]
function Document.runHeld(self: Document, outcome: Transaction.Outcome?)
	local held = self._held
	self._held = {}
	for _, entry in held do
		self:_runDeferred(entry.callbacks, outcome or entry.outcome)
	end
end

--[=[
	Sets `path` to `value` as its own transaction

	@within Document
]=]
function Document.set(self: Document, path: PathLike, value: unknown): TxResult
	return self:transact(function(tx)
		tx:set(path, value)
	end)
end

--[=[
	Replaces the value at `path` with what `transform` returns, as its own transaction

	@within Document
]=]
function Document.update(
	self: Document,
	path: PathLike,
	transform: (current: unknown) -> unknown
): TxResult
	return self:transact(function(tx)
		tx:update(path, transform)
	end)
end

--[=[
	Adds `amount`, 1 by default, to the number at `path`

	@within Document
]=]
function Document.increment(self: Document, path: PathLike, amount: number?): TxResult
	return self:transact(function(tx)
		tx:increment(path, amount)
	end)
end

--[=[
	Subtracts `amount`, 1 by default, from the number at `path`

	@within Document
]=]
function Document.decrement(self: Document, path: PathLike, amount: number?): TxResult
	return self:transact(function(tx)
		tx:decrement(path, amount)
	end)
end

--[=[
	Adds `value` to the end of the list at `path`

	@within Document
]=]
function Document.append(self: Document, path: PathLike, value: unknown): TxResult
	return self:transact(function(tx)
		tx:append(path, value)
	end)
end

--[=[
	Inserts `value` into the list at `path` at `index`

	@within Document
]=]
function Document.insert(self: Document, path: PathLike, index: number, value: unknown): TxResult
	return self:transact(function(tx)
		tx:insert(path, index, value)
	end)
end

--[=[
	Removes the value at `path`

	@within Document
]=]
function Document.remove(self: Document, path: PathLike): TxResult
	return self:transact(function(tx)
		tx:remove(path)
	end)
end

--[=[
	Empties the table at `path`, or everything with no path

	@within Document
]=]
function Document.clear(self: Document, path: PathLike?): TxResult
	return self:transact(function(tx)
		tx:clear(path)
	end)
end

--[=[
	Copies the fields of `partial` into the table at `path`

	@within Document
]=]
function Document.merge(self: Document, path: PathLike?, partial: { [string]: unknown }): TxResult
	return self:transact(function(tx)
		tx:merge(path, partial)
	end)
end

--[=[
	Runs the custom op `name` with the given arguments as its own transaction

	@within Document
]=]
function Document.op(self: Document, name: string, ...: any): TxResult
	local args = table.pack(...)
	return self:transact(function(tx)
		tx:op(name, table.unpack(args, 1, args.n))
	end)
end

-- Listening

local function connect(list: { Listener }, listener: Listener): Types.Connection
	table.insert(list, listener)
	return {
		disconnect = function()
			listener.connected = false
			local index = table.find(list, listener)
			if index then
				table.remove(list, index)
			end
		end,
	}
end

--[=[
	Calls `callback` after every commit that changed the value at `path`, with the new and old
	values. Changes inside the value and replacements of a parent both count

	@return Connection
]=]
function Document.observe(self: Document, path: PathLike, callback: Observer): Types.Connection
	return connect(self._observers, {
		path = Path.parse(path),
		callback = callback,
		connected = true,
	})
end

--[=[
	Calls `callback` with the record of every commit
]=]
function Document.onCommit(self: Document, callback: (record: CommitRecord) -> ()): Types.Connection
	return connect(self._commitListeners, {
		path = nil,
		callback = callback,
		connected = true,
	})
end

function Document._call(self: Document, listener: Listener, ...: any)
	local args = table.pack(...)
	local ok, err = pcall(function()
		listener.callback(table.unpack(args, 1, args.n))
	end)
	if not ok then
		self._reportError(`listener error: {tostring(err)}`)
	end
end

-- Observers run first, then commit listeners, each group in the order it connected. A copy of each
-- list is walked so listeners can connect or disconnect while being called
function Document._notify(
	self: Document,
	previous: unknown,
	entries: { DiffEntry },
	record: CommitRecord
)
	for _, observer in table.clone(self._observers) do
		if not observer.connected then
			continue
		end
		local path = observer.path :: Path
		local derived = self:_derivedAt(path)
		local watched: { Path } = if derived then derived.deps else { path }
		local touched = false
		for _, entry in entries do
			for _, watchedPath in watched do
				if Path.related(entry.path, watchedPath) then
					touched = true
					break
				end
			end
			if touched then
				break
			end
		end
		if not touched then
			continue
		end
		if derived then
			local rest = table.move(path, 2, #path, 1, {})
			local old = Tree.get(derived.read(previous), rest)
			local new = Tree.get(derived.read(self._root), rest)
			if not Tree.equal(old, new) then
				self:_call(observer, new, old, record)
			end
		else
			local old = Tree.get(previous, path)
			local new = Tree.get(self._root, path)
			if old ~= new then
				self:_call(observer, new, old, record)
			end
		end
	end
	for _, listener in table.clone(self._commitListeners) do
		if listener.connected then
			self:_call(listener, record)
		end
	end
end

return Document
