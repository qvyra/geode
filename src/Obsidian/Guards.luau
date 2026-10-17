--!strict

-- Guards look at the final diff of a transaction, after bundles and reactions have run, and decide
-- whether it may commit. They run as the last stage of a document's pipeline, so they see exactly
-- what would be written and a rejection rolls back everything, reaction writes included

local Document = require("../Matrix/Document")
local Path = require("../Matrix/Path")
local Schema = require("./Schema")
local Signal = require("../Quartz/Signal")
local Transaction = require("../Matrix/Transaction")
local Tree = require("../Matrix/Tree")
local Types = require("../Quartz/Types")
local Validate = require("./Validate")

type Path = Path.Path
type PathLike = Path.PathLike
type Schema = Schema.Schema

export type ActionName = "warn" | "flag" | "reject" | "rollback" | "kick"

export type GuardKind =
	"schema"
	| "range"
	| "delta"
	| "rate"
	| "rateValue"
	| "requires"
	| "subset"
	| "custom"

export type Violation = {
	guard: string,
	kind: GuardKind,
	path: string?,
	reason: string,
	action: ActionName,
	source: Transaction.Source,
	userId: number?,
	ops: { string },
	timestamp: number,
	-- The value at `path` before and after the transaction, when the path can be read back.
	-- Live values, shared with the tree, never copied
	before: unknown?,
	after: unknown?,
}

-- Decides what to do about a violation. Returning nil fails closed and rejects
export type ActionHandler = (violation: Violation) -> ActionName?

export type Action = ActionName | ActionHandler

export type GuardOptions = {
	name: string?,
	-- defaults to "reject"
	action: Action?,
	ops: { string }?,
	-- Sources this guard ignores. Rate guards skip reaction and bundle writes by default
	skipSources: { Transaction.SourceKind }?,
}

export type Context = {
	source: Transaction.Source,
	userId: number?,
	ops: { Transaction.OpCall },
	opNames: { [string]: boolean },
	now: number,
	diff: { Tree.DiffEntry },
	state: unknown,
	get: (path: PathLike?) -> unknown,
	getBefore: (path: PathLike?) -> unknown,
}

type Finding = {
	reason: string,
	path: string?,
}

type GuardState = { [string]: unknown }

export type Guard = {
	kind: GuardKind,
	name: string,
	path: Path?,
	action: Action,
	ops: { [string]: boolean }?,
	skipSources: { [string]: boolean },
	check: (ctx: Context, state: GuardState) -> { Finding },
	-- Runs after a commit that this guard checked, to record usage for rate limits
	committed: ((ctx: Context, state: GuardState) -> ())?,
}

local Guards = {}

local ACTION_RANK: { [string]: number } = {
	warn = 1,
	flag = 2,
	reject = 3,
	rollback = 3,
	kick = 4,
}

--// ================================================================ //--
--//  Helpers                                                         //--
--// ================================================================ //--

local function touched(ctx: Context, path: Path): boolean
	for _, entry in ctx.diff do
		if Path.related(entry.path, path) then
			return true
		end
	end
	return false
end

local function label(path: Path): string
	local formatted = Path.format(path)
	return if formatted == "" then "the root" else formatted
end

local function toSet(list: { unknown }?): { [string]: boolean }?
	if list == nil then
		return nil
	end
	local set: { [string]: boolean } = {}
	for _, item in list do
		set[tostring(item)] = true
	end
	return set
end

-- Rate guards limit what players do. Reactions and bundles follow from a change that was already
-- counted, and plugin edits come from a developer's tooling, so none of them count
local RATE_SKIPS: { Transaction.SourceKind } = { "reaction", "bundle", "plugin" }

local function make(
	kind: GuardKind,
	path: Path?,
	options: GuardOptions?,
	defaultSkips: { Transaction.SourceKind },
	check: (ctx: Context, state: GuardState) -> { Finding },
	committed: ((ctx: Context, state: GuardState) -> ())?
): Guard
	local action: Action = if options and options.action then options.action else "reject"
	if type(action) == "string" then
		assert(ACTION_RANK[action], `unknown guard action {action}`)
	end
	local name: string = if options and options.name
		then options.name
		elseif path then `{kind} {label(path)}`
		else kind
	local skips: { unknown } = if options and options.skipSources
		then options.skipSources
		else defaultSkips
	local guard: Guard = {
		kind = kind,
		name = name,
		path = if path then table.freeze(path) else nil,
		action = action,
		ops = toSet(options and options.ops),
		skipSources = toSet(skips) :: { [string]: boolean },
		check = check,
		committed = committed,
	}
	return table.freeze(guard)
