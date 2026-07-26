--!strict

-- Data that keeps itself consistent: bundles normalize a group of fields together, reactions
-- write one thing when another changes, derived fields are computed on read. Bundles and
-- reactions run inside the triggering transaction, so guards see their writes and a
-- rejection undoes them too

local Document = require("../Matrix/Document")
local Path = require("../Matrix/Path")
local Transaction = require("../Matrix/Transaction")
local Tree = require("../Matrix/Tree")

type Path = Path.Path
type PathLike = Path.PathLike
type Transaction = Transaction.Transaction

export type Bundle = {
	kind: "bundle",
	name: string,
	fields: { Path },
	normalize: (tx: Transaction) -> (),
}

export type Reaction = {
	kind: "reaction",
	name: string,
	deps: { Path },
	writes: { Path },
	run: (tx: Transaction) -> (),
}

export type Derived = {
	kind: "derived",
	name: string,
	deps: { Path },
	compute: (state: unknown) -> unknown,
}

export type BundleOptions = {
	name: string?,
}

export type ReactionOptions = {
	name: string?,
	-- every path the reaction may write. Required, cycle detection runs off this
	writes: { PathLike },
}

export type SetOptions = {
	bundles: { Bundle }?,
	reactions: { Reaction }?,
	derived: { Derived }?,
	-- max rounds of bundles and reactions per transaction, default 8
	maxDepth: number?,
}

local Facet = {}

local DEFAULT_MAX_DEPTH = 8

