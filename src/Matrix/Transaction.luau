--!strict

-- A draft of a document's state. Ops change the draft only, and nothing becomes visible until the
-- document commits it. Throwing anywhere inside a transaction discards the draft whole

local Path = require("./Path")
local Schema = require("../Obsidian/Schema")
local Tree = require("./Tree")
local Validate = require("../Obsidian/Validate")

type Path = Path.Path
type PathLike = Path.PathLike

export type SourceKind =
	"system"
	| "reaction"
	| "bundle"
	| "player"
	| "plugin"
	| "mailbox"
	| "migration"

export type Source = {
	kind: SourceKind,
	userId: number?,
}

export type SourceLike = SourceKind | Source

export type OpCall = {
	name: string,
	args: { unknown },
}

export type TxErrorKind =
	"opFailed"
	| "unknownOp"
	| "invalidArgs"
	| "error"
	| "readOnly"
	| "busy"
	| "rejected"

export type TxError = {
	kind: TxErrorKind,
	message: string,
	-- the guard that rejected the transaction, for "rejected" errors a guard raised
	guard: string?,
}

-- What a deferred callback learns about how the transaction ended. `record` is set only when it
-- committed a change
export type Outcome = {
	committed: boolean,
	record: unknown,
	error: TxError?,
}

export type OpHandler = (tx: Transaction, ...any) -> ()

export type OpOptions = {
	-- One schema per argument. A call with other arguments fails before the handler runs
	args: { Schema.Schema }?,
	-- A name per argument, by index, for tools to show. Needs `args`, and can name fewer
	names: { string }?,
	-- A line saying what the op does, for tools to show
	description: string?,
}

-- What a custom op said about itself for tools: argument names and a description
export type OpInfo = {
	names: { string }?,
	description: string?,
}

type Fields = {
	source: Source,
	_base: unknown,
	_root: unknown,
	_ops: { OpCall },
	_depth: number,
	_allowed: { [string]: boolean },
	_open: boolean,
	_deferred: { (outcome: Outcome) -> () },
	_provenance: { [string]: SourceKind },
	-- set for a dry run, which never commits. Stages report into _findings instead of acting
	_dryRun: boolean,
	_findings: { unknown },
}

--[=[
	@class Transaction

	The draft a transaction body and its bundles, reactions and guards work on. Nothing becomes
	visible until the document commits it
]=]
local Transaction = {}
Transaction.__index = Transaction

export type Transaction = typeof(setmetatable({} :: Fields, Transaction))

local SOURCE_KINDS: { [string]: boolean } = {
	system = true,
	reaction = true,
	bundle = true,
	player = true,
	plugin = true,
	mailbox = true,
	migration = true,
}

local BUILT_IN: { [string]: boolean } = {
	set = true,
	update = true,
	increment = true,
	decrement = true,
	append = true,
	insert = true,
	remove = true,
	clear = true,
	merge = true,
}

local registry: { [string]: OpHandler } = {}
-- argument schemas of the custom ops that declared them
local argSchemas: { [string]: { Schema.Schema } } = {}
-- argument names and descriptions of the custom ops that gave them
local infos: { [string]: OpInfo } = {}

-- Errors and sources

local TX_ERROR = {}

--[=[
	Throws an error the document reports with the given kind instead of as a plain bug
]=]
function Transaction.fail(kind: TxErrorKind, message: string, guard: string?): never
	error(setmetatable({ kind = kind, message = message, guard = guard }, TX_ERROR), 0)
end

--[=[
	Turns whatever a transaction threw into a TxError
]=]
function Transaction.toError(thrown: unknown): TxError
	if type(thrown) == "table" and getmetatable(thrown :: any) == TX_ERROR then
		local tagged = thrown :: TxError
		return { kind = tagged.kind, message = tagged.message, guard = tagged.guard }
	end
	return { kind = "error", message = tostring(thrown) }
end

--[=[
	Normalizes a source given as a kind name or a full record
]=]
function Transaction.source(source: SourceLike?): Source
	if source == nil then
		return table.freeze({ kind = "system" :: SourceKind })
	end
	if type(source) == "string" then
		assert(SOURCE_KINDS[source], `unknown source {source}`)
		assert(
			source ~= "player",
			'a player source needs a userId, use { kind = "player", userId = id }'
		)
		return table.freeze({ kind = source })
	end
	assert(SOURCE_KINDS[source.kind], `unknown source {source.kind}`)
	if source.kind == "player" then
		assert(type(source.userId) == "number", "a player source needs a userId")
	end
	return table.freeze({ kind = source.kind, userId = source.userId })
