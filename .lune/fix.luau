--!strict

-- Applies every formatter the check suite verifies

local process = require("@lune/process")

local Files = require("./lib/Files")

local prettier =
	{ "node", "node_modules/prettier/bin/prettier.cjs", "--write", "--log-level=warn", "." }
for _, arg in Files.prettierIgnoreArgs() do
	table.insert(prettier, arg)
end

local STEPS: { { string } } = {
	{ "stylua", "src", "tests", ".lune", "example" },
	prettier,
}

for _, step in STEPS do
	local result = process.exec(step[1], { table.unpack(step, 2) }, { stdio = "inherit" })
	if not result.ok then
		process.exit(result.code)
	end
end
