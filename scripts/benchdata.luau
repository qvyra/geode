--!strict

-- Keeps bench runs in benchmarks/runs and builds the bench data the docs site publishes
--
--   lune run benchdata import <results.json> [--build <name>] [--line <line>] [--notes <file>]
--       [--source-tree <id>] [--bench-tree <id>] [--workflow-run <url>]
--   lune run benchdata build
--   lune run benchdata check
--
-- import cleans a run of anything that identifies the place or a server and keeps it. The build
-- says which Geode it measured. Left out, it's the catalog's build for the run's source tree, or
-- the release whose src matches, or `unreleased-<tree>`. A build the catalog doesn't know yet is
-- added to it on the line given with --line, or the line of the last build. --notes appends what
-- a reviewer should look at to a file. The bench records the tree ids and the workflow run in
-- results.json; runs from before it did need them given, from `git rev-parse <commit>:src` and
-- `git rev-parse <commit>:tests/bench`
--
-- build writes the published files under .moonwave/static/data/benchmarks. check fails when they
-- don't match the runs and the catalog, or when a run doesn't fit the catalog

local fs = require("@lune/fs")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

local BenchPublish = require("./BenchPublish")
local BenchResults = require("./BenchResults")

local RUNS_DIR = "benchmarks/runs"
local CATALOG_PATH = "benchmarks/catalog.json"
local SCHEMA_PATH = "benchmarks/schema.json"
local OUT_DIR = ".moonwave/static/data/benchmarks"
-- check writes a copy here for scripts/validate-bench-data.mjs to hold against the schema
local CHECK_DIR = ".cache/bench-data"

local function fail(message: string): never
	stdio.ewrite(`{message}\n`)
	return process.exit(1)
end

local function options(args: { string }, from: number): { [string]: string }
	local found = {}
	local index = from
	while index <= #args do
		local name = string.match(args[index], "^%-%-(.+)$")
		local value = args[index + 1]
		if name == nil or value == nil then
			fail(`expected --name value pairs, got {args[index]}`)
		end
		found[name :: string] = value
		index += 2
	end
	return found
end

local function git(args: { string }): string?
	local result = process.exec("git", args)
	if not result.ok then
		return nil
	end
	return (string.gsub(result.stdout, "%s+$", ""))
end

-- The release whose src is this tree, if there is one
local function releaseOf(sourceTree: string): string?
	local tags = git({ "for-each-ref", "--format=%(refname:short)", "refs/tags/v*" }) or ""
	for tag in string.gmatch(tags, "[^\r\n]+") do
		if git({ "rev-parse", `{tag}:src` }) == sourceTree then
			return tag
		end
	end
	return nil
end

local function note(path: string?, line: string)
	print(line)
	if path then
		local before = if fs.isFile(path) then fs.readFile(path) else ""
		fs.writeFile(path, `{before}{line}\n`)
	end
end

--// import

