--!strict

-- What's running right now as tooling sees it. Shared by Vein.snapshot and the Studio bridge

local Bus = require("./Bus")
local Registry = require("./Registry")

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

local Snapshot = {}

function Snapshot.take(): Snapshot
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

return Snapshot