end

local function numberAt(value: unknown): number?
	if value == nil then
		return 0
	end
	return if type(value) == "number" then value else nil
end

-- per player, or per source kind when there's no player
local function sourceKey(ctx: Context): string
	if ctx.userId then
		return `player:{ctx.userId}`
	end
	return ctx.source.kind
end

--// ================================================================ //--
--//  Builders                                                        //--
--// ================================================================ //--

--[=[
	The value at `path` must stay within bounds. Only checked when the transaction touches it

	@within guard
	@param path PathLike
	@param bounds { min: number?, max: number? }
	@param options GuardOptions?
	@return Guard

	```lua
	Geode.guard.range("coins", { min = 0 })
	```
]=]
function Guards.range(
	path: PathLike,
	bounds: { min: number?, max: number? },
	options: GuardOptions?
): Guard
	local parsed = Path.parse(path)
	assert(bounds.min or bounds.max, "a range guard needs a min or a max")
	return make("range", parsed, options, {}, function(ctx)
		if not touched(ctx, parsed) then
			return {}
		end
		local value = ctx.get(parsed)
		if value == nil then
			return {}
		end
		if type(value) ~= "number" then
			return {
				{
					path = label(parsed),
					reason = `{label(parsed)} should be a number, got a {typeof(value)}`,
				},
			}
		end
		if bounds.min and value < bounds.min then
			return {
				{
					path = label(parsed),
					reason = `{label(parsed)} is {value}, below the minimum of {bounds.min}`,
				},
			}
		end
		if bounds.max and value > bounds.max then
			return {
				{
					path = label(parsed),
					reason = `{label(parsed)} is {value}, above the maximum of {bounds.max}`,
				},
			}
		end
		return {}
	end)
end

--[=[
	A single transaction may move the number at `path` by at most `max`, or by `up` and `down`
	separately

	@within guard
	@return Guard
]=]
function Guards.delta(
	path: PathLike,
	limits: { max: number?, up: number?, down: number? },
	options: GuardOptions?
): Guard
	local parsed = Path.parse(path)
	local up = limits.up or limits.max
	local down = limits.down or limits.max
	assert(up or down, "a delta guard needs max, up or down")
	return make("delta", parsed, options, {}, function(ctx)
		if not touched(ctx, parsed) then
			return {}
		end
		local before, after = numberAt(ctx.getBefore(parsed)), numberAt(ctx.get(parsed))
		if before == nil or after == nil then
			return { { path = label(parsed), reason = `{label(parsed)} should stay a number` } }
		end
		local change = after - before
		if up and change > up then
			return {
				{
					path = label(parsed),
					reason = `{label(parsed)} rose by {change}, more than {up} at once`,
				},
			}
		end
		if down and -change > down then
			return {
				{
					path = label(parsed),
					reason = `{label(parsed)} fell by {-change}, more than {down} at once`,
				},
			}
		end
		return {}
	end)
end

local function pruned(entries: Bucket, cutoff: number): Bucket
	local kept = {}
	for _, entry in entries do
		if entry.at > cutoff then
			table.insert(kept, entry)
		end
	end
	return kept
end

type Bucket = { { at: number, amount: number } }

local function bucketsOf(state: GuardState): { [string]: Bucket }
	if state.buckets == nil then
		state.buckets = {}
	end
	return state.buckets :: { [string]: Bucket }
end

local function bucket(state: GuardState, key: string, cutoff: number): Bucket
	local buckets = bucketsOf(state)
	local existing: Bucket = buckets[key] or {}
	local kept = pruned(existing, cutoff)
	if #kept > 0 then
		buckets[key] = kept
	else
		buckets[key] = nil
	end
	return kept
end

local function record(state: GuardState, key: string, at: number, amount: number)
	local buckets = bucketsOf(state)
	local entries = buckets[key] or {}
	table.insert(entries, { at = at, amount = amount })
	buckets[key] = entries
end

--[=[
	At most `count` committed transactions may change `path` within any rolling `window` seconds,
	counted per player. Reaction and bundle writes don't count unless `skipSources` says otherwise

	@within guard
	@return Guard
]=]
function Guards.rate(
	path: PathLike,
	limit: { count: number, window: number },
	options: GuardOptions?
): Guard
	local parsed = Path.parse(path)
	assert(
		limit.count >= 1 and limit.window > 0,
		"a rate guard needs a count of at least 1 and a window"
	)
	return make("rate", parsed, options, RATE_SKIPS, function(ctx, state)
		if not touched(ctx, parsed) then
			return {}
		end
		local recent = bucket(state, sourceKey(ctx), ctx.now - limit.window)
		if #recent + 1 > limit.count then
			return {
				{
					path = label(parsed),
					reason = `{label(parsed)} changed more than {limit.count} times in {limit.window} seconds`,
				},
			}
		end
		return {}
	end, function(ctx, state)
		if touched(ctx, parsed) then
			record(state, sourceKey(ctx), ctx.now, 1)
		end
	end)
