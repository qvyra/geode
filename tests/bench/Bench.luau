--!strict

-- Benchmarks Geode next to other DataStore libraries under the same conditions, inside a Luau
-- Execution task on the test place. scripts/bench.luau starts one task per mode and library and
-- collects what `run` returns. Each library only ever gets the DataStore
-- GeodeStudioCheck_Bench_<Library>, enforced by the proxy, with fresh keys every run.
--
-- Modes:
--   perf      load, save and release a few fresh profiles, then load them again
--   throttle  exhaust the request budget with a burst, then load, save and release once
--   hold      the old server of a server hop: load, change, then release when asked or keep it
--   join      the new server of a server hop, run in a second task at the same time as hold
--   memory    the Lua heap before and after loading twenty profiles, per profile

local DataStoreService = game:GetService("DataStoreService")
local LogService = game:GetService("LogService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")
local RunService = game:GetService("RunService")

local Libraries = require("./Libraries")
local Proxy = require("./Proxy")

export type Mode = "env" | "perf" | "throttle" | "hold" | "join" | "memory"

export type Options = {
	mode: Mode,
	run: string,
	library: string?,
	iterations: number?,
}

export type Step = {
	op: string,
	key: string,
	seconds: number,
	ok: boolean,
	err: string?,
	-- DataStore requests the library made for this key during the step, counted by the proxy
	requests: number,
	byMethod: { [string]: number },
	failedRequests: number,
	-- budget before minus budget after, per request type. Refills during the step add noise
	budgetUsed: { [string]: number },
	check: string?,
	-- each request in order: method, seconds from the step's start to the request's start and
	-- end (-1 while out), and whether it succeeded. Capped at TIMELINE_LIMIT
	timeline: { { any } },
}

-- Seconds of the five minute task limit the bench plans to use
local TASK_BUDGET = 270
-- Seconds between two operations on the same key. Longer than ProfileService's 7 second per key
-- write cooldown and the old 6 second per key write limit, so neither adds to a timing
local GAP = 8
local DEFAULT_ITERATIONS = 5
local TIMELINE_LIMIT = 12
local HOP_ATTEMPTS = 3
local WRITE_METHODS =
	{ UpdateAsync = true, SetAsync = true, RemoveAsync = true, IncrementAsync = true }

-- The same payload for every library: a 50 item inventory on top of the template
local INVENTORY = table.create(50, "")
for index = 1, 50 do
	INVENTORY[index] = string.format("item-%03d", index)
end

local Bench = {}

--// helpers

local function now(): number
	return DateTime.now().UnixTimestampMillis
end

local function budgets(): { [string]: number }
	local found = {}
	for _, item in Enum.DataStoreRequestType:GetEnumItems() do
		local ok, value = pcall(function()
			return DataStoreService:GetRequestBudgetForRequestType(item)
		end)
		if ok then
			found[item.Name] = value
		end
	end
	return found
end

-- Counts how often each RunService event fires in one second. Some libraries run their request
-- queues or autosaves on these, so a task where one never fires can't run them as a server would
local function frameEvents(): { [string]: number }
	local counts: { [string]: number } = {}
	local connections = {}
	for _, name in { "Heartbeat", "Stepped", "PreSimulation", "PostSimulation" } do
		counts[name] = 0
		local ok, connection = pcall(function()
			return ((RunService :: any)[name] :: RBXScriptSignal):Connect(function()
				counts[name] += 1
			end)
		end)
		if ok then
			table.insert(connections, connection)
		else
			counts[name] = -1
		end
	end
	task.wait(1)
	for _, connection in connections do
		connection:Disconnect()
	end
	return counts
end

local function environment(label: string): { [string]: any }
	-- tells whether tasks share one DataModel: a later task would see an earlier one's marker
	local marker = workspace:GetAttribute("GeodeBench")
	workspace:SetAttribute("GeodeBench", label)
	local studio = ((script.Parent :: Instance).Parent :: Instance):FindFirstChild("studio")
	local run = studio and studio:FindFirstChild("Run")
	return {
		isStudio = RunService:IsStudio(),
		isServer = RunService:IsServer(),
		jobId = game.JobId,
		placeId = game.PlaceId,
		placeVersion = game.PlaceVersion,
		startedAt = now(),
		budgets = budgets(),
		earlierMarker = marker,
		checksScriptRan = run ~= nil and run:GetAttribute("Results") ~= nil,
		frameEvents = frameEvents(),
	}
