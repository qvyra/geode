--!strict

-- Checks what Lune can't: how the live Roblox services behave. Every store, map, queue and topic
-- it touches is named after this place and a run id, so it never touches real game data.
-- README.md next to this file says how to run it and what each check settles

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")

-- The Rojo project mirrors the repo layout, so these paths resolve the same in Studio and here
local DataStoreContract = require("../Quartz/Contracts/DataStore")
local Geode = require("../../src")
local MemoryStoreContract = require("../Quartz/Contracts/MemoryStore")
local MessagingContract = require("../Quartz/Contracts/Messaging")
local OrderedDataStoreContract = require("../Quartz/Contracts/OrderedDataStore")
local Spec = require("../_lib/Spec")

local STORE = "GeodeStudioCheck"
local SCOPE = "geode-check"
-- fresh names each run, so leftovers from an earlier run can't skew results
local RUN = string.sub(HttpService:GenerateGUID(false), 1, 8)

local results = { pass = 0, fail = 0, observed = 0 }

local function report(kind: "pass" | "fail" | "observed", name: string, detail: string?)
	results[kind] += 1
	local line = `[{string.upper(kind)}] {name}`
	if detail then
		line ..= `: {detail}`
	end
	if kind == "fail" then
		warn(line)
	else
		print(line)
	end
end

local function check(name: string, body: () -> (boolean, string?))
	local ok, passed, detail = pcall(body)
	if not ok then
		report("fail", name, `errored: {tostring(passed)}`)
	elseif passed then
		report("pass", name, detail)
	else
		report("fail", name, detail)
	end
end

local function observe(name: string, body: () -> string)
	local ok, detail = pcall(body)
	if ok then
		report("observed", name, detail)
	else
		report("observed", name, `threw: {tostring(detail)}`)
	end
end

--// raw service behavior

local function dataStore(): DataStore
	return DataStoreService:GetDataStore(STORE, `{SCOPE}-{RUN}`)
end

-- Two threads update one key at once. Roblox should rerun the losing transform on fresh
-- data, so no increment is lost
check("UpdateAsync contention from two threads on one key", function()
	local store = dataStore()
	local key = "contention"
	local runs = 0
	local finished = 0
	local function bump(times: number)
		for _ = 1, times do
			store:UpdateAsync(key, function(current: number?)
				runs += 1
				return (current or 0) + 1
			end)
		end
		finished += 1
	end
	task.spawn(bump, 10)
	task.spawn(bump, 10)
	local deadline = os.clock() + 120
	while finished < 2 and os.clock() < deadline do
		task.wait(0.5)
	end
	local final = store:GetAsync(key)
	return final == 20,
		`final value {tostring(final)} after {runs} transform runs (20 means none was lost)`
end)

observe("GetVersionAsync with a version id that never existed", function()
	local store = dataStore()
	store:SetAsync("versions", 1)
	local value, info = store:GetVersionAsync("versions", "not-a-real-version-id")
	return `returned value {tostring(value)} and info {tostring(info)}`
end)

local function sortedKeys(items: { { key: string } }): string
	local keys = {}
	for _, item in items do
		table.insert(keys, item.key)
	end
	return `[{table.concat(keys, ", ")}]`
end

observe("sorted map GetRangeAsync with a bound holding only a key", function()
	local map = MemoryStoreService:GetSortedMap(`{STORE}-{RUN}-bounds`)
	map:SetAsync("a", 1, 120, 5)
	map:SetAsync("b", 1, 120, 1)
	map:SetAsync("c", 1, 120, 9)
	local items = map:GetRangeAsync(Enum.SortDirection.Ascending, 10, { key = "b" })
	return `items after a lower bound of key "b" only: {sortedKeys(items)}, full order is b, a, c`
end)

observe("sorted map GetRangeAsync with a bound holding only a sort key", function()
	local map = MemoryStoreService:GetSortedMap(`{STORE}-{RUN}-bounds`)
	local items = map:GetRangeAsync(Enum.SortDirection.Ascending, 10, { sortKey = 5 })
	return `items after a lower bound of sort key 5 only: {sortedKeys(items)}`
end)