end

--[=[
	Caps how much the number at `path` may rise (`gain`) or fall (`loss`) in total within any
	rolling `window` seconds, counted per player

	@within guard
	@return Guard

	```lua
	Geode.guard.rateValue("coins", { gain = 50000, window = 60 })
	```
]=]
function Guards.rateValue(
	path: PathLike,
	limit: { gain: number?, loss: number?, window: number },
	options: GuardOptions?
): Guard
	local parsed = Path.parse(path)
	assert(limit.gain or limit.loss, "a value rate guard needs a gain or a loss limit")
	assert(limit.window > 0, "a value rate guard needs a window")

	local function change(ctx: Context): number?
		local before, after = numberAt(ctx.getBefore(parsed)), numberAt(ctx.get(parsed))
		if before == nil or after == nil then
			return nil
		end
		return after - before
	end

	return make("rateValue", parsed, options, RATE_SKIPS, function(ctx, state)
		if not touched(ctx, parsed) then
			return {}
		end
		local amount = change(ctx)
		if amount == nil then
			return { { path = label(parsed), reason = `{label(parsed)} should stay a number` } }
		end
		local gained, lost = math.max(amount, 0), math.max(-amount, 0)
		for _, entry in bucket(state, sourceKey(ctx), ctx.now - limit.window) do
			gained += math.max(entry.amount, 0)
			lost += math.max(-entry.amount, 0)
		end
		if limit.gain and gained > limit.gain then
			return {
				{
					path = label(parsed),
					reason = `{label(parsed)} gained {gained} in {limit.window} seconds, more than {limit.gain}`,
				},
			}
		end
		if limit.loss and lost > limit.loss then
			return {
				{
					path = label(parsed),
					reason = `{label(parsed)} lost {lost} in {limit.window} seconds, more than {limit.loss}`,
				},
			}
		end
		return {}
	end, function(ctx, state)
		local amount = change(ctx)
		if amount and amount ~= 0 then
			record(state, sourceKey(ctx), ctx.now, amount)
		end
	end)
end

--[=[
	`path` may only change in a transaction that also changes `other`. For example, level only
	moves when xp moved too

	@within guard
	@return Guard
]=]
function Guards.requires(path: PathLike, other: PathLike, options: GuardOptions?): Guard
	local parsed, required = Path.parse(path), Path.parse(other)
	return make("requires", parsed, options, {}, function(ctx)
		if touched(ctx, parsed) and not touched(ctx, required) then
			return {
				{
					path = label(parsed),
					reason = `{label(parsed)} changed without {label(required)} changing`,
				},
			}
		end
		return {}
	end)
end

--[=[
	Every item of the list at `path` must exist in the collection at `of`: among its values when
	it's a list, among its keys when it's a map. For example, equipped items must be owned

	@within guard
	@return Guard
]=]
function Guards.subset(path: PathLike, of: PathLike, options: GuardOptions?): Guard
	local parsed, container = Path.parse(path), Path.parse(of)
	return make("subset", parsed, options, {}, function(ctx)
		if not touched(ctx, parsed) and not touched(ctx, container) then
			return {}
		end
		local items = ctx.get(parsed)
		if items == nil then
			return {}
		end
		local collection = ctx.get(container)
		local allowed: { [unknown]: boolean } = {}
		if type(collection) == "table" then
			local source = collection :: { [unknown]: unknown }
			local isList = #source > 0
			for key, value in source do
				allowed[if isList then value else key] = true
			end
		end
		local findings = {}
		for index, item in items :: { unknown } do
			if not allowed[item] then
				local itemPath = table.clone(parsed)
				table.insert(itemPath, index)
				table.insert(findings, {
					path = label(itemPath),
					reason = `{tostring(item)} at {label(itemPath)} isn't in {label(container)}`,
				})
			end
		end
		return findings
	end)
end

-- Walks a schema along a path. Stops at kinds that have no addressable children, returning how
-- many segments it consumed, or nil when the path leaves the schema

