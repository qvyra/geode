--!strict

-- Builds Geode alone as a model file, the one attached to releases and put on the Creator Store,
-- then opens it and checks what tools rely on to find Geode wherever it's dropped: one
-- ModuleScript named Geode with the Geode tag and a GeodeVersion attribute matching the version.
-- Usage: lune run model [output path], .cache/Geode.rbxm by default

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local OUTPUT = process.args[1] or ".cache/Geode.rbxm"
local TAG = "Geode"
local ATTRIBUTE = "GeodeVersion"

local version = string.match(fs.readFile("src/Version.luau"), 'return "([^"]+)"')
assert(version, "couldn't read the version from src/Version.luau")

local build = process.exec(
	"rojo",
	{ "build", "default.project.json", "--output", OUTPUT },
	{ stdio = "inherit" :: "inherit" }
)
if not build.ok then
	process.exit(1)
end

local problems: { string } = {}
local roots = roblox.deserializeModel(fs.readFile(OUTPUT))
local root = roots[1]
if #roots ~= 1 or root.ClassName ~= "ModuleScript" or root.Name ~= "Geode" then
	table.insert(problems, "the model should hold one ModuleScript named Geode")
else
	if not root:HasTag(TAG) then
		table.insert(problems, `the module has no {TAG} tag`)
	end
	local found = root:GetAttribute(ATTRIBUTE)
	if found ~= version then
		table.insert(
			problems,
			`its {ATTRIBUTE} attribute is {tostring(found)}, src/Version.luau says {version}`
		)
	end
	local vein = root:FindFirstChild("Vein")
	if vein == nil or vein:FindFirstChild("Bridge") == nil then
		table.insert(problems, "the model has no Vein/Bridge")
	end
end

if #problems > 0 then
	for _, problem in problems do
		print(`{OUTPUT}: {problem}`)
	end
	process.exit(1)
end
print(`{OUTPUT}: Geode {version}, tagged {TAG}`)