end

local function newProxy(library: string): Proxy.Proxy
	return Proxy.new({
		real = DataStoreService,
		allowed = Libraries.storeName(library),
		clock = os.clock,
		-- Geode keeps mail in a second DataStore, moved under a scope of the allowed one
		aliases = if library == "Geode" or library == "GeodeMail"
			then { [`{Libraries.storeName(library)}_mailbox`] = { scope = "mailbox" } }
			else nil,
	})
end

local function waitWriteFor(proxy: Proxy.Proxy): (string, number, number) -> boolean
	return function(key: string, since: number, timeout: number): boolean
		local deadline = os.clock() + timeout
		while os.clock() < deadline do
			for _, call in Proxy.since(proxy, since, key) do
				if WRITE_METHODS[call.method] and call.finished ~= nil and call.ok then
					return true
				end
			end
			task.wait()
		end
		return false
	end
end

-- Runs `body` and records how long it took and what it cost. A body still running after
-- `limit` seconds is left behind and reported as not finished
local function measure(
	proxy: Proxy.Proxy,
	op: string,
	key: string,
	limit: number,
	body: () -> ()
): Step
	local before = budgets()
	local since = os.clock()
	local done = false
	local ok = false
	local err: string? = nil
	task.spawn(function()
		local success, message = pcall(body :: () -> any)
		ok = success
		err = if success then nil else tostring(message)
		done = true
	end)
	while not done and os.clock() - since < limit do
		task.wait()
	end
	local seconds = os.clock() - since
	if not done then
		ok = false
		err = `still waiting after {limit} seconds`
	end
	local after = budgets()
	local byMethod: { [string]: number } = {}
	local timeline: { { any } } = {}
	local requests, failed = 0, 0
	for _, call in Proxy.since(proxy, since, key) do
		if call.started <= since + seconds then
			local method = if call.noCache then "GetAsync (no cache)" else call.method
			requests += 1
			if #timeline < TIMELINE_LIMIT then
				-- -1 for a request still out, so the entry stays a plain JSON array
				local ended = if call.finished then call.finished - since else -1
				table.insert(
					timeline,
					{ method :: any, call.started - since, ended, call.ok == true }
				)
			end
			byMethod[method] = (byMethod[method] or 0) + 1
			if call.ok == false then
				failed += 1
			end
		end
	end
	local used: { [string]: number } = {}
	for name, value in before do
		if after[name] ~= nil and after[name] ~= value then
			used[name] = value - after[name]
		end
	end
	return {
		op = op,
		key = key,
		seconds = seconds,
		ok = ok,
		err = err,
		requests = requests,
		byMethod = byMethod,
		failedRequests = failed,
		budgetUsed = used,
		timeline = timeline,
	}
end

-- measure for steps the rest depends on: errors when the step failed or ran out of time
local function must(proxy: Proxy.Proxy, op: string, key: string, limit: number, body: () -> ())
	local step = measure(proxy, op, key, limit, body)
	if not step.ok then
		error(`{op}: {step.err}`, 0)
	end
end

--// perf

