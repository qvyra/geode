--!strict

-- Runs the README quick start exactly as written, so the first code a reader copies keeps
-- working. Only the Roblox globals it touches are stubbed

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local Geode = require("../../src")
local Helpers = require("../Sapphire/Helpers")
local Polish = require("../../src/Polish")
local Record = require("../../src/Sapphire/Record")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")

type Any = any

local function quickStart(): string
	local readme = fs.readFile("README.md")
	local section = string.find(readme, "## Quick start", 1, true)
	assert(section, "README.md has no quick start section")
	local code = string.match(readme, "```lua\n(.-)```", section)
	assert(code, "the quick start has no lua block")
	return code
end

-- runs the quick start with `game` and `require` leading to Geode, returns the PlayerData it made
local function run(source: string): any
	local packages = { Geode = {} }
	local replicatedStorage = { Packages = packages }
	local made: any = nil
	local environment: { [string]: any } = {
		game = {
			GetService = function(_self: any, name: string)
				assert(name == "ReplicatedStorage", `the quick start asked for {name}`)
				return replicatedStorage
			end,
		},
		require = function(target: any)
			assert(target == packages.Geode, "the quick start required something other than Geode")
			-- Wrap players so the test can reach what the quick start made
			return setmetatable({
				players = function(options: any)
					made = Geode.players(options)
					return made
				end,
			}, { __index = Geode })
		end,
	}
	local chunk =
		luau.load(source, { debugName = "README quick start", environment = environment :: any })
	chunk()
	return made
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("README quick start", function()
		it("runs as written and gives a joining player 100 coins", function()
			Polish._reset()
			local universe = Universe.new()
			local server = universe:server()
			local warnings = {}
			Geode.setup({
				services = server,
				reportError = function(message: string)
					table.insert(warnings, message)
				end,
			})

			local PlayerData = run(quickStart())
			expect(PlayerData).never.toBeNil()

			server:join(42)
			universe.clock:advance(1)
			local player = server.players:list()[1].player
			expect(PlayerData:isLoaded(player)).toBe(true)
			expect(PlayerData:get(player):get("coins")).toBe(100)

			server:leave(42)
			universe.clock:advance(5)
			local record = Helpers.stored(universe, "42") :: Record.Record
			expect((record.data :: Any).coins).toBe(100)
			expect(record.meta.lease).toBeNil()
			-- The replicate option is accepted with one warning until replication ships
			expect(#warnings).toBe(1)
			Polish._reset()
		end)
	end)
end
