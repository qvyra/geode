--!strict

-- What tooling reads: a registry of what's running and the telemetry bus

local Bus = require("@self/Bus")
local Registry = require("@self/Registry")
local Types = require("./Quartz/Types")

export type ModuleReport = {
	kind: string,
	name: string,
	details: { [string]: unknown }?,
}

export type Snapshot = {
	v: number,
	idle: boolean,
	modules: { ModuleReport },
	-- optional features with nothing running, tooling shows hints for these
	missing: { string },
}

local FEATURES: { { name: string, kinds: { string } } } = {
	{ name = "Profile", kinds = { "profileStore" } },
	{ name = "Shared", kinds = { "sharedStore" } },
	{ name = "Ephemeral", kinds = { "hashMap", "sortedMap", "queue" } },
	{ name = "Presence", kinds = { "presence" } },
	{ name = "Mutex", kinds = { "mutex" } },
	{ name = "Counter", kinds = { "counter" } },
	{ name = "RateLimiter", kinds = { "rateLimiter" } },
	{ name = "JobQueue", kinds = { "jobQueue" } },
	{ name = "Matchmaker", kinds = { "matchmaker" } },
	{ name = "Ranked", kinds = { "leaderboard" } },
	{ name = "Replicator", kinds = { "replicator" } },
}

local Vein = {}

--[=[
	Everything running right now, with live details, plus the optional features nothing uses

	@within Vein
]=]
function Vein.snapshot(): Snapshot
	local modules: { ModuleReport } = {}
	local present: { [string]: boolean } = {}
	for _, entry in Registry.list() do
		present[entry.kind] = true
		local details: { [string]: unknown }? = nil
		local describe = entry.describe
		if describe then
			local ok, result = pcall(describe)
			local failed: { [string]: unknown } = { error = tostring(result) }
			details = if ok then result else failed
		end
		table.insert(modules, { kind = entry.kind, name = entry.name, details = details })
	end
	local missing = {}
	for _, feature in FEATURES do
		local used = false
		for _, kind in feature.kinds do
			if present[kind] then
				used = true
			end
		end
		if not used then
			table.insert(missing, feature.name)
		end
	end
	return { v = Bus.VERSION, idle = #modules == 0, modules = modules, missing = missing }
end

--[=[
	Calls back with every telemetry message from now on. Messages are frozen tables shaped
	`{ v, type, at, ... }`

	@within Vein
]=]
function Vein.subscribe(callback: (message: Bus.Message) -> ()): Types.Connection
	return Bus.subscribe(callback)
end

Vein.VERSION = Bus.VERSION

return table.freeze(Vein)