local function perf(
	adapter: Libraries.Adapter,
	proxy: Proxy.Proxy,
	options: Options,
	deadline: number
): { [string]: any }
	local library = adapter.name
	local count = options.iterations or DEFAULT_ITERATIONS
	local steps: { Step } = {}
	local handles: { [number]: Libraries.Handle? } = {}
	local lastDone: { [number]: number } = {}
	local keys = {}
	for index = 1, count do
		keys[index] = Libraries.key(library, options.run, "perf", index)
	end
	local truncated = false

	local function paced(index: number, op: string, body: () -> ()): Step?
		local wait = (lastDone[index] or 0) + GAP - os.clock()
		if wait > 0 then
			task.wait(wait)
		end
		if os.clock() > deadline then
			truncated = true
			return nil
		end
		local step = measure(proxy, op, keys[index], math.min(60, deadline - os.clock()), body)
		lastDone[index] = os.clock()
		table.insert(steps, step)
		return step
	end

	-- fresh profiles
	for index = 1, count do
		paced(index, "loadNew", function()
			handles[index] = adapter.load(keys[index])
		end)
		local handle = handles[index]
		if handle then
			adapter.set(handle, "inventory", INVENTORY)
			adapter.set(handle, "coins", index * 10)
		end
	end
	for index = 1, count do
		local handle = handles[index]
		if handle then
			paced(index, "save", function()
				adapter.save(handle)
			end)
		end
	end
	-- release always follows a change, so every library has something to write
	for index = 1, count do
		local handle = handles[index]
		if handle then
			adapter.set(handle, "coins", index * 10 + 1)
			paced(index, "release", function()
				adapter.release(handle)
			end)
			handles[index] = nil
		end
	end
	-- the same profiles again, now stored
	for index = 1, count do
		local step = paced(index, "load", function()
			handles[index] = adapter.load(keys[index])
		end)
		local handle = handles[index]
		if step and handle then
			local coins = adapter.coins(handle)
			step.check = if coins == index * 10 + 1
				then "read back the released value"
				else `read back coins {tostring(coins)}, expected {index * 10 + 1}`
		end
	end
	for index = 1, count do
		local handle = handles[index]
		if handle then
			adapter.set(handle, "coins", index * 10 + 2)
			paced(index, "releaseAgain", function()
				adapter.release(handle)
			end)
		end
	end
	return { steps = steps, iterations = count, gap = GAP, truncated = truncated }
end

--// throttle

local function burstSize(before: { [string]: number }): number
	local biggest = 0
	for _, name in { "UpdateAsync", "StandardWrite", "SetIncrementAsync", "StandardRead" } do
		biggest = math.max(biggest, before[name] or 0)
	end
	-- enough to use up the budget and fill the queue behind it
	return math.clamp(biggest + 40, 60, 400)
end

local function throttle(
	adapter: Libraries.Adapter,
	proxy: Proxy.Proxy,
	context: Libraries.Context,
	options: Options,
	deadline: number
): { [string]: any }
	local library = adapter.name
	local burstProxy = newProxy(library)
	local burstStore = burstProxy.service:GetDataStore(Libraries.storeName(library))
	local before = budgets()
	local size = burstSize(before)

	local warnings: { string } = {}
	local connection = LogService.MessageOut:Connect(
		function(message: string, kind: Enum.MessageType)
			if
				(kind == Enum.MessageType.MessageWarning or kind == Enum.MessageType.MessageError)
				and #warnings < 25
			then
				table.insert(warnings, string.sub(message, 1, 240))
			end
		end
	)

	-- UpdateAsync with a transform that returns nil writes nothing, so the burst leaves no keys
	-- behind but still spends budget. Each call is sent before the next thread starts
	for index = 1, size do
		task.spawn(function()
			pcall(function()
				burstStore:UpdateAsync(`{options.run}-burst-{index}`, function()
					return nil
				end)
			end)
		end)
	end
	local afterBurst = budgets()

	local key = Libraries.key(library, options.run, "throttle", 1)
	local steps: { Step } = {}
	local handle: Libraries.Handle? = nil
	local started = os.clock()
	local function remaining(cap: number): number
		return math.max(1, math.min(cap, deadline - os.clock()))
	end
	context.loadLimit = remaining(90)
	table.insert(
		steps,
		measure(proxy, "load", key, remaining(90), function()
			handle = adapter.load(key)
		end)
	)
	local loaded = handle
	if loaded then
		adapter.set(loaded, "coins", 5)
		context.writeLimit = remaining(60)
		table.insert(
			steps,
			measure(proxy, "save", key, remaining(60), function()
				adapter.save(loaded)
			end)
		)
		adapter.set(loaded, "coins", 6)
		context.writeLimit = remaining(60)
		table.insert(
			steps,
			measure(proxy, "release", key, remaining(60), function()
				adapter.release(loaded)
			end)
		)
	end
	connection:Disconnect()

	local burst = { sent = size, ok = 0, failed = 0, pending = 0, errors = {} :: { string } }
	for _, call in burstProxy.calls do
		if call.finished == nil then
			burst.pending += 1
		elseif call.ok then
			burst.ok += 1
		else
			burst.failed += 1
			local message = string.sub(call.err or "?", 1, 200)
			if #burst.errors < 5 and not table.find(burst.errors, message) then
				table.insert(burst.errors, message)
			end
		end
	end

	return {
		budgetsBefore = before,
		budgetsAfterBurst = afterBurst,
		burst = burst,
		steps = steps,
		seconds = os.clock() - started,
		warnings = warnings,
	}
