--!strict

-- Builds the bench data the docs site publishes from the runs in benchmarks/runs and the
-- definitions in benchmarks/catalog.json: one file per run with its results, latest.json with
-- the current results and index.json listing every run. Plain Luau like BenchResults, the
-- caller reads and writes the files

local BenchResults = require("./BenchResults")

local array = BenchResults.array

local BenchPublish = {}

BenchPublish.SCHEMA_URL = "https://qvyra.github.io/geode/data/benchmarks/schema/v1.json"
BenchPublish.SCHEMA_VERSION = 1

export type Value = { [string]: any }

export type Result = {
	suite: string,
	scenario: string,
	metric: string,
	subject: string,
	runs: { string },
	value: Value,
}

-- One thing measured once: a time, a request count, a yes or no, or a value seen
type Sample = {
	suite: string,
	scenario: string,
	metric: string,
	subject: string,
	run: string,
	-- nil for a step that failed, which is counted but has no time
	value: any,
}

local PERF_SCENARIOS = table.freeze({
	loadNew = "load-new",
	load = "load-stored",
	save = "save",
	release = "release",
})

local SUITE_OF_MODE = table.freeze({
	perf = "load-save-release",
	hold = "server-hop",
	join = "server-hop",
	throttle = "throttling",
	memory = "memory",
})

--// lookups

local function find(list: { any }, id: string): any
	for _, entry in list do
		if entry.id == id then
			return entry
		end
	end
	return nil
end

--[=[
	The subject a bench library's task belongs to, given the Geode build the run measured
]=]
function BenchPublish.subjectOf(catalog: any, benchLibrary: string, buildId: string): string
	local build = find(catalog.builds, buildId)
	if build == nil then
		error(`build {buildId} isn't in benchmarks/catalog.json`)
	end
	for _, subject in catalog.subjects do
		if
			subject.bench == benchLibrary
			and (subject.lines == nil or table.find(subject.lines, build.line))
		then
			return subject.id
		end
	end
	error(`no subject in benchmarks/catalog.json for {benchLibrary} on the {build.line} line`)
end

--[=[
	The build whose source tree matches, if the catalog has one
]=]
function BenchPublish.buildOf(catalog: any, sourceTree: string): string?
	for _, build in catalog.builds do
		if table.find(build.sourceTrees, sourceTree) then
			return build.id
		end
	end
	return nil
end

--[=[
	Adds a build to the catalog's text, at the end of its builds list, and leaves the rest of the
	file as it was. Prettier tidies the new entry
]=]
function BenchPublish.addBuild(catalogText: string, build: { [string]: any }): string
	local start = string.find(catalogText, '"builds"%s*:%s*%[')
	if start == nil then
		error("benchmarks/catalog.json has no builds list")
	end
	local at = (string.find(catalogText, "[", start, true) :: number) + 1
	local depth, inString = 1, false
	while depth > 0 do
		local char = string.sub(catalogText, at, at)
		if char == "" then
			error("benchmarks/catalog.json ends inside its builds list")
		elseif inString then
			if char == "\\" then
				at += 1
			elseif char == '"' then
				inString = false
			end
		elseif char == '"' then
			inString = true
		elseif char == "[" or char == "{" then
			depth += 1
		elseif char == "]" or char == "}" then
			depth -= 1
		end
		at += 1
	end
	-- `at` is just past the list's closing bracket. The entry goes after its last item
	local close = at - 1
	local body = string.sub(catalogText, 1, close - 1)
	local last = string.find(body, "%S%s*$") :: number
	local entry = string.gsub(BenchResults.encode(build), "\n$", "")
	local comma = if string.sub(body, last, last) == "[" then "\n" else ",\n"
	return string.sub(body, 1, last)
		.. comma
		.. entry
		.. string.sub(body, last + 1)
		.. string.sub(catalogText, close)
end

local function methodIds(catalog: any): { [string]: string }
	local ids = {}
	for _, method in catalog.requestMethods do
		ids[method.bench] = method.id
	end
	return ids
end

--// samples

local function requestsOf(step: any, ids: { [string]: string }): { [string]: number }
	local counts = {}
	for label, count in step.byMethod or {} do
		local id = ids[label]
		if id == nil then
			error(`request method {label} isn't in benchmarks/catalog.json`)
		end
		counts[id] = count
	end
	return counts
end