observe("queue RemoveAsync with an old id after the items were read again", function()
	local queue = MemoryStoreService:GetQueue(`{STORE}-{RUN}-queue`, 5)
	queue:AddAsync("job", 120)
	local _, oldId = queue:ReadAsync(1, false, 0)
	task.wait(6)
	local again, newId = queue:ReadAsync(1, false, 0)
	queue:RemoveAsync(oldId)
	task.wait(6)
	local left = queue:ReadAsync(1, false, 0)
	return `second read got {#again} item(s) under a new id ({tostring(newId ~= oldId)}). After removing with the old id, {#left} item(s) remain (1 means the old id did nothing)`
end)

--// adapter contracts against live services

-- live services with every name moved under this run, so contracts can't touch game data
local function isolatedServices(): any
	local live = Geode.Raw.services()
	local prefix = `{STORE}-{RUN}-`
	local services = table.clone(live :: any)
	services.dataStore = function(name: string, _scope: string?)
		return live.dataStore(`{STORE}_{name}`, `{SCOPE}-{RUN}`)
	end
	services.orderedDataStore = function(name: string, _scope: string?)
		return live.orderedDataStore(`{STORE}_{name}`, `{SCOPE}-{RUN}`)
	end
	services.hashMap = function(name: string)
		return live.hashMap(prefix .. name)
	end
	services.sortedMap = function(name: string)
		return live.sortedMap(prefix .. name)
	end
	services.queue = function(name: string, timeout: number?)
		return live.queue(prefix .. name, timeout)
	end
	local messaging = live.messaging
	services.messaging = {
		publish = function(_self: any, topic: string, data: unknown)
			return messaging:publish(prefix .. topic, data)
		end,
		subscribe = function(_self: any, topic: string, handler: any)
			return messaging:subscribe(prefix .. topic, handler)
		end,
	}
	return services
end

-- The contracts drive a mock clock. On live services the same calls just run in real time
local function realClock(): any
	local clock = Geode.Raw.clock()
	local wrapper = table.clone(clock :: any)
	function wrapper.run(_self: any, body: () -> ...any): ...any
		return body()
	end
	return wrapper
end

local function fixture(): any
	return { services = isolatedServices(), clock = realClock() }
end

local suites = {
	{ name = "DataStore", define = DataStoreContract },
	{ name = "OrderedDataStore", define = OrderedDataStoreContract },
	{ name = "MemoryStore", define = MemoryStoreContract },
	{ name = "Messaging", define = MessagingContract },
}
for _, suite in suites do
	for _, result in
		Spec.run(function(api)
			suite.define(api, "live", fixture)
		end)
	do
		if result.ok then
			report("pass", `contract {result.name}`)
		else
			report("fail", `contract {result.name}`, result.message)
		end
	end
end

--// a full profile cycle

check("profile load, mutate, save, release and reload", function()
	local store = Geode.Profile.store({
		name = STORE,
		scope = `{SCOPE}-{RUN}`,
		studio = "real",
		template = { coins = 0, log = {} },
	})
	local key = "cycle"
	local first = store:load(key)
	if not first.ok then
		return false, `first load failed: {first.error.message}`
	end
	local profile = first.profile
	profile:increment("coins", 25)
	profile:append("log", "saved")
	local saved = profile:save()
	if not saved.ok then
		return false, `save failed: {saved.error.message}`
	end
	profile:append("log", "released")
	local released = profile:release()
	if not released.ok then
		return false, `release failed: {released.error.message}`
	end

	local second = store:load(key)
	if not second.ok then
		return false, `reload failed: {second.error.message}`
	end
	local coins = second.profile:get("coins")
	local log = second.profile:get("log") :: { string }
	second.profile:release()
	local ok = coins == 25 and #log == 2 and log[2] == "released"
	return ok, `reloaded coins {tostring(coins)} and log [{table.concat(log, ", ")}]`
end)

print(
	`Geode Studio checks done: {results.pass} passed, {results.fail} failed, {results.observed} observed`
)