end

--// server hop

local function hopMap(run: string): MemoryStoreHashMap
	return MemoryStoreService:GetHashMap(`GeodeStudioCheck-Bench-{run}`)
end

local function put(map: MemoryStoreHashMap, key: string, value: { [string]: any })
	pcall(function()
		map:SetAsync(key, value, 900)
	end)
end

local function waitFor(map: MemoryStoreHashMap, key: string, timeout: number): any
	local deadline = os.clock() + timeout
	while os.clock() < deadline do
		local ok, value = pcall(function()
			return map:GetAsync(key)
		end)
		if ok and value ~= nil then
			return value
		end
		task.wait(0.25)
	end
	return nil
end

-- Both tasks of a hop listen and talk on one topic, which shows whether MessagingService
-- reaches from one task to the other at all
local function messagingProbe(run: string, library: string, role: string): { [string]: any }
	local topic = `GeodeStudioCheck-Bench-{run}-{library}`
	local probe: { [string]: any } =
		{ topic = topic, heard = {} :: { [string]: number }, sent = 0, subscribed = false }
	local ok, err = pcall(function()
		MessagingService:SubscribeAsync(topic, function(message: any)
			local from = type(message.Data) == "table" and message.Data.from or "?"
			probe.heard[from] = (probe.heard[from] or 0) + 1
		end)
	end)
	probe.subscribed = ok
	if not ok then
		probe.heard.subscribeError = 0
		probe.error = tostring(err)
	end
	task.spawn(function()
		for _ = 1, 10 do
			if pcall(MessagingService.PublishAsync, MessagingService, topic, { from = role }) then
				probe.sent += 1
			end
			task.wait(3)
		end
	end)
	return probe
end

local function hold(
	adapter: Libraries.Adapter,
	proxy: Proxy.Proxy,
	options: Options,
	deadline: number
): { [string]: any }
	local library = adapter.name
	local map = hopMap(options.run)
	local probe = messagingProbe(options.run, library, "hold")
	local attempts: { { [string]: any } } = {}
	local joinerMissing = false

	for attempt = 1, HOP_ATTEMPTS do
		if deadline - os.clock() < 170 then
			break
		end
		local key = Libraries.key(library, options.run, "hop", attempt)
		local slot = `{library}-hop-{attempt}`
		local entry: { [string]: any } = { attempt = attempt }
		local ok, err = pcall(function()
			local handle: Libraries.Handle = nil :: any
			must(proxy, "load", key, 40, function()
				handle = adapter.load(key)
			end)
			adapter.set(handle, "coins", 777)
			must(proxy, "save", key, 30, function()
				adapter.save(handle)
			end)
			task.wait(GAP)
			-- only the release's final save carries this one
			adapter.set(handle, "coins", 888)
			put(map, slot, { state = "held", jobId = game.JobId, at = now() })
			local go = waitFor(map, `{slot}-go`, 90)
			if go == nil then
				joinerMissing = true
				put(map, slot, { state = "gone", at = now() })
			else
				entry.goSeenAfterMs = now() - go.at
			end
			local started = os.clock()
			must(proxy, "release", key, 40, function()
				adapter.release(handle)
			end)
			entry.releaseSeconds = os.clock() - started
		end)
		entry.ok = ok
		entry.err = if ok then nil else tostring(err)
		table.insert(attempts, entry)
		if joinerMissing then
			break
		end
	end

	local keep: { [string]: any }? = nil
	if not joinerMissing and deadline - os.clock() > 60 then
		local key = Libraries.key(library, options.run, "keep", 1)
		local slot = `{library}-keep`
		keep = {}
		local entry = keep :: { [string]: any }
		local ok, err = pcall(function()
			local handle: Libraries.Handle = nil :: any
			must(proxy, "load", key, 40, function()
				handle = adapter.load(key)
			end)
			adapter.set(handle, "coins", 777)
			must(proxy, "save", key, 30, function()
				adapter.save(handle)
			end)
			task.wait(GAP)
			-- never saved by this server unless the library hands the profile over
			adapter.set(handle, "coins", 999)
			adapter.watch(handle, function(reason: string)
				if entry.lost == nil then
					entry.lost = reason
					entry.lostAt = now()
				end
			end)
			put(map, slot, { state = "held", jobId = game.JobId, at = now() })
			local done = waitFor(map, `{slot}-done`, math.max(1, deadline - os.clock() - 15))
			entry.joinerDone = done ~= nil
			measure(proxy, "cleanup", key, 10, function()
				adapter.release(handle)
			end)
		end)
		entry.ok = ok
		entry.err = if ok then nil else tostring(err)
	end

	return { attempts = attempts, keep = keep, joinerMissing = joinerMissing, messaging = probe }