local function samplesOf(catalog: any, run: any): ({ Sample }, { any }, { any })
	local ids = methodIds(catalog)
	local samples: { Sample } = {}
	local notRunnable = array({})
	local problems = array({})

	for _, entry in run.tasks do
		local subject = BenchPublish.subjectOf(catalog, entry.library, run.build)
		local suite = SUITE_OF_MODE[entry.mode]
		local function add(scenario: string, metric: string, value: any)
			table.insert(samples, {
				suite = suite,
				scenario = scenario,
				metric = metric,
				subject = subject,
				run = run.run,
				value = value,
			})
		end
		local function step(scenario: string, data: any)
			if data.ok then
				add(scenario, "time", data.seconds)
				add(scenario, "requests", requestsOf(data, ids))
			else
				add(scenario, "time", nil)
			end
		end

		if entry.problem then
			table.insert(
				problems,
				{ subject = subject, mode = entry.mode, problem = entry.problem }
			)
		end
		local report = entry.report
		if report and report.notRunnable then
			table.insert(
				notRunnable,
				{ subject = subject, suite = suite, reason = report.notRunnable }
			)
		end
		local result = report and report.result
		if result == nil then
			continue
		end

		if entry.mode == "perf" then
			for _, data in result.steps do
				local scenario = PERF_SCENARIOS[data.op]
				if scenario then
					step(scenario, data)
				end
			end
		elseif entry.mode == "throttle" then
			for _, data in result.steps do
				step(data.op, data)
			end
		elseif entry.mode == "memory" then
			if result.notReadable then
				table.insert(notRunnable, {
					subject = subject,
					suite = suite,
					reason = `collectgarbage("count") failed: {result.notReadable}`,
				})
			elseif result.perProfileKb then
				add("loaded-profiles", "heap-per-profile", result.perProfileKb)
			end
		elseif entry.mode == "join" then
			for _, attempt in result.attempts do
				if attempt.step then
					step("old-releases", attempt.step)
					add("old-releases", "final-save-seen", attempt.coins == 888)
				end
			end
			local keep = result.keep
			if keep and keep.step then
				step("old-keeps", keep.step)
				add(
					"old-keeps",
					"value-seen",
					if keep.coins == nil then "none" else tostring(keep.coins)
				)
			end
		end
	end

	-- Geode's edits in Lune, timed by the runner rather than a task
	local cpu = run.lune and run.lune.cpu
	if cpu then
		local subject = BenchPublish.subjectOf(catalog, "Geode", run.build)
		if cpu.problem then
			table.insert(problems, { subject = subject, mode = "cpu", problem = cpu.problem })
		end
		for _, seconds in cpu.batches or {} do
			table.insert(samples, {
				suite = "geode-edits",
				scenario = "increment",
				metric = "time-per-edit",
				subject = subject,
				run = run.run,
				-- microseconds
				value = seconds / cpu.editsPerBatch * 1e6,
			})
		end
	end
	return samples, notRunnable, problems
end

--// values

local function round(value: number): number
	return math.round(value * 1000) / 1000
end

