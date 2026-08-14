--!strict

-- Full check suite, same one CI runs. Every step runs even after a failure, so one pass shows
-- everything that needs fixing

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

local Files = require("./lib/Files")

-- Pinned to the luau-lsp release in rokit.toml so the API surface only moves on purpose
local LUAU_LSP_VERSION = "1.69.0"
local ROBLOX_TYPES_URL =
	`https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/{LUAU_LSP_VERSION}/scripts/globalTypes.None.d.luau`
local ROBLOX_TYPES_PATH = `.cache/globalTypes-{LUAU_LSP_VERSION}.d.luau`
local CSPELL_LIST_PATH = ".cache/cspell-files.txt"

-- These folders alias @lune to the typedefs for one Lune version
local LUNE_LUAURC_PATHS = { "tests/.luaurc", ".lune/.luaurc" }

if not fs.isDir(".cache") then
	fs.writeDir(".cache")
end

type Step = {
	name: string,
	program: string,
	args: { string },
	cwd: string?,
}

--// setup

local function ensureRobloxTypes()
	if fs.isFile(ROBLOX_TYPES_PATH) then
		return
	end
	local response = net.request(ROBLOX_TYPES_URL)
	if not response.ok then
		error(
			`couldn't download Roblox type definitions: {response.statusCode} {response.statusMessage}`
		)
	end
	fs.writeFile(ROBLOX_TYPES_PATH, response.body)
end

-- a Lune bump in rokit.toml would otherwise show up as a wall of unresolved require errors
local function checkLuneAliases(): boolean
	local version = string.match(_VERSION, "%d+%.%d+%.%d+") :: string
	local ok = true
	for _, path in LUNE_LUAURC_PATHS do
		if not string.find(fs.readFile(path), `.typedefs/{version}/`, 1, true) then
			print(`{path} doesn't point at the typedefs for Lune {version}`)
			ok = false
		end
	end
	return ok
end

local function node(name: string, script: string, args: { string }): Step
	local fullArgs = { `node_modules/{script}` }
	table.move(args, 1, #args, 2, fullArgs)
	return { name = name, program = "node", args = fullArgs }
end

-- cspell only reads .gitignore. Piping the list through stdin sometimes exits 1 with no output,
-- so it goes through a file. Entries are absolute since cspell resolves them against the list
-- file's folder
local function cspell(): Step
	local paths = {}
	for index, path in Files.list() do
		paths[index] = `{process.cwd}/{path}`
	end
	fs.writeFile(CSPELL_LIST_PATH, table.concat(paths, "\n") .. "\n")
	return node("cspell", "cspell/bin.mjs", { "--no-progress", "--file-list", CSPELL_LIST_PATH })
end

local function prettier(): Step
	local args = { "--check", "." }
	for _, arg in Files.prettierIgnoreArgs() do
		table.insert(args, arg)
	end
	return node("prettier", "prettier/bin/prettier.cjs", args)
end

local STEPS: { Step } = {
	{ name = "stylua", program = "stylua", args = { "--check", "src", "tests", ".lune" } },
	{ name = "selene src", program = "selene", args = { "src" } },
	{ name = "selene tests", program = "selene", args = { "." }, cwd = "tests" },
	{ name = "selene studio", program = "selene", args = { "." }, cwd = "tests/studio" },
	{ name = "selene scripts", program = "selene", args = { "." }, cwd = ".lune" },
	{
		name = "luau-lsp src",
		program = "luau-lsp",
		args = {
			"analyze",
			"--platform=roblox",
			`--definitions=@roblox={ROBLOX_TYPES_PATH}`,
			"src",
		},
	},
	-- tests require src, so they need the same Roblox definitions
	{
		name = "luau-lsp tests",
		program = "luau-lsp",
		args = {
			"analyze",
			"--platform=roblox",
			`--definitions=@roblox={ROBLOX_TYPES_PATH}`,
			"tests",
		},
	},
	{
		name = "luau-lsp scripts",
		program = "luau-lsp",
		args = { "analyze", "--platform=standard", ".lune" },
	},
	{ name = "tests", program = "lune", args = { "run", "test" } },
	prettier(),
	node("eslint", "eslint/bin/eslint.js", {}),
	node("tsc", "typescript/bin/tsc", { "--noEmit", "-p", "." }),
	cspell(),
}

local BOLD = stdio.style("bold")
local RESET = stdio.style("reset")

local function header(text: string)
	stdio.write(`\n{BOLD}{stdio.color("blue")}> {text}{stdio.color("reset")}{RESET}\n`)
end

local function finish(color: stdio.Color, text: string)
	stdio.write(`\n{stdio.color(color)}{text}{stdio.color("reset")}\n`)
end

header("setup")
-- lune setup also rewrites the .luaurc in its working directory, so it runs where that's harmless
local luneSetup = process.exec("lune", { "setup" }, { cwd = ".cache" })
if not luneSetup.ok then
	print(luneSetup.stderr)
	process.exit(1)
end
ensureRobloxTypes()

local failed: { string } = {}
if not checkLuneAliases() then
	table.insert(failed, "lune aliases")
end

for _, step in STEPS do
	header(step.name)
	local ok, result = pcall(process.exec, step.program, step.args, {
		cwd = step.cwd,
		stdio = "inherit" :: "inherit",
	})
	if not ok then
		print(`couldn't start {step.program}: {result}`)
		table.insert(failed, step.name)
	elseif not result.ok then
		table.insert(failed, step.name)
	end
end

if #failed > 0 then
	finish("red", `failed: {table.concat(failed, ", ")}`)
	process.exit(1)
end
finish("green", "all checks passed")