end

--// registry

--[=[
	Registers an op once for the whole game. A store has to list it in its `ops` before the op
	can run there. With `args`, every call is checked against one schema per argument before the
	handler runs, and development tools can describe and decode the arguments

	`names` gives the arguments names by index and `description` says what the op does. Neither
	changes how the op runs; development tools show them instead of `arg1, arg2`. `names` needs
	`args` and may name fewer arguments than it declares

	@function op
	@within Geode
	@param name string
	@param handler OpHandler
	@param options OpOptions?

	```lua
	Geode.op("reward", function(tx, itemId: string, coins: number)
		tx:increment({ "inventory", itemId })
		tx:increment("coins", coins)
	end, {
		args = { Geode.t.string(), Geode.t.integer({ min = 1, max = 1000 }) },
		names = { "item", "coins" },
		description = "Give the player an item and some coins",
	})
	```
]=]
function Transaction.register(name: string, handler: OpHandler, options: OpOptions?)
	assert(type(name) == "string" and name ~= "", "an op needs a name")
	assert(type(handler) == "function", `op {name} needs a handler function`)
	assert(not BUILT_IN[name], `{name} is a built-in op and can't be replaced`)
	assert(registry[name] == nil, `an op named {name} is already registered`)
	local args = options and options.args
	if args ~= nil then
		assert(type(args) == "table", `op {name}'s args must be a list of schemas`)
		for index, schema in args do
			assert(
				type(schema) == "table" and type((schema :: any).kind) == "string",
				`argument {index} of op {name} isn't a schema`
			)
		end
	end
	local names = options and options.names
	if names ~= nil then
		assert(args ~= nil, `op {name} names its arguments but declares no args to name`)
		assert(type(names) == "table", `op {name}'s names must be a list of strings`)
		local count = 0
		for index, argName in names do
			count += 1
			assert(type(index) == "number", `op {name}'s names must be a list of strings`)
			assert(
				type(argName) == "string" and argName ~= "",
				`name {index} of op {name} must be a non-empty string`
			)
		end
		assert(count == #names, `op {name}'s names must be a list of strings`)
		assert(
			#names <= #(args :: { Schema.Schema }),
			`op {name} names {#names} arguments but declares {#(args :: { Schema.Schema })}`
		)
	end
	local description = options and options.description
	if description ~= nil then
		assert(
			type(description) == "string" and description ~= "",
			`op {name}'s description must be a non-empty string`
		)
	end
	if args ~= nil then
		argSchemas[name] = table.clone(args)
	end
	if names ~= nil or description ~= nil then
		infos[name] = table.freeze({
			names = if names then table.freeze(table.clone(names)) else nil,
			description = description,
		})
	end
	registry[name] = handler
end

-- The argument schemas a custom op declared, or nil when it declared none
function Transaction.opArgs(name: string): { Schema.Schema }?
	local args = argSchemas[name]
	return if args then table.clone(args) else nil
end

-- The argument names and description a custom op gave, both nil when it gave neither. Nil for
-- built-in ops and names nothing registered. The answer is frozen
function Transaction.opInfo(name: string): OpInfo?
	if registry[name] == nil then
		return nil
	end
	return infos[name] or table.freeze({})
end

-- Checks a call's arguments against the op's schemas. Fewer is fine when the missing ones are
-- optional, the schemas decide
local function checkArgs(name: string, args: { n: number, [number]: unknown })
	local schemas = argSchemas[name]
	if schemas == nil then
		return
	end
	if args.n > #schemas then
		Transaction.fail(
			"invalidArgs",
			`op {name} takes {#schemas} arguments and was given {args.n}`
		)
	end
	for index, schema in schemas do
		local result = Validate.validate(schema, args[index])
		if not result.ok then
			local issue = result.issues[1]
			local where = if issue.path ~= "" then ` at {issue.path}` else ""
			Transaction.fail("invalidArgs", `argument {index} of op {name}{where}: {issue.message}`)
		end
	end
end

function Transaction.isRegistered(name: string): boolean
	return registry[name] ~= nil or BUILT_IN[name] == true
end

-- Transaction

function Transaction.new(
	root: unknown,
	source: Source,
	allowedOps: { [string]: boolean }
): Transaction
	local self: Fields = {
		source = source,
		_base = root,
		_root = root,
		_ops = {},
		_depth = 0,
		_allowed = allowedOps,
		_open = true,
		_deferred = {},
		_provenance = {},
		_dryRun = false,
		_findings = {},
	}
	return setmetatable(self, Transaction)
end

function Transaction._ensureOpen(self: Transaction)
	if not self._open then
		Transaction.fail("error", "this transaction already ended, ops on it do nothing")
	end
end

-- Runs one op. Only direct calls get recorded, not ops called from inside another op
function Transaction._run(self: Transaction, name: string, args: { unknown }, body: () -> ())
	self:_ensureOpen()
	if self._depth == 0 then
		table.insert(self._ops, { name = name, args = Tree.adopt(args) :: { unknown } })
	end
	self._depth += 1
	local ok, err = pcall(body :: () -> ...unknown)
	self._depth -= 1
	if not ok then
		error(err, 0)
	end
end

local function parse(path: PathLike?): Path
	local ok, parsed = pcall(Path.parse, path)
	if not ok then
		Transaction.fail("opFailed", tostring(parsed))
	end
	return parsed
end

local function write(self: Transaction, path: Path, value: unknown)
	local ok, root = pcall(Tree.set, self._root, path, value)
	if not ok then
		Transaction.fail("opFailed", tostring(root))
	end
	self._root = root
end

local function isSequence(value: unknown): boolean
	if type(value) ~= "table" then
		return false
	end
	local count = 0
	for key in value :: { [unknown]: unknown } do
		if type(key) ~= "number" then
			return false
		end
		count += 1
	end
	return count == #(value :: { unknown })
end

local function where(path: Path): string
	local formatted = Path.format(path)
	return if formatted == "" then "the root" else formatted
end

--[=[
	Reads from the draft, so it sees this transaction's own writes. The value is frozen
]=]
function Transaction.get(self: Transaction, path: PathLike?): unknown
	return Tree.get(self._root, parse(path))
end

--[=[
	Reads the state as it was when the transaction began, ignoring its own writes
]=]
function Transaction.getBefore(self: Transaction, path: PathLike?): unknown
	return Tree.get(self._base, parse(path))
end

function Transaction.set(self: Transaction, path: PathLike, value: unknown)
	self:_run("set", { path, value }, function()
		write(self, parse(path), value)
	end)
end

--[=[
	Replaces the value with what `transform` returns. It receives the current frozen value
]=]
function Transaction.update(
	self: Transaction,
	path: PathLike,
	transform: (current: unknown) -> unknown
)
	self:_run("update", { path }, function()
		local parsed = parse(path)
		write(self, parsed, transform(Tree.get(self._root, parsed)))
	end)
end

local function addTo(self: Transaction, name: string, path: PathLike, amount: number)
	self:_run(name, { path, amount }, function()
		local parsed = parse(path)
		if type(amount) ~= "number" or amount ~= amount or math.abs(amount) == math.huge then
			Transaction.fail("opFailed", `{name} needs a finite number, got {tostring(amount)}`)
		end
		local current = Tree.get(self._root, parsed)
		if current ~= nil and type(current) ~= "number" then
			Transaction.fail(
				"opFailed",
				`can't {name} {where(parsed)}, it holds a {typeof(current)}`
			)
		end
		write(self, parsed, ((current :: number?) or 0) + amount)
	end)
end

function Transaction.increment(self: Transaction, path: PathLike, amount: number?)
	addTo(self, "increment", path, amount or 1)
end

function Transaction.decrement(self: Transaction, path: PathLike, amount: number?)
	local by = amount or 1
	addTo(self, "decrement", path, if type(by) == "number" then -by else by)
end

local function listAt(self: Transaction, name: string, path: Path): { unknown }
	local current = Tree.get(self._root, path)
	if current == nil then
		return {}
	end
	if not isSequence(current) then
		Transaction.fail("opFailed", `can't {name} at {where(path)}, it isn't a list`)
	end
	return table.clone(current :: { unknown })
end

--[=[
	Adds a value to the end of a list. A missing list is created
]=]
function Transaction.append(self: Transaction, path: PathLike, value: unknown)
	self:_run("append", { path, value }, function()
		local parsed = parse(path)
		local list = listAt(self, "append", parsed)
		table.insert(list, value)
		write(self, parsed, list)
	end)
end

--[=[
	Inserts a value at `index`, shifting later items up
]=]
function Transaction.insert(self: Transaction, path: PathLike, index: number, value: unknown)
	self:_run("insert", { path, index, value }, function()
		local parsed = parse(path)
		local list = listAt(self, "insert", parsed)
		if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #list + 1 then
			Transaction.fail(
				"opFailed",
				`insert index {tostring(index)} is outside 1 to {#list + 1}`
			)
		end
		table.insert(list, index, value)
		write(self, parsed, list)
	end)
end

--[=[
	Removes the value at a path. In a list the later items shift down, anywhere else the key is
	just cleared
]=]
function Transaction.remove(self: Transaction, path: PathLike)
	self:_run("remove", { path }, function()
		local parsed = parse(path)
		if #parsed == 0 then
			Transaction.fail("opFailed", "can't remove the root, use clear instead")
		end
		local parentPath = table.move(parsed, 1, #parsed - 1, 1, {})
		local last = parsed[#parsed]
		local parent = Tree.get(self._root, parentPath)
		if type(last) == "number" and isSequence(parent) then
			local list = table.clone(parent :: { unknown })
			if last <= #list then
				table.remove(list, last)
				write(self, parentPath, list)
			end
		else
			write(self, parsed, nil)
		end
	end)
end

--[=[
	Replaces the value with an empty table
]=]
function Transaction.clear(self: Transaction, path: PathLike?)
	self:_run("clear", { path }, function()
		write(self, parse(path), {})
	end)
end

--[=[
	Copies the fields of `partial` over the table at a path, leaving its other fields alone
]=]
function Transaction.merge(self: Transaction, path: PathLike?, partial: { [string]: unknown })
	self:_run("merge", { path, partial }, function()
		local parsed = parse(path)
		if type(partial) ~= "table" then
			Transaction.fail("opFailed", `merge needs a table, got a {typeof(partial)}`)
		end
		local current = Tree.get(self._root, parsed)
		if current ~= nil and type(current) ~= "table" then
			Transaction.fail(
				"opFailed",
				`can't merge into {where(parsed)}, it holds a {typeof(current)}`
			)
		end
		local merged = if current then table.clone(current :: { [unknown]: unknown }) else {}
		for key, value in partial do
			merged[key] = value
		end
		write(self, parsed, merged)
	end)
end

--[=[
	Runs a registered custom op inside this transaction
]=]
function Transaction.op(self: Transaction, name: string, ...: any)
	local handler = registry[name]
	if handler == nil then
		Transaction.fail("unknownOp", `no op named {name} is registered`)
	end
	if not self._allowed[name] then
		Transaction.fail("unknownOp", `op {name} isn't enabled on this store, add it to its ops`)
	end
	local args = table.pack(...)
	checkArgs(name, args)
	self:_run(name, table.move(args, 1, args.n, 1, {}), function()
		handler(self, table.unpack(args, 1, args.n))
	end)
end

--[=[
	Leaf changes the draft holds so far, relative to where the transaction started
]=]
function Transaction.diff(self: Transaction): { Tree.DiffEntry }
	return Tree.diff(self._base, self._root)
end

--[=[
	Runs `callback` once the transaction has settled, whether it committed, changed nothing or
	failed. Stages use it for work that must not happen inside the transaction, like firing events
	whose handlers may write to the same store
]=]
function Transaction.defer(self: Transaction, callback: (outcome: Outcome) -> ())
	self:_ensureOpen()
	table.insert(self._deferred, callback)
end

--[=[
	Records who wrote a path, keyed by its formatted form. First writer wins, so a player's own
	write never gets relabeled as a reaction's
]=]
function Transaction.markWriter(self: Transaction, pathKey: string, kind: SourceKind)
	if self._provenance[pathKey] == nil then
		self._provenance[pathKey] = kind
	end
end

--[=[
	Who wrote a path in this transaction. Paths nobody claimed belong to the transaction's source
]=]
function Transaction.writerOf(self: Transaction, pathKey: string): SourceKind
	return self._provenance[pathKey] or self.source.kind
end

function Transaction._close(self: Transaction)
	self._open = false
end

return Transaction