local function median(sorted: { number }): number
	local middle = (#sorted + 1) / 2
	if middle % 1 == 0 then
		return sorted[middle]
	end
	return (sorted[math.floor(middle)] + sorted[math.ceil(middle)]) / 2
end

local function timeValue(kind: string, values: { any }): Value
	local times = array({})
	local failed = 0
	for _, value in values do
		if value == nil or value == false then
			failed += 1
		else
			table.insert(times, value)
		end
	end
	local rounded = array({})
	for index, time in times do
		rounded[index] = round(time)
	end
	local value: Value = { kind = kind, unit = "s", n = #times, failed = failed, samples = rounded }
	if #times > 0 then
		local sorted = table.clone(times)
		table.sort(sorted)
		value.min = round(sorted[1])
		value.max = round(sorted[#sorted])
		if kind == "timing" then
			value.median = round(median(sorted))
		end
	end
	return value
end

local function requestsValue(values: { any }): Value
	local methods: { [string]: boolean } = {}
	for _, counts in values do
		for id in counts do
			methods[id] = true
		end
	end
	local byMethod = {}
	local exact = true
	for id in methods do
		local low, high = math.huge, -math.huge
		for _, counts in values do
			local count = counts[id] or 0
			low = math.min(low, count)
			high = math.max(high, count)
		end
		byMethod[id] = { min = low, max = high }
		if low ~= high then
			exact = false
		end
	end
	return { kind = "requests", exact = exact, n = #values, byMethod = byMethod }
end

local function countValue(values: { any }): Value
	local passed = 0
	for _, value in values do
		if value then
			passed += 1
		end
	end
	return { kind = "count", passed = passed, total = #values }
end

local function valuesValue(values: { any }): Value
	local counts = {}
	for _, value in values do
		counts[value] = (counts[value] or 0) + 1
	end
	return { kind = "values", counts = counts, total = #values }
end

-- A measured quantity that isn't a time in seconds, like KB or microseconds
local function amountValue(unit: string, values: { any }): Value
	local rounded = array({})
	for index, value in values do
		rounded[index] = round(value)
	end
	local sorted = table.clone(values)
	table.sort(sorted)
	return {
		kind = "amount",
		unit = unit,
		n = #values,
		median = round(median(sorted)),
		min = round(sorted[1]),
		max = round(sorted[#sorted]),
		samples = rounded,
	}
end

local function valueOf(catalog: any, suiteId: string, metricId: string, values: { any }): Value
	local metric = find(catalog.metrics, metricId)
	if metric.kind == "amount" then
		return amountValue(metric.unit, values)
	elseif metric.kind == "timing" then
		local suite = find(catalog.suites, suiteId)
		return timeValue(suite.timeKind or "timing", values)
	elseif metric.kind == "requests" then
		return requestsValue(values)
	elseif metric.kind == "count" then
		return countValue(values)
	end
	return valuesValue(values)
end

-- Results in catalog order: suite, scenario, metric, then subject. `runsOf` says which runs each
-- subject takes, nil to leave a subject out
local function resultsOf(
	catalog: any,
	samples: { Sample },
	runsOf: (subject: string) -> { string }?
): { Result }
	local grouped: { [string]: { any } } = {}
	-- the runs that gave each result samples, which can be fewer than the subject takes when an
	-- older run didn't measure something yet
	local contributed: { [string]: { [string]: boolean } } = {}
	for _, sample in samples do
		local runs = runsOf(sample.subject)
		if runs == nil or not table.find(runs, sample.run) then
			continue
		end
		local key = `{sample.suite}|{sample.scenario}|{sample.metric}|{sample.subject}`
		local list = grouped[key]
		if list == nil then
			list = {}
			grouped[key] = list
		end
		-- a failed step's time is nil, which a list can't hold
		table.insert(list, if sample.value == nil then false else sample.value)
		contributed[key] = contributed[key] or {}
		contributed[key][sample.run] = true
	end

	local results = array({})
	for _, suite in catalog.suites do
		for _, scenario in suite.scenarios do
			for _, metric in scenario.metrics do
				for _, subject in catalog.subjects do
					local key = `{suite.id}|{scenario.id}|{metric}|{subject.id}`
					local from = contributed[key]
					if from == nil then
						continue
					end
					local runs = array({})
					for _, id in runsOf(subject.id) :: { string } do
						if from[id] then
							table.insert(runs, id)
						end
					end
					table.insert(results, {
						suite = suite.id,
						scenario = scenario.id,
						metric = metric,
						subject = subject.id,
						runs = runs,
						value = valueOf(catalog, suite.id, metric, grouped[key]),
					})
				end
			end
		end
	end
	return results
end

--// files

local function sortedRuns(runs: { any }): { any }
	local sorted = table.clone(runs)
	table.sort(sorted, function(a, b)
		return a.date < b.date
	end)
	return sorted
end

local function runRef(run: any): { [string]: any }
	return { id = run.run, date = run.date, build = run.build, data = `runs/{run.run}.json` }
end

local function without(entry: { [string]: any }, fields: { string }): { [string]: any }
	local copy = table.clone(entry)
	for _, field in fields do
		copy[field] = nil
	end
	return copy
end

--[=[
	One run's published file: its normalized results, in the same shape as latest.json's, and the
	cleaned raw tasks they came from
]=]
function BenchPublish.runFile(catalog: any, run: any): { [string]: any }
	local samples, notRunnable, problems = samplesOf(catalog, run)
	local only = array({ run.run })
	local tasks = array({})
	for _, entry in run.tasks do
		local copy = table.clone(entry)
		copy.subject = BenchPublish.subjectOf(catalog, entry.library, run.build)
		table.insert(tasks, copy)
	end
	return {
		["$schema"] = BenchPublish.SCHEMA_URL,
		schemaVersion = BenchPublish.SCHEMA_VERSION,
		kind = "run",
		id = run.run,
		date = run.date,
		build = run.build,
		geode = { sourceTree = run.geodeSourceTree },
		bench = { tree = run.benchTree, workflowRun = run.workflowRun },
		libraries = run.libraries,
		refused = run.refused,
		results = resultsOf(catalog, samples, function()
			return only
		end),
		notRunnable = notRunnable,
		problems = problems,
		tasks = tasks,
		lune = run.lune,
	}
end

-- The runs each subject takes for latest.json. Current subjects share the last runs of the
-- current subject's lines, a historical one keeps the last runs of its own
local function chosenRuns(catalog: any, runs: { any }): { [string]: { string } }
	local limit = catalog.currentRuns
	local lineOf: { [string]: string } = {}
	for _, build in catalog.builds do
		lineOf[build.id] = build.line
	end
	local function last(lines: { string }?): { string }
		local picked = {}
		for _, run in runs do
			if lines == nil or table.find(lines, lineOf[run.build]) then
				table.insert(picked, run.run)
			end
		end
		return table.move(picked, math.max(1, #picked - limit + 1), #picked, 1, {})
	end

	local current = find(catalog.subjects, catalog.current)
	local shared = last(current.lines)
	local chosen = {}
	for _, subject in catalog.subjects do
		chosen[subject.id] = if subject.historical then last(subject.lines) else shared
	end
	return chosen
end

--[=[
	latest.json: the catalog's definitions, the current results and the runs they came from
]=]
function BenchPublish.latest(catalog: any, runs: { any }): { [string]: any }
	local sorted = sortedRuns(runs)
	local chosen = chosenRuns(catalog, sorted)
	local samples = {}
	for _, run in sorted do
		local found = samplesOf(catalog, run)
		table.move(found, 1, #found, #samples + 1, samples)
	end
	local results = resultsOf(catalog, samples, function(subject: string)
		return chosen[subject]
	end)

	local used: { [string]: boolean } = {}
	for _, result in results do
		for _, id in result.runs do
			used[id] = true
		end
	end
	local refs = array({})
	for _, run in sorted do
		if used[run.run] then
			table.insert(refs, runRef(run))
		end
	end

	local suites = array({})
	for _, suite in catalog.suites do
		table.insert(suites, without(suite, { "timeKind" }))
	end
	local methods = array({})
	for _, method in catalog.requestMethods do
		table.insert(methods, without(method, { "bench" }))
	end
	local subjects = array({})
	for _, subject in catalog.subjects do
		table.insert(subjects, without(subject, { "bench", "docsLabel" }))
	end

	return {
		["$schema"] = BenchPublish.SCHEMA_URL,
		schemaVersion = BenchPublish.SCHEMA_VERSION,
		kind = "latest",
		updatedAt = if #sorted > 0 then sorted[#sorted].date else nil,
		aggregation = {
			currentRuns = catalog.currentRuns,
			rule = catalog.rule,
			caveat = catalog.caveat,
		},
		suites = suites,
		metrics = catalog.metrics,
		requestMethods = methods,
		lines = catalog.lines,
		builds = catalog.builds,
		subjects = subjects,
		runs = refs,
		results = results,
		notMeasured = catalog.notMeasured,
	}
end

--[=[
	index.json: every run, oldest first
]=]
function BenchPublish.index(runs: { any }): { [string]: any }
	local refs = array({})
	for _, run in sortedRuns(runs) do
		table.insert(refs, runRef(run))
	end
	return {
		["$schema"] = BenchPublish.SCHEMA_URL,
		schemaVersion = BenchPublish.SCHEMA_VERSION,
		kind = "index",
		updatedAt = if #refs > 0 then refs[#refs].date else nil,
		latest = "latest.json",
		runs = refs,
	}
end

--[=[
	Every published file by its path under data/benchmarks, encoded
]=]
function BenchPublish.files(catalog: any, runs: { any }, schema: string): { [string]: string }
	local files = {
		["latest.json"] = BenchResults.encode(BenchPublish.latest(catalog, runs)),
		["index.json"] = BenchResults.encode(BenchPublish.index(runs)),
		["schema/v1.json"] = schema,
	}
	for _, run in runs do
		files[`runs/{run.run}.json`] = BenchResults.encode(BenchPublish.runFile(catalog, run))
	end
	return files
end

return BenchPublish