local function parseAll(paths: { PathLike }, what: string): { Path }
	assert(type(paths) == "table" and #paths > 0, `{what} needs at least one path`)
	local parsed = {}
	for _, path in paths do
		table.insert(parsed, table.freeze(Path.parse(path)))
	end
	return table.freeze(parsed)
end

local function describePaths(paths: { Path }): string
	local parts = {}
	for _, path in paths do
		table.insert(parts, Path.format(path))
	end
	return table.concat(parts, ", ")
end

local function overlaps(a: { Path }, b: { Path }): boolean
	for _, left in a do
		for _, right in b do
			if Path.related(left, right) then
				return true
			end
		end
	end
	return false
end

-- Builders

--[=[
	A group of fields kept consistent by one function. It runs whenever any of the fields changes,
	and may only write those fields

	@within Geode
	@param fields { PathLike }
	@param normalize (tx: Transaction) -> ()
	@param options BundleOptions?
	@return Bundle

	```lua
	local progress = Geode.bundle({ "xp", "level" }, function(tx)
		local xp, level = tx:get("xp"), tx:get("level")
		while xp >= level * 100 do
			xp -= level * 100
			level += 1
		end
		tx:set("xp", xp)
		tx:set("level", level)
	end)
	```
]=]
function Facet.bundle(
	fields: { PathLike },
	normalize: (tx: Transaction) -> (),
	options: BundleOptions?
): Bundle
	local parsed = parseAll(fields, "a bundle")
	assert(type(normalize) == "function", "a bundle needs a normalize function")
	return table.freeze({
		kind = "bundle" :: "bundle",
		name = options and options.name or `bundle({describePaths(parsed)})`,
		fields = parsed,
		normalize = normalize,
	})
end

--[=[
	Writes `writes` whenever something in `deps` changes, inside the same transaction

	@within Geode
	@param deps { PathLike }
	@param run (tx: Transaction) -> ()
	@param options ReactionOptions
	@return Reaction

	```lua
	Geode.react({ "level" }, function(tx)
		tx:increment("coins", 50)
	end, { writes = { "coins" } })
	```
]=]
function Facet.react(
	deps: { PathLike },
	run: (tx: Transaction) -> (),
	options: ReactionOptions
): Reaction
	local parsedDeps = parseAll(deps, "a reaction")
	assert(type(run) == "function", "a reaction needs a function to run")
	assert(
		options and options.writes,
		"a reaction has to declare the paths it writes, so cycles can be found before anything runs"
	)
	local parsedWrites = parseAll(options.writes, "a reaction's writes")
	return table.freeze({
		kind = "reaction" :: "reaction",
		name = options.name
			or `reaction({describePaths(parsedDeps)} -> {describePaths(parsedWrites)})`,
		deps = parsedDeps,
		writes = parsedWrites,
		run = run,
	})
end

--[=[
	A top level field computed from `deps` when read. It's never stored or written, and only
	recomputes when a dependency changed

	@within Geode
	@param name string
	@param deps { PathLike }
	@param compute (state: unknown) -> unknown
	@return Derived
]=]
function Facet.derive(
	name: string,
	deps: { PathLike },
	compute: (state: unknown) -> unknown
): Derived
	assert(type(name) == "string" and name ~= "", "a derived field needs a name")
	assert(not string.find(name, ".", 1, true), "a derived field name can't contain dots")
	assert(type(compute) == "function", "a derived field needs a compute function")
	return table.freeze({
		kind = "derived" :: "derived",
		name = name,
		deps = parseAll(deps, "a derived field"),
		compute = compute,
	})
end

-- Graph

type Node = {
	name: string,
	reads: { Path },
	writes: { Path },
	reaction: Reaction?,
}

-- Orders reactions so each runs after everything it depends on, and errors on cycles. Bundles
-- are nodes too (they read and write their own fields), so a loop through one is caught
local function order(bundles: { Bundle }, reactions: { Reaction }): { Reaction }
	local nodes: { Node } = {}
	for _, bundle in bundles do
		table.insert(
			nodes,
			{ name = bundle.name, reads = bundle.fields, writes = bundle.fields, reaction = nil }
		)
	end
	for _, reaction in reactions do
		table.insert(nodes, {
			name = reaction.name,
			reads = reaction.deps,
			writes = reaction.writes,
			reaction = reaction,
		})
	end

	local edges: { [Node]: { Node } } = {}
	local incoming: { [Node]: number } = {}
	for _, node in nodes do
		edges[node] = {}
		incoming[node] = 0
	end
	for _, from in nodes do
		for _, to in nodes do
			local isBundleItself = from == to and from.reaction == nil
			if not isBundleItself and overlaps(from.writes, to.reads) then
				if from == to then
					error(`{from.name} writes a path it depends on, which would trigger itself`, 0)
				end
				table.insert(edges[from], to)
				incoming[to] += 1
			end
		end
	end

	local ready = {}
	for _, node in nodes do
		if incoming[node] == 0 then
			table.insert(ready, node)
		end
	end
	local sorted: { Reaction } = {}
	local visited = 0
	while #ready > 0 do
		local node = table.remove(ready, 1) :: Node
		visited += 1
		if node.reaction then
			table.insert(sorted, node.reaction)
		end
		for _, next in edges[node] do
			incoming[next] -= 1
			if incoming[next] == 0 then
				table.insert(ready, next)
			end
		end
	end

	if visited < #nodes then
		local stuck = {}
		for _, node in nodes do
			if incoming[node] > 0 then
				table.insert(stuck, node.name)
			end
		end
		table.sort(stuck)
		error(`bundles and reactions form a cycle through {table.concat(stuck, ", ")}`, 0)
	end
	return sorted
end

--// facet sets

type Fields = {
	order: { Reaction },
	_bundles: { Bundle },
	_derived: { Derived },
	_maxDepth: number,
}

local FacetSet = {}
FacetSet.__index = FacetSet

export type FacetSet = typeof(setmetatable({} :: Fields, FacetSet))

--[=[
	Validates bundles and reactions together and fixes their run order. Cycles, and reactions
	that trigger themselves, error here rather than at runtime

	@within Raw
	@param options FacetSetOptions
	@return FacetSet
]=]
function Facet.set(options: SetOptions): FacetSet
	local bundles: { Bundle } = if options.bundles then options.bundles else {}
	local reactions: { Reaction } = if options.reactions then options.reactions else {}
	local derived: { Derived } = if options.derived then options.derived else {}

	local names: { [string]: boolean } = {}
	for _, item in derived do
		assert(not names[item.name], `two derived fields are named {item.name}`)
		names[item.name] = true
	end

	local self: Fields = {
		order = table.freeze(order(bundles, reactions)),
		_bundles = table.clone(bundles),
		_derived = table.clone(derived),
		_maxDepth = options.maxDepth or DEFAULT_MAX_DEPTH,
	}
	assert(self._maxDepth >= 1, "maxDepth must be at least 1")
	return setmetatable(self, FacetSet)
end

local function touches(changes: { Tree.DiffEntry }, paths: { Path }): boolean
	for _, entry in changes do
		for _, path in paths do
			if Path.related(entry.path, path) then
				return true
			end
		end
	end
	return false
end

-- Runs one bundle or reaction and returns what it changed. Writes outside what it may write are
-- refused, which keeps the definition time cycle check honest
local function step(
	tx: Transaction,
	name: string,
	allowed: { Path },
	writer: Transaction.SourceKind,
	body: (tx: Transaction) -> ()
): { Tree.DiffEntry }
	local before = tx:get()
	body(tx)
	local changes = Tree.diff(before, tx:get())
	for _, entry in changes do
		local inside = false
		for _, path in allowed do
			if Path.startsWith(entry.path, path) then
				inside = true
				break
			end
		end
		if not inside then
			Transaction.fail(
				"error",
				`{name} wrote {Path.format(entry.path)}, which isn't among the paths it may write`
			)
		end
		tx:markWriter(Path.format(entry.path), writer)
	end
	return changes
end

local function append(target: { Tree.DiffEntry }, source: { Tree.DiffEntry })
	table.move(source, 1, #source, #target + 1, target)
end

--[=[
	The pipeline stage. Round one runs bundles touched by the caller's changes, then reactions in
	order. Later rounds only happen when reactions touched bundle members: those bundles normalize
	again and reactions see just their new writes
]=]
function FacetSet.stage(self: FacetSet): (tx: Transaction) -> ()
	return function(tx: Transaction)
		local pending = tx:diff()
		for _, entry in pending do
			tx:markWriter(Path.format(entry.path), tx.source.kind)
		end

		local round = 0
		local triggers = pending
		while true do
			round += 1
			if round > self._maxDepth then
				Transaction.fail(
					"error",
					`bundles and reactions didn't settle within {self._maxDepth} rounds`
				)
			end

			local bundleWrites: { Tree.DiffEntry } = {}
			for _, bundle in self._bundles do
				if touches(pending, bundle.fields) then
					append(
						bundleWrites,
						step(tx, bundle.name, bundle.fields, "bundle", bundle.normalize)
					)
				end
			end
			if round > 1 then
				if #bundleWrites == 0 then
					break
				end
				triggers = {}
			end
			append(triggers, bundleWrites)

			local reactionWrites: { Tree.DiffEntry } = {}
			for _, reaction in self.order do
				if touches(triggers, reaction.deps) then
					local changes =
						step(tx, reaction.name, reaction.writes, "reaction", reaction.run)
					append(triggers, changes)
					append(reactionWrites, changes)
				end
			end

			if #reactionWrites == 0 then
				break
			end
			pending = reactionWrites
		end
	end
end

-- Only recomputes when an input changed. Structural sharing means an unchanged input is the
-- very same value, so a reference compare is enough
local function cached(derived: Derived): (root: unknown) -> unknown
	local lastInputs: { unknown }? = nil
	local lastValue: unknown = nil
	return function(root: unknown): unknown
		local inputs = {}
		for index, dep in derived.deps do
			inputs[index] = Tree.get(root, dep)
		end
		if lastInputs then
			local same = true
			for index, value in inputs do
				if lastInputs[index] ~= value then
					same = false
					break
				end
			end
			if same then
				return lastValue
			end
		end
		lastInputs = inputs
		lastValue = Tree.adopt(derived.compute(root))
		return lastValue
	end
end

--[=[
	Adds the stage and the derived fields to a document. Attach it before any guard set so the
	guards see what bundles and reactions wrote
]=]
function FacetSet.attach(self: FacetSet, document: Document.Document)
	for _, derived in self._derived do
		local deps: { PathLike } = {}
		for _, dep in derived.deps do
			table.insert(deps, dep)
		end
		document:addDerived(derived.name, deps, cached(derived))
	end
	if #self._bundles > 0 or #self.order > 0 then
		document:addStage(self:stage())
	end
end

return Facet