end

local function join(
	adapter: Libraries.Adapter,
	proxy: Proxy.Proxy,
	options: Options,
	deadline: number
): { [string]: any }
	local library = adapter.name
	local map = hopMap(options.run)
	local probe = messagingProbe(options.run, library, "join")
	local attempts: { { [string]: any } } = {}
	local holderMissing = false

	for attempt = 1, HOP_ATTEMPTS do
		local key = Libraries.key(library, options.run, "hop", attempt)
		local slot = `{library}-hop-{attempt}`
		local held = waitFor(map, slot, math.max(1, math.min(120, deadline - os.clock() - 60)))
		if held == nil or held.state ~= "held" then
			holderMissing = true
			table.insert(attempts, { attempt = attempt, holderMissing = true })
			break
		end
		local handle: Libraries.Handle? = nil
		put(map, `{slot}-go`, { at = now() })
		local step = measure(proxy, "hopLoad", key, 100, function()
			handle = adapter.load(key)
		end)
		local entry: { [string]: any } = {
			attempt = attempt,
			sameJobId = held.jobId == game.JobId,
			step = step,
		}
		local loaded = handle
		if loaded then
			entry.coins = adapter.coins(loaded)
			adapter.set(loaded, "coins", 1)
			measure(proxy, "cleanup", key, 15, function()
				adapter.release(loaded)
			end)
		end
		table.insert(attempts, entry)
	end

	local keep: { [string]: any }? = nil
	if not holderMissing then
		local key = Libraries.key(library, options.run, "keep", 1)
		local slot = `{library}-keep`
		local held = waitFor(map, slot, math.max(1, math.min(150, deadline - os.clock() - 30)))
		if held ~= nil and held.state == "held" then
			local handle: Libraries.Handle? = nil
			local limit = math.max(1, math.min(130, deadline - os.clock() - 10))
			local step = measure(proxy, "keepLoad", key, limit, function()
				handle = adapter.load(key)
			end)
			keep = { sameJobId = held.jobId == game.JobId, step = step }
			local loaded = handle
			if loaded then
				(keep :: any).coins = adapter.coins(loaded)
			end
			put(map, `{slot}-done`, { at = now() })
			if loaded then
				adapter.set(loaded, "coins", 1)
				measure(proxy, "cleanup", key, 10, function()
					adapter.release(loaded)
				end)
			end
		else
			keep = { holderMissing = true }
		end
	end

	return { attempts = attempts, keep = keep, holderMissing = holderMissing, messaging = probe }
end

--// memory

-- Profiles the memory mode holds at once, and how long it watches the heap before and after
local MEMORY_PROFILES = 20
local HEAP_WINDOW = 5
local HEAP_INTERVAL = 0.1

-- The Lua heap in KB, sampled over a few seconds. Luau collects garbage in steps and a script
-- can't make it finish a cycle, so the lowest sample is the closest to what's still in use and
-- still an upper bound
local function heap(): { [string]: any }
	local samples: { number } = {}
	local stop = os.clock() + HEAP_WINDOW
	while os.clock() < stop do
		table.insert(samples, collectgarbage("count"))
		task.wait(HEAP_INTERVAL)
	end
	local low, high = math.huge, -math.huge
	for _, sample in samples do
		low = math.min(low, sample)
		high = math.max(high, sample)
	end
	return { min = low, max = high, samples = samples }
