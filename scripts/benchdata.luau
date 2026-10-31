--!strict

-- Keeps bench runs in benchmarks/runs, cleaned of anything that identifies the place or a server
--
--   lune run benchdata import <results.json> --build <name> [--source-tree <id>]
--       [--bench-tree <id>] [--workflow-run <url>]
--
-- The build name says which Geode it measured, for example 0.6.0. The bench records the rest in
-- results.json. Older runs need them given: the tree ids are git's ids for src and tests/bench at
-- the commit the bench ran on (`git rev-parse <commit>:src`)

local fs = require("@lune/fs")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

local BenchResults = require("./BenchResults")

local RUNS_DIR = "benchmarks/runs"

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

local function import(args: { string })
	local path = args[2] or fail("import needs the path of a results.json")
	local given = options(args, 3)
	local results = BenchResults.decode(fs.readFile(path))
	local build = given.build or fail("import needs --build")
	-- runs from before the bench recorded these need them given
	local sourceTree = given["source-tree"]
		or results.geodeSourceTree
		or fail("import needs --source-tree")
	local benchTree = given["bench-tree"] or results.benchTree or fail("import needs --bench-tree")
	for _, tree in { sourceTree, benchTree } do
		if not string.match(tree, "^%x+$") or #tree ~= 40 then
			fail(`{tree} isn't a full git id`)
		end
	end

	local run = BenchResults.sanitize(results, {
		build = build,
		sourceTree = sourceTree,
		benchTree = benchTree,
		workflowRun = given["workflow-run"] or results.workflowRun,
	})
	if not fs.isDir(RUNS_DIR) then
		fs.writeDir(RUNS_DIR)
	end
	local target = `{RUNS_DIR}/{run.run}.json`
	fs.writeFile(target, BenchResults.encode(run))
	print(`{target}: run {run.run} from {run.date}, build {build}, {#run.tasks} tasks`)
end

local command = process.args[1]
if command == "import" then
	import(process.args)
else
	fail("usage: lune run benchdata import <results.json> --build <name> ...")
end

-- .lune/benchdata.luau requires this, and a module has to return one value
return nil
