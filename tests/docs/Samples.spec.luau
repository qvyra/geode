--!strict

-- Runs every ```lua sample in docs/*.md, word for word, against mock services. Each sample gets a
-- fresh universe with one player already on the server, `game` and `require` lead to Geode, and
-- the live services Geode would reach for are swapped for that mock server while it runs. Then
-- the clock moves on so loads, saves and callbacks finish. A sample passes when nothing errors

local fs = require("@lune/fs")
local luau = require("@lune/luau")
-- datatype constructors exist at runtime but aren't in Lune's typedefs
local roblox = require("@lune/roblox") :: any

local Geode = require("../../src")
local Polish = require("../../src/Polish")
local RealServices = require("../../src/Quartz/Real/Services")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")
local VeinRegistry = require("../../src/Vein/Registry")

local DOCS_DIR = "docs"
-- seconds the clock runs after a sample so loads, autosaves and handoffs settle
local SETTLE = 120

type Sample = {
	file: string,
	index: number,
	source: string,
}

local function samples(): { Sample }
	local found = {}
	if not fs.isDir(DOCS_DIR) then
		return found
	end
	local names = fs.readDir(DOCS_DIR)
	table.sort(names)
	for _, name in names do
		if string.sub(name, -3) ~= ".md" then
			continue
		end
		local index = 0
		for source in string.gmatch(fs.readFile(`{DOCS_DIR}/{name}`), "```lua\n(.-)```") do
			index += 1
			table.insert(found, { file = name, index = index, source = source })
		end
	end
	return found
end

-- What `game:GetService` hands a sample. ReplicatedStorage leads to Geode, Players to the mock
-- server's players with a stand-in LocalPlayer
local function fakeGame(server: Universe.MockServer, packages: { [string]: unknown }): any
	local services: { [string]: unknown } = {
		ReplicatedStorage = { Packages = packages },
		Players = {
			LocalPlayer = { UserId = 1, Name = "Player1" },
			GetPlayers = function()
				local players = {}
				for _, entry in server.players:list() do
					table.insert(players, entry.player)
				end
				return players
			end,
		},
		ServerScriptService = {},
	}
	return {
		GetService = function(_self: any, name: string)
			local service = services[name]
			assert(
				service,
				`a docs sample asked for {name}, which the sample runner doesn't stand in for`
			)
			return service
		end,
	}
end

local function run(sample: Sample)
	Polish._reset()
	VeinRegistry._reset()
	local universe = Universe.new()
	local server = universe:server()
	server:join(1)

	local live, client = RealServices.live, RealServices.client
	RealServices.live = function()
		return server :: any
	end
	RealServices.client = function()
		return server:client(1)
	end

	local packages: { [string]: unknown } = { Geode = {} }
	local environment: { [string]: any } = {
		game = fakeGame(server, packages),
		require = function(target: any)
			assert(target == packages.Geode, "a docs sample required something other than Geode")
			return Geode
		end,
		warn = function() end,
		print = function() end,
		Vector3 = roblox.Vector3,
		Vector2 = roblox.Vector2,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		UDim2 = roblox.UDim2,
		Enum = roblox.Enum,
	}
	local ok, err = pcall(function()
		local chunk = luau.load(sample.source, {
			debugName = `{sample.file} sample {sample.index}`,
			environment = environment :: any,
		})
		universe.clock:spawn(chunk)
		universe.clock:advance(SETTLE)
	end)

	RealServices.live, RealServices.client = live, client
	Polish._reset()
	VeinRegistry._reset()
	if not ok then
		error(`{sample.file} sample {sample.index} failed: {tostring(err)}`, 0)
	end
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("docs samples", function()
		local all = samples()
		it("exist", function()
			expect(#all > 0).toBe(true)
		end)
		for _, sample in all do
			it(`{sample.file} sample {sample.index} runs`, function()
				run(sample)
			end)
		end
	end)
end
