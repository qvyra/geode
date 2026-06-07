--!strict

-- Applies every formatter the check suite verifies

local process = require("@lune/process")

local STEPS: { { string } } = {
	{ "stylua", "src", "tests", ".lune" },
	{ "node", "node_modules/prettier/bin/prettier.cjs", "--write", "--log-level=warn", "." },
}

for _, step in STEPS do
	local result = process.exec(step[1], { table.unpack(step, 2) }, { stdio = "inherit" })
	if not result.ok then
		process.exit(result.code)
	end
end
