--!strict

-- Checks what Lune can't: how the live Roblox services behave. Every store, map, queue and topic
-- it touches is named after this place and a run id, so it never touches real game data.
-- Studio runs it through Run.server.luau and the Open Cloud runner calls `run` directly.
-- README.md next to this file says what each check settles

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")

-- The Rojo project mirrors the repo layout, so these paths resolve the same in Studio and here
local DataStoreContract = require("../Quartz/Contracts/DataStore")
local Geode = require("../../src")
local Json = require("../../src/Quartz/Json")
local MemoryStoreContract = require("../Quartz/Contracts/MemoryStore")
local MessagingContract = require("../Quartz/Contracts/Messaging")
local OrderedDataStoreContract = require("../Quartz/Contracts/OrderedDataStore")
local Spec = require("../_lib/Spec")

export type Kind = "pass" | "fail" | "observed"

export type Result = {
	kind: Kind,
	name: string,
	detail: string?,
}

export type Report = {
	results: { Result },
	pass: number,
	fail: number,
	observed: number,
}

local STORE = "GeodeStudioCheck"
local SCOPE = "geode-check"

local Checks = {}

export type Group = "services" | "contracts" | "profile"

Checks.GROUPS = { "services", "contracts", "profile" } :: { Group }

--[=[
	Runs the checks against the live services and returns what each one found. Yields for a few
	minutes, printing each line as it finishes. `groups` limits the run to some of them, which
	the Open Cloud runner uses to stay inside a task's time limit
]=]
function Checks.run(groups: { Group }?): Report
	local function wants(group: Group): boolean
		return groups == nil or table.find(groups, group) ~= nil
	end

	-- fresh names each run, so leftovers from an earlier run can't skew results
	local RUN = string.sub(HttpService:GenerateGUID(false), 1, 8)
	local outcome: Report = { results = {}, pass = 0, fail = 0, observed = 0 }

	local function report(kind: Kind, name: string, detail: string?)
		outcome[kind] += 1
		table.insert(outcome.results, { kind = kind, name = name, detail = detail })
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

	if wants("services") then
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
			local failures = {}
			local function bump(times: number)
				for _ = 1, times do
					-- otherwise a throttle kills the thread and looks like a lost increment
					local ok, err = pcall(function()
						store:UpdateAsync(key, function(current: number?)
							runs += 1
							return (current or 0) + 1
						end)
					end)
					if not ok then
						table.insert(failures, tostring(err))
					end
				end
				finished += 1
			end
			task.spawn(bump, 5)
			task.spawn(bump, 5)
			local deadline = os.clock() + 180
			while finished < 2 and os.clock() < deadline do
				task.wait(0.5)
			end
			if #failures > 0 then
				return false, `{#failures} update(s) failed, first: {failures[1]}`
			end
			local final = store:GetAsync(key)
			return final == 10,
				`final value {tostring(final)} after {runs} transform runs (10 means none was lost)`
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

		--// behavior the code depends on

		observe(
			"HttpService:JSONEncode floats and non-ASCII text next to Geode's own encoder",
			function()
				local samples: { unknown } = {
					0.1,
					1.5,
					1 / 3,
					1e20,
					123456789012,
					-0,
					"\u{E9}",
					"\u{1F600}",
					"a\nb",
					"\u{7F}",
				}
				local lines = {}
				for _, sample in samples do
					local roblox = HttpService:JSONEncode({ sample })
					local ours = Json.encode({ sample })
					table.insert(
						lines,
						`{roblox} {if roblox == ours then "same" else `differs from {ours}`}`
					)
				end
				return table.concat(lines, "; ")
			end
		)

		observe("UpdateAsync returning no metadata on a key that has some", function()
			local store = dataStore()
			local options = Instance.new("DataStoreSetOptions")
			options:SetMetadata({ tag = "kept" })
			store:SetAsync("metadata", 1, nil, options)
			store:UpdateAsync("metadata", function(current: number?)
				return (current or 0) + 1
			end)
			local _, info = store:GetAsync("metadata")
			local metadata = if info then (info :: DataStoreKeyInfo):GetMetadata() else nil
			return `metadata afterwards: {if metadata and metadata.tag then metadata.tag else "none"} (kept means it carries over)`
		end)

		observe("sorted map GetRangeAsync with an upper bound holding only a key", function()
			local map = MemoryStoreService:GetSortedMap(`{STORE}-{RUN}-bounds`)
			local items = map:GetRangeAsync(Enum.SortDirection.Ascending, 10, nil, { key = "c" })
			return `items before an upper bound of key "c" only: {sortedKeys(items)}, full order is b, a, c`
		end)
	end

	if wants("contracts") then
		--// adapter contracts against live services

		-- live services with every name moved under this run, so contracts can't touch game data.
		-- Each contract test also gets its own names, like the fresh universe it gets in Lune
		local fixtures = 0
		local function isolatedServices(): any
			fixtures += 1
			local live = Geode.Raw.services()
			local prefix = `{STORE}-{RUN}-{fixtures}-`
			local services = table.clone(live :: any)
			services.dataStore = function(name: string, scope: string?)
				return live.dataStore(
					`{STORE}_{name}`,
					`{SCOPE}-{RUN}-{fixtures}-{scope or "global"}`
				)
			end
			services.orderedDataStore = function(name: string, scope: string?)
				return live.orderedDataStore(
					`{STORE}_{name}`,
					`{SCOPE}-{RUN}-{fixtures}-{scope or "global"}`
				)
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
				if string.find(result.name, "Teleport contract", 1, true) and not result.ok then
					-- ReserveServer is refused in Studio, only a live game server
					-- can do it (found in testing)
					report(
						"observed",
						`contract {result.name}`,
						`not runnable here: {result.message}`
					)
				elseif result.ok then
					report("pass", `contract {result.name}`)
				else
					report("fail", `contract {result.name}`, result.message)
				end
			end
		end
	end

	if wants("profile") then
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
	end

	print(
		`Geode Studio checks done: {outcome.pass} passed, {outcome.fail} failed, {outcome.observed} observed`
	)
	return outcome
end

return Checks