--[=[
	Changed values must match the schema. Only the changed parts are checked, so the cost follows
	the size of the change

	@within guard
	@return Guard
]=]
function Guards.schema(schema: Schema, options: GuardOptions?): Guard
	assert(Schema.isSchema(schema), "a schema guard needs a schema")
	return make("schema", nil, options, {}, function(ctx)
		local findings: { Finding } = {}
		local checked: { [string]: boolean } = {}
		for _, entry in ctx.diff do
			local node, depth = Validate.at(schema, entry.path)
			local prefix = table.move(entry.path, 1, depth, 1, {})
			local key = Path.format(prefix)
			if checked[key] then
				continue
			end
			checked[key] = true
			local root = if key == "" then "data" else `data.{key}`
			if node == nil then
				if depth > 0 then
					table.insert(
						findings,
						{ path = root, reason = `{label(prefix)} isn't declared in the schema` }
					)
				end
				continue
			end

			-- A list that shrank leaves its old last indices as nil. That's a removal, not a hole
			local value = ctx.get(prefix)
			if value == nil and depth > 0 then
				local parentSchema = Validate.at(schema, table.move(prefix, 1, depth - 1, 1, {}))
				if parentSchema and parentSchema.kind == "array" then
					continue
				end
			end

			for _, issue in Validate.validate(node, value, { root = root }).issues do
				table.insert(findings, { path = issue.path, reason = issue.message })
			end
		end
		return findings
	end)
end

--[=[
	Any rule, written as a function of the diff, the state that would commit and the context.
	Return false plus a reason to report a violation

	@within guard
	@return Guard
]=]
function Guards.custom(
	check: (
		diff: { Tree.DiffEntry },
		state: unknown,
		ctx: Context
	) -> (boolean, string?),
	options: GuardOptions?
): Guard
	return make("custom", nil, options, {}, function(ctx)
		local ok, reason = check(ctx.diff, ctx.state, ctx)
		if ok then
			return {}
		end
		return { { path = nil, reason = reason or "custom guard refused the change" } }
	end)
end

--// ================================================================ //--
--//  Guard sets                                                      //--
--// ================================================================ //--

export type SetOptions = {
	guards: { Guard }?,
	clock: Types.Clock?,
	players: Types.Players?,
	reportError: ((message: string) -> ())?,
}

type Fields = {
	broken: Signal.Signal,
	_guards: { Guard },
	_state: { [Guard]: GuardState },
	_clock: Types.Clock?,
	_players: Types.Players?,
	_report: (message: string) -> (),
}

--[=[
	@class GuardSet

	Guards attached to a document. Made with `Geode.Raw.guards`
]=]
local GuardSet = {}
GuardSet.__index = GuardSet

export type GuardSet = typeof(setmetatable({} :: Fields, GuardSet))

--[=[
	A group of guards attached to one document. `broken` fires on every violation with full
	details, regardless of the action

	@within GuardSet
	@param options GuardSetOptions?
	@return GuardSet
]=]
function Guards.set(options: SetOptions?): GuardSet
	local report = options and options.reportError or function(message: string)
		warn(message)
	end
	local self: Fields = {
		broken = Signal.new(report),
		_guards = {},
		_state = {},
		_clock = options and options.clock,
		_players = options and options.players,
		_report = report,
	}
	local set = setmetatable(self, GuardSet)
	local initial: { Guard } = if options and options.guards then options.guards else {}
	for _, guard in initial do
		set:add(guard)
	end
	return set
end

--[=[
	Adds a guard to the set

	@within GuardSet
]=]
function GuardSet.add(self: GuardSet, guard: Guard)
	assert(type(guard) == "table" and type(guard.check) == "function", "expected a guard")
	table.insert(self._guards, guard)
	self._state[guard] = {}
end

function GuardSet._context(self: GuardSet, tx: Transaction.Transaction): Context
	local opNames = {}
	for _, call in tx._ops do
		opNames[call.name] = true
	end
	return {
		source = tx.source,
		userId = tx.source.userId,
		ops = tx._ops,
		opNames = opNames,
		now = if self._clock then self._clock:now() else os.time(),
		diff = tx:diff(),
		state = tx:get(),
		get = function(path: PathLike?): unknown
			return tx:get(path)
		end,
		getBefore = function(path: PathLike?): unknown
			return tx:getBefore(path)
		end,
	}
end

-- A guard only sees changes from sources it doesn't skip. So when a player's transaction also
-- set off reactions, rate limits count the player's own changes and let the reaction writes
-- through
local function filtered(guard: Guard, ctx: Context, tx: Transaction.Transaction): Context
	if next(guard.skipSources) == nil then
		return ctx
	end
	local kept = {}
	for _, entry in ctx.diff do
		if not guard.skipSources[tx:writerOf(Path.format(entry.path))] then
			table.insert(kept, entry)
		end
	end
	local view = table.clone(ctx)
	view.diff = kept
	return view