local function import(args: { string })
	local path = args[2] or fail("import needs the path of a results.json")
	local given = options(args, 3)
	local results = BenchResults.decode(fs.readFile(path))
	local sourceTree = given["source-tree"]
		or results.geodeSourceTree
		or fail("import needs --source-tree for a run that didn't record it")
	local benchTree = given["bench-tree"]
		or results.benchTree
		or fail("import needs --bench-tree for a run that didn't record it")
	for _, tree in { sourceTree, benchTree } do
		if not string.match(tree, "^%x+$") or #tree ~= 40 then
			fail(`{tree} isn't a full git id`)
		end
	end

	local catalogText = fs.readFile(CATALOG_PATH)
	local catalog = BenchResults.decode(catalogText)
	local known = BenchPublish.buildOf(catalog, sourceTree)
	local release = nil
	local build = given.build
	if build == nil then
		if known == nil then
			release = releaseOf(sourceTree)
		end
		build = known
			or (release and string.gsub(release, "^v", ""))
			or `unreleased-{string.sub(sourceTree, 1, 7)}`
	end

	local entry = nil
	for _, candidate in catalog.builds do
		if candidate.id == build then
			entry = candidate
		end
	end
	if entry and not table.find(entry.sourceTrees, sourceTree) then
		fail(`build {build} in {CATALOG_PATH} doesn't list source tree {sourceTree}`)
	elseif entry == nil and known then
		fail(`source tree {sourceTree} belongs to build {known}, not {build}`)
	elseif entry == nil then
		local line = given.line or catalog.builds[#catalog.builds].line
		fs.writeFile(
			CATALOG_PATH,
			BenchPublish.addBuild(catalogText, {
				id = build,
				line = line,
				release = release,
				sourceTrees = BenchResults.array({ sourceTree }),
				note = "Added by the import on the line of the build before it.",
			})
		)
		note(
			given.notes,
			`- New build \`{build}\` in \`{CATALOG_PATH}\`, put on the \`{line}\` line. If it changed how loads, saves, releases or hops work, it needs its own line and subjects.`
		)
	end

	local run = BenchResults.sanitize(results, {
		build = build :: string,
		sourceTree = sourceTree,
		benchTree = benchTree,
		workflowRun = given["workflow-run"] or results.workflowRun,
	})
	if not fs.isDir(RUNS_DIR) then
		fs.writeDir(RUNS_DIR)
	end
	local target = `{RUNS_DIR}/{run.run}.json`
	fs.writeFile(target, BenchResults.encode(run))
	note(given.notes, `- Run \`{run.run}\` from {run.date}, build \`{build}\`, {#run.tasks} tasks`)
end

--// build and check

local function readRuns(): { any }
	local runs = {}
	local names: { string } = if fs.isDir(RUNS_DIR) then fs.readDir(RUNS_DIR) else {}
	table.sort(names)
	for _, name in names do
		if string.sub(name, -5) == ".json" then
			table.insert(runs, BenchResults.decode(fs.readFile(`{RUNS_DIR}/{name}`)))
		end
	end
	return runs
end

local function published(): { [string]: string }
	local catalog = BenchResults.decode(fs.readFile(CATALOG_PATH))
	return BenchPublish.files(catalog, readRuns(), fs.readFile(SCHEMA_PATH))
end

local function listOut(dir: string, prefix: string, into: { string })
	for _, name in fs.readDir(dir) do
		local path = `{dir}/{name}`
		if fs.isDir(path) then
			listOut(path, `{prefix}{name}/`, into)
		else
			table.insert(into, `{prefix}{name}`)
		end
	end
end

local function writeAll(dir: string, files: { [string]: string }): number
	if fs.isDir(dir) then
		fs.removeDir(dir)
	end
	local count = 0
	for path, contents in files do
		local full = `{dir}/{path}`
		local folder = string.match(full, "^(.*)/[^/]+$") :: string
		if not fs.isDir(folder) then
			fs.writeDir(folder)
		end
		fs.writeFile(full, contents)
		count += 1
	end
	return count
end

local function build()
	local count = writeAll(OUT_DIR, published())
	print(`wrote {count} files to {OUT_DIR}`)
end

local function check()
	local files = published()
	writeAll(CHECK_DIR, files)
	if not fs.isDir(OUT_DIR) then
		print(`every run fits the catalog; nothing published in {OUT_DIR} yet`)
		return
	end
	local problems = {}
	local existing = {}
	listOut(OUT_DIR, "", existing)
	for _, path in existing do
		if files[path] == nil then
			table.insert(problems, `{path} is published but no run makes it`)
		end
	end
	for path, contents in files do
		local full = `{OUT_DIR}/{path}`
		if not fs.isFile(full) then
			table.insert(problems, `{path} is missing`)
		elseif string.gsub(fs.readFile(full), "\r\n", "\n") ~= contents then
			table.insert(problems, `{path} is out of date`)
		end
	end
	if #problems > 0 then
		table.sort(problems)
		fail(`{table.concat(problems, "\n")}\nlune run benchdata build writes them again`)
	end
	print(`{OUT_DIR} matches the runs and the catalog`)
end

local command = process.args[1]
if command == "import" then
	import(process.args)
elseif command == "build" then
	build()
elseif command == "check" then
	check()
else
	fail("usage: lune run benchdata import <results.json> | build | check")
end

-- .lune/benchdata.luau requires this, and a module has to return one value
return nil
