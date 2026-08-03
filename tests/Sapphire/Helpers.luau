--!strict

-- Builds profile stores on mock servers and reads back what really reached the DataStore

local ProfileStore = require("../../src/Sapphire/ProfileStore")
local Record = require("../../src/Sapphire/Record")
local Universe = require("../../src/Quartz/Mock/Universe")

local Helpers = {}

Helpers.STORE = "PlayerData"

export type Server = Universe.MockServer

--[=[
	A store with short timings so tests stay readable. Options override the defaults
]=]
function Helpers.store(
	server: Server,
	-- loose on purpose, the store validates options itself
	overrides: { [string]: any }?
): (ProfileStore.ProfileStore, { string })
	local reported = {}
	local options: { [string]: any } = {
		name = Helpers.STORE,
		template = { coins = 0, log = {} },
		services = server,
		autosaveInterval = 10,
		leaseTimeout = 60,
		stealAfter = 5,
		reportError = function(message: string)
			table.insert(reported, message)
		end,
	}
	local extra: { [string]: any } = overrides or {}
	for key, value in extra do
		options[key] = value
	end
	return ProfileStore.new(options :: any), reported
end

--[=[
	The record as it sits in the DataStore right now, read outside any clock thread
]=]
function Helpers.stored(universe: Universe.Universe, key: string, scope: string?): Record.Record?
	local reader = universe:server({ jobId = "reader" })
	local found: Record.Record? = nil
	universe.clock:spawn(function()
		local result = reader.dataStore(Helpers.STORE, scope):get(key)
		if result.ok then
			found = result.value.value :: Record.Record?
		end
	end)
	return found
end

--[=[
	Event ids in the stored log, in order
]=]
function Helpers.storedLog(universe: Universe.Universe, key: string): { string }
	local record = Helpers.stored(universe, key)
	if record == nil then
		return {}
	end
	return ((record.data :: { log: { string } }).log or {}) :: { string }
end

--[=[
	Counts how often each id shows up, so duplicates stand out
]=]
function Helpers.counts(list: { string }): { [string]: number }
	local counts = {}
	for _, id in list do
		counts[id] = (counts[id] or 0) + 1
	end
	return counts
end

return Helpers
