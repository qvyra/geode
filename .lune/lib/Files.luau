--!strict

-- File lists come from git so every ignore rule applies, not just .gitignore. Some tools only
-- read .gitignore on their own

local fs = require("@lune/fs")
local process = require("@lune/process")

local Files = {}

--[=[
	Lists files git tracks or would track, optionally narrowed by git pathspecs like `*.md`
]=]
function Files.list(pathspecs: { string }?): { string }
	local args = { "ls-files", "--cached", "--others", "--exclude-standard" }
	if pathspecs then
		table.move(pathspecs, 1, #pathspecs, #args + 1, args)
	end
	local result = process.exec("git", args)
	if not result.ok then
		error(`git ls-files failed: {result.stderr}`)
	end

	local files = {}
	for path in string.gmatch(result.stdout, "[^\r\n]+") do
		if fs.isFile(path) then
			table.insert(files, path)
		end
	end
	return files
end

--[=[
	Ignore file arguments for Prettier, which only reads .gitignore and misses git's other ignore
	rules
]=]
function Files.prettierIgnoreArgs(): { string }
	local result = process.exec("git", { "rev-parse", "--git-path", "info/exclude" })
	if not result.ok then
		error(`git rev-parse failed: {result.stderr}`)
	end
	local excludePath = (string.gsub(result.stdout, "%s+$", ""))
	return {
		"--ignore-path",
		".gitignore",
		"--ignore-path",
		".prettierignore",
		"--ignore-path",
		excludePath,
	}
end

return Files
