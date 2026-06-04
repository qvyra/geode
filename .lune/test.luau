--!strict

-- Runs every tests/**/*.spec.luau. An optional arg filters spec files by substring

local fs = require("@lune/fs")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

local Spec = require("../tests/_lib/Spec")

local TESTS_DIR = "tests"
local SUFFIX = ".spec.luau"

local function collect(dir: string, into: { string })
	local entries = fs.readDir(dir)
	table.sort(entries)
	for _, entry in entries do
		local path = `{dir}/{entry}`
		if fs.isDir(path) then
			collect(path, into)
		elseif string.sub(entry, -#SUFFIX) == SUFFIX then
			table.insert(into, path)
		end
	end
end

local filter = process.args[1]
local files: { string } = {}
collect(TESTS_DIR, files)

local passed, failed = 0, 0
for _, file in files do
	if filter and not string.find(file, filter, 1, true) then
		continue
	end

	-- Paths are relative to this script, and require takes them without the extension
	local define = require(`../{string.sub(file, 1, -#".luau" - 1)}`) :: Spec.Define
	stdio.write(stdio.style("bold") .. file .. stdio.style("reset") .. "\n")

	for _, result in Spec.run(define) do
		if result.ok then
			passed += 1
			stdio.write(`  {stdio.color("green")}pass{stdio.color("reset")} {result.name}\n`)
		else
			failed += 1
			stdio.write(`  {stdio.color("red")}FAIL{stdio.color("reset")} {result.name}\n`)
			stdio.write(`       {result.message}\n`)
		end
	end
end

stdio.write(`\n{passed} passed, {failed} failed\n`)
if failed > 0 or passed == 0 then
	process.exit(1)
end