end

local function memory(
	adapter: Libraries.Adapter,
	proxy: Proxy.Proxy,
	options: Options,
	deadline: number
): { [string]: any }
	local library = adapter.name
	-- TODO(verify): Roblox documents collectgarbage("count") for scripts, this finds out whether
	-- a Luau Execution task allows it
	local readable, reason = pcall(function()
		return collectgarbage("count")
	end)
	if not readable then
		return { notReadable = tostring(reason) }
	end

	-- one profile first, so the library's own setup isn't counted as the profiles'
	local warmKey = Libraries.key(library, options.run, "memory", 1)
	local warm = adapter.load(warmKey)
	adapter.set(warm, "inventory", INVENTORY)
	adapter.set(warm, "coins", 1)
	adapter.release(warm)

	-- the log grows with every request, which isn't the library's memory
	proxy.recording = false
	table.clear(proxy.calls)
	local before = heap()
	local handles: { Libraries.Handle } = {}
	local failed: { string } = {}
	for index = 1, MEMORY_PROFILES do
		if os.clock() > deadline - 60 then
			table.insert(failed, `stopped before profile {index}, out of time`)
			break
		end
		local key = Libraries.key(library, options.run, "memory", index + 1)
		local ok, result = pcall(adapter.load, key)
		if ok then
			local handle = result :: Libraries.Handle
			adapter.set(handle, "inventory", INVENTORY)
			adapter.set(handle, "coins", index)
			table.insert(handles, handle)
		else
			table.insert(failed, tostring(result))
		end
	end
	local after = heap()
	proxy.recording = true

	-- nothing stays locked behind the task
	local released = 0
	for _, handle in handles do
		if pcall(adapter.release, handle) then
			released += 1
		end
	end
	return {
		profiles = #handles,
		failed = failed,
		released = released,
		window = HEAP_WINDOW,
		before = before,
		after = after,
		perProfileKb = if #handles > 0 then (after.min - before.min) / #handles else nil,
	}
end

--// entry

--[=[
	Runs one bench mode for one library and returns everything it saw, ready for JSONEncode
]=]
function Bench.run(options: Options): { [string]: any }
	local started = os.clock()
	local deadline = started + TASK_BUDGET
	local label = `{options.mode}:{options.library or "-"}:{options.run}`
	local report: { [string]: any } = {
		mode = options.mode,
		library = options.library,
		run = options.run,
		environment = environment(label),
	}
	if options.mode == "env" then
		report.endedAt = now()
		return report
	end

	local library = options.library :: string
	-- Lapis sends every request from a RunService.PostSimulation handler. Without that event its
	-- loads wait forever and make no request, so it's reported instead of timed
	if library == "Lapis" and report.environment.frameEvents.PostSimulation == 0 then
		report.notRunnable =
			"RunService.PostSimulation didn't fire in this task, and Lapis sends its DataStore requests from that event"
		report.endedAt = now()
		return report
	end
	local proxy = newProxy(library)
	Proxy.setActive(proxy)
	local context: Libraries.Context = {
		proxy = proxy,
		waitWrite = waitWriteFor(proxy),
		loadLimit = 120,
		writeLimit = 120,
	}
	local made, adapter = pcall(Libraries.make, library, context)
	if not made then
		report.error = `couldn't set up {library}: {adapter}`
		report.endedAt = now()
		return report
	end

	local ok, result = pcall(function(): { [string]: any }
		if options.mode == "perf" then
			return perf(adapter, proxy, options, deadline)
		elseif options.mode == "throttle" then
			return throttle(adapter, proxy, context, options, deadline)
		elseif options.mode == "hold" then
			return hold(adapter, proxy, options, deadline)
		elseif options.mode == "join" then
			return join(adapter, proxy, options, deadline)
		elseif options.mode == "memory" then
			return memory(adapter, proxy, options, deadline)
		end
		error(`unknown mode {options.mode}`)
	end)
	if ok then
		report.result = result
	else
		report.error = tostring(result)
	end
	report.requestsTotal = #proxy.calls
	report.seconds = os.clock() - started
	report.endedAt = now()
	return report
end

return Bench
