--!strict

-- Docs check. The Moonwave extractor parses every doc comment in src, so a broken one fails here
-- and not in the site build. Every ```ts sample in the guides is then compiled against the
-- typings. The ```lua samples run as Lune tests in tests/docs

local fs = require("@lune/fs")
local process = require("@lune/process")

local SAMPLES_DIR = ".cache/doc-samples"
local DOCS_DIR = "docs"

local failed = false

local extracted = process.exec("moonwave-extractor", { "extract", "src" })
if extracted.ok then
	print("doc comments: ok")
else
	print("doc comments: the Moonwave extractor refused them")
	print(extracted.stderr)
	failed = true
end

if fs.isDir(SAMPLES_DIR) then
	fs.removeDir(SAMPLES_DIR)
end
fs.writeDir(SAMPLES_DIR)

local count = 0
local names: { string } = if fs.isDir(DOCS_DIR) then fs.readDir(DOCS_DIR) else {}
for _, name in names do
	if string.sub(name, -3) ~= ".md" then
		continue
	end
	local text = fs.readFile(`{DOCS_DIR}/{name}`)
	local index = 0
	for sample in string.gmatch(text, "```ts\n(.-)```") do
		index += 1
		count += 1
		local stem = string.sub(name, 1, -4)
		fs.writeFile(`{SAMPLES_DIR}/{stem}-{index}.ts`, sample)
	end
end

if count > 0 then
	local compiled = process.exec(
		"node",
		{ "node_modules/typescript/bin/tsc", "--noEmit", "-p", "tsconfig.docs.json" }
	)
	if compiled.ok then
		print(`typescript samples: {count} compiled`)
	else
		print("typescript samples: they don't compile against the typings")
		print(compiled.stdout)
		failed = true
	end
end

if failed then
	process.exit(1)
end