end

local function applies(guard: Guard, ctx: Context): boolean
	if guard.ops then
		for name in ctx.opNames do
			if guard.ops[name] then
				return true
			end
		end
		return false
	end
	return true
end

-- Before and after values for a finding's path. Schema guards report paths under a "data" root
local function valuesAt(guard: Guard, finding: Finding, ctx: Context): (unknown, unknown)
	if finding.path == nil then
		return nil, nil
	end
	local path = Path.parseFormatted(finding.path)
	if path == nil then
		return nil, nil
	end
	if guard.kind == "schema" and path[1] == "data" then
		table.remove(path, 1)
	end
	local ok, before, after = pcall(function()
		return ctx.getBefore(path), ctx.get(path)
	end)
	if not ok then
		return nil, nil
	end
	return before, after
end

local function copy(value: unknown): unknown
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, item in value :: { [unknown]: unknown } do
		out[key] = copy(item)
	end
	return out
end

local function resolve(action: Action, violation: Violation): ActionName
	if type(action) == "string" then
		return action :: ActionName
	end
	local handler = action :: ActionHandler
	local chosen = handler(violation)
	if chosen == nil or ACTION_RANK[chosen :: string] == nil then
		return "reject"
	end
	return chosen :: ActionName
end

--[=[
	The pipeline stage that evaluates every guard against a transaction
]=]
function GuardSet.stage(self: GuardSet): (tx: Transaction.Transaction) -> ()
	return function(tx: Transaction.Transaction)
		local ctx = self:_context(tx)
		local opNames = {}
		for name in ctx.opNames do
			table.insert(opNames, name)
		end
		table.sort(opNames)

		local violations: { Violation } = {}
		local checked: { { guard: Guard, ctx: Context } } = {}
		local strongest = 0
		local dryRun = tx._dryRun
		for _, guard in self._guards do
			if not applies(guard, ctx) then
				continue
			end
			local view = filtered(guard, ctx, tx)
			table.insert(checked, { guard = guard, ctx = view })
			-- a dry run checks against a copy, so rate guards never count it
			local state = if dryRun
				then copy(self._state[guard]) :: GuardState
				else self._state[guard]
			for _, finding in guard.check(view, state) do
				local before, after = valuesAt(guard, finding, ctx)
				local violation: Violation = {
					guard = guard.name,
					kind = guard.kind,
					path = finding.path,
					reason = finding.reason,
					action = "reject",
					source = ctx.source,
					userId = ctx.userId,
					ops = opNames,
					timestamp = ctx.now,
					before = before,
					after = after,
				}
				violation.action = resolve(guard.action, violation)
				table.freeze(violation)
				table.insert(violations, violation)
				strongest = math.max(strongest, ACTION_RANK[violation.action])
			end
		end

		-- A dry run reports and stops here: no signal, no kick, nothing recorded, no rejection
		if dryRun then
			for _, violation in violations do
				table.insert(tx._findings, violation)
			end
			return
		end

		tx:defer(function(outcome)
			for _, violation in violations do
				if violation.action == "warn" or violation.action == "flag" then
					self._report(`guard {violation.guard} {violation.action}: {violation.reason}`)
				end
				self.broken:fire(violation)
			end
			if strongest == ACTION_RANK.kick and ctx.userId and self._players then
				self._players:kick(ctx.userId, violations[1].reason)
			end
			if outcome.committed then
				for _, entry in checked do
					local committed = entry.guard.committed
					if committed then
						committed(entry.ctx, self._state[entry.guard])
					end
				end
			end
		end)

		if strongest >= ACTION_RANK.reject then
			local first: Violation? = nil
			for _, violation in violations do
				if ACTION_RANK[violation.action] >= ACTION_RANK.reject then
					first = violation
					break
				end
			end
			local blocking = first :: Violation
			local others = #violations - 1
			Transaction.fail(
				"rejected",
				`guard {blocking.guard}: {blocking.reason}{if others > 0
					then ` (and {others} more)`
					else ""}`,
				blocking.guard
			)
		end
	end
end

--[=[
	Adds the guard stage to a document. Attach it after every other stage so guards see the
	final diff
]=]
function GuardSet.attach(self: GuardSet, document: Document.Document)
	document:addStage(self:stage())
end

Guards.ACTION_RANK = ACTION_RANK

return Guards
