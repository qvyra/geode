--!strict

-- Finds the keys a profile still has that its template dropped. Only tables the template spells
-- out with keys are read field by field. A list, an empty table and a value that isn't a table
-- are containers whose contents the template doesn't describe, so nothing in them is touched,
-- and neither is anything at or under a kept path

local Path = require("../Matrix/Path")
local Record = require("./Record")

export type Options = {
	-- Paths that stay even though the template doesn't have them, with everything under them
	keep: { Path.PathLike }?,
	-- Goes up with every template change. A server never prunes a record that a server with a
	-- higher version already wrote, so a rolling deploy can't drop keys the new template added
	version: number,
	-- Report what would go and remove nothing
	dryRun: boolean?,
}

export type Config = {
	keep: { Path.Path },
	version: number,
	dryRun: boolean,
}

-- What a server with prune on leaves in meta: its prune.version and a hash of the template's
-- shape, so other servers can tell whose template last wrote the record
export type Mark = {
	version: number,
	shape: string,
}

-- "prune": go ahead. "newer": a server with a higher version wrote the record. "mismatch": a
-- server with the same version but another template wrote it
export type Verdict = "prune" | "newer" | "mismatch"

local Prune = {}

local function isList(value: { [unknown]: unknown }): boolean
	return #value > 0
end

local function child(path: Path.Path, key: string): Path.Path
	local next = table.clone(path)
	table.insert(next, key)
	return next
end

-- a kept path at or above `path` keeps all of it
local function keptAt(keep: { Path.Path }, path: Path.Path): boolean
	for _, kept in keep do
		if Path.startsWith(path, kept) then
			return true
		end
	end
	return false
end

-- a kept path below `path` keeps part of it
local function keptBelow(keep: { Path.Path }, path: Path.Path): boolean
	for _, kept in keep do
		if #kept > #path and Path.startsWith(kept, path) then
			return true
		end
	end
	return false
end

-- Under a key the template doesn't have, everything goes except what a kept path reaches
local function undeclared(
	node: { [unknown]: unknown },
	path: Path.Path,
	keep: { Path.Path },
	found: { Path.Path }
)
	for key, value in node do
		if type(key) ~= "string" then
			continue
		end
		local at = child(path, key)
		if keptAt(keep, at) then
			continue
		end
		if keptBelow(keep, at) then
			-- a kept path through a list or a plain value can't be followed, so all of it stays
			if type(value) == "table" and not isList(value :: { [unknown]: unknown }) then
				undeclared(value :: { [unknown]: unknown }, at, keep, found)
			end
			continue
		end
		table.insert(found, at)
	end
end

local function walk(
	node: unknown,
	template: unknown,
	path: Path.Path,
	keep: { Path.Path },
	found: { Path.Path }
)
	if type(node) ~= "table" or type(template) ~= "table" then
		return
	end
	local data = node :: { [unknown]: unknown }
	local defaults = template :: { [unknown]: unknown }
	if isList(data) or isList(defaults) or next(defaults) == nil then
		return
	end
	for key, value in data do
		-- only string keys are fields. Anything else in a table the template spells out stays
		if type(key) ~= "string" then
			continue
		end
		local at = child(path, key)
		if keptAt(keep, at) then
			continue
		end
		local default = defaults[key]
		if default ~= nil then
			walk(value, default, at, keep, found)
		elseif keptBelow(keep, at) then
			if type(value) == "table" and not isList(value :: { [unknown]: unknown }) then
				undeclared(value :: { [unknown]: unknown }, at, keep, found)
			end
		else
			table.insert(found, at)
		end
	end
end

-- The fields a template spells out, with what kind of value each holds, as Prune.find reads them
local function declared(template: unknown, path: Path.Path, into: { string })
	if type(template) ~= "table" then
		return
	end
	local defaults = template :: { [unknown]: unknown }
	if isList(defaults) or next(defaults) == nil then
		return
	end
	for key, value in defaults do
		if type(key) == "string" then
			local at = child(path, key)
			table.insert(into, `{Path.format(at)}:{typeof(value)}`)
			declared(value, at, into)
		end
	end
end

-- 32-bit FNV-1a. The multiply by 16777619 is split into 2^24 + 403 so it stays exact in doubles
local function hash(text: string): string
	local value = 2166136261
	for index = 1, #text do
		value = bit32.bxor(value, string.byte(text, index))
		value = (value * 403 + bit32.lshift(value, 24)) % 4294967296
	end
	return string.format("%08x", value)
end

-- Checks the prune option and parses its kept paths. Fails on anything malformed, so a mistake
-- shows up when the game starts
function Prune.config(options: Options): Config
	assert(type(options) == "table", "prune must be a table")
	local version = options.version
	assert(
		type(version) == "number" and version >= 1 and version % 1 == 0,
		"prune needs a version: a whole number from 1 that goes up with every template change"
	)
	assert(
		options.dryRun == nil or type(options.dryRun) == "boolean",
		"prune.dryRun must be a boolean"
	)
	local keep: { Path.Path } = {}
	local given: { Path.PathLike } = options.keep or {}
	for _, path in given do
		local parsed = Path.parse(path)
		assert(#parsed > 0, "a kept path can't be the root")
		table.insert(keep, parsed)
	end
	return { keep = keep, version = version, dryRun = options.dryRun == true }
end

-- The paths in `data` that `template` no longer has, sorted, never inside a list or a kept path
function Prune.find(data: unknown, template: unknown, keep: { Path.Path }): { Path.Path }
	local found: { Path.Path } = {}
	walk(data, template, {}, keep, found)
	table.sort(found, function(a: Path.Path, b: Path.Path): boolean
		return Path.format(a) < Path.format(b)
	end)
	return found
end

-- A hash of everything that decides what Prune.find removes: the fields the template spells out
-- and the kept paths. Default values don't count
function Prune.shape(template: unknown, keep: { Path.Path }): string
	local fields: { string } = {}
	declared(template, {}, fields)
	table.sort(fields)
	local kept: { string } = {}
	for _, path in keep do
		table.insert(kept, Path.format(path))
	end
	table.sort(kept)
	return hash(`{table.concat(fields, "\n")}\nkeep\n{table.concat(kept, "\n")}`)
end

-- Whether a server with `mark` may prune a record whose meta is `meta`, read before it marks it
function Prune.verdict(meta: Record.Meta, mark: Mark): Verdict
	local version: unknown = meta.templateVersion
	if version == nil then
		return "prune"
	end
	-- anything but a number was written by hand. Leave the record be rather than guess
	if type(version) ~= "number" or version > mark.version then
		return "newer"
	end
	if
		version == mark.version
		and meta.templateShape ~= nil
		and meta.templateShape ~= mark.shape
	then
		return "mismatch"
	end
	return "prune"
end

-- Leaves `mark` in `meta`, unless a server with a higher version wrote it. That one's mark stays,
-- so servers behind it keep leaving the record alone
function Prune.mark(meta: Record.Meta, mark: Mark)
	local version: unknown = meta.templateVersion
	if type(version) == "number" and version > mark.version then
		return
	end
	meta.templateVersion = mark.version
	meta.templateShape = mark.shape
end

return Prune
