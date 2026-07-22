--!strict

-- Immutable tree of plain values. A write clones only the tables along its path and shares the
-- rest, so old roots stay valid and unchanged subtrees keep their identity. That identity is
-- what makes reads safe to hand out and diffs cheap

local Path = require("./Path")

type Path = Path.Path

export type DiffEntry = {
	path: Path,
	old: unknown,
	new: unknown,
}

local Tree = {}

-- Tables this module froze itself, so known frozen all the way down. One someone else froze
-- may still have mutable children, and gets copied like anything else
local owned: { [unknown]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function adopt(value: unknown, stack: { [unknown]: boolean }): unknown
	if type(value) ~= "table" or owned[value] then
		return value
	end
	local source = value :: { [unknown]: unknown }
	if stack[source] then
		error("can't store a table that contains itself", 0)
	end
	stack[source] = true
	local copy = {}
	for key, child in source do
		copy[key] = adopt(child, stack)
	end
	stack[source] = nil
	table.freeze(copy)
	owned[copy] = true
	return copy
end

--[=[
	Returns a deeply frozen version of `value`. Subtrees already in a tree are shared, everything
	else is copied, so the caller's tables are never frozen or kept
]=]
function Tree.adopt(value: unknown): unknown
	return adopt(value, {})
end

function Tree.get(root: unknown, path: Path): unknown
	local node = root
	for _, segment in path do
		if type(node) ~= "table" then
			return nil
		end
		node = (node :: { [unknown]: unknown })[segment]
	end
	return node
end

local function setAt(node: unknown, path: Path, depth: number, value: unknown): unknown
	if depth > #path then
		return value
	end
	local segment = path[depth]
	local container: { [unknown]: unknown }
	if node == nil then
		container = {}
	elseif type(node) == "table" then
		container = table.clone(node :: { [unknown]: unknown })
	else
		local where = Path.format(table.move(path, 1, depth - 1, 1, {}))
		error(
			`can't write below {if where == "" then "the root" else where}, it holds a {typeof(node)}`,
			0
		)
	end
	container[segment] = setAt(container[segment], path, depth + 1, value)
	table.freeze(container)
	owned[container] = true
	return container
end

--[=[
	Returns a new root with `value` at `path`. Missing tables along the way are created. Writing
	nil removes the key
]=]
function Tree.set(root: unknown, path: Path, value: unknown): unknown
	return setAt(root, path, 1, Tree.adopt(value))
end

local function collect(old: unknown, new: unknown, path: Path, into: { DiffEntry })
	if old == new then
		return
	end
	if type(old) == "table" and type(new) == "table" then
		local before = old :: { [unknown]: unknown }
		local after = new :: { [unknown]: unknown }
		for key, value in before do
			local childPath = table.clone(path)
			table.insert(childPath, key :: Path.Segment)
			collect(value, after[key], childPath, into)
		end
		for key, value in after do
			if before[key] == nil then
				local childPath = table.clone(path)
				table.insert(childPath, key :: Path.Segment)
				collect(nil, value, childPath, into)
			end
		end
		return
	end
	table.insert(into, { path = path, old = old, new = new })
end

--[=[
	Deep equality, short cutting on shared subtrees
]=]
function Tree.equal(a: unknown, b: unknown): boolean
	local entries = {}
	collect(a, b, {}, entries)
	return #entries == 0
end

--[=[
	Every leaf that differs between two roots. Shared subtrees are skipped without walking them,
	so cost scales with the change, not the data
]=]
function Tree.diff(old: unknown, new: unknown): { DiffEntry }
	local entries = {}
	collect(old, new, {}, entries)
	return entries
end

return Tree
