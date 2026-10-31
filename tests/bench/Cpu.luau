--!strict

-- How long Geode takes to apply an edit to a loaded profile, in Lune against Geode's test
-- universe. Only Geode runs here: the other libraries don't do the same work for an edit (they
-- change a plain table), so a side by side number would compare different things. Not part of
-- the bench place; `lune run benchcpu` runs it and scripts/bench.luau adds it to results.json

local Geode = require("../../src")

local Cpu = {}

local BATCHES = 5
local EDITS_PER_BATCH = 1000

-- The same data the live bench uses: its template plus a 50 item inventory
local function template(): { [string]: any }
	return {
		coins = 0,
		level = 1,
		inventory = {},
		settings = { music = true, volume = 0.5 },
	}
end

local INVENTORY = table.create(50, "")
for index = 1, 50 do
	INVENTORY[index] = string.format("item-%03d", index)
end

--[=[
	Times batches of `profile:increment("coins")` on one loaded profile. Each edit runs through
	the profile's transaction pipeline and is applied and recorded for the next save, without a
	DataStore request. `clock` gives seconds, os.clock in Lune
]=]
function Cpu.run(clock: () -> number): { [string]: any }
	local universe = Geode.Testing.universe()
	local store = Geode.Profile.store({
		name = "BenchCpu",
		template = template(),
		services = universe:server(),
		reportError = function() end,
	})
	return universe.clock:run(function(): { [string]: any }
		local loaded = store:load("cpu")
		if not loaded.ok then
			error(`couldn't load the profile: {loaded.error.message}`)
		end
		local profile = loaded.profile
		profile:set("inventory", INVENTORY)

		local function batch(): number
			local started = clock()
			for _ = 1, EDITS_PER_BATCH do
				local result = profile:increment("coins")
				if not result.ok then
					error(`an edit failed: {result.error.message}`)
				end
			end
			return clock() - started
		end

		-- one batch first, so the measured ones don't pay for anything done once
		batch()
		local batches = {}
		for index = 1, BATCHES do
			batches[index] = batch()
		end
		local coins = profile:get("coins")
		profile:release()
		return {
			editsPerBatch = EDITS_PER_BATCH,
			batches = batches,
			edits = (BATCHES + 1) * EDITS_PER_BATCH,
			coins = coins,
		}
	end)
end

return Cpu
