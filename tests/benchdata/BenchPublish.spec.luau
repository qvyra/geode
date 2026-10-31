--!strict

local fs = require("@lune/fs")

local BenchPublish = require("../../scripts/BenchPublish")
local BenchResults = require("../../scripts/BenchResults")
local Spec = require("../_lib/Spec")

local TREE_OLD = string.rep("1", 40)
local TREE_NEW = string.rep("2", 40)

local function catalog(): any
	local data: any = {
		currentRuns = 2,
		current = "geode",
		rule = "rule",
		caveat = "caveat",
		suites = {
			{
				id = "load-save-release",
				name = "Load, save and release",
				environment = "roblox-live",
				timingResolution = 1 / 60,
				description = "d",
				scenarios = {
					{ id = "load-new", name = "Load, new", metrics = { "time", "requests" } },
				},
			},
			{
				id = "server-hop",
				name = "Server hops",
				environment = "roblox-live",
				timingResolution = 1 / 60,
				description = "d",
				scenarios = {
					{
						id = "old-releases",
						name = "Releases",
						metrics = { "time", "final-save-seen" },
					},
					{ id = "old-keeps", name = "Keeps", metrics = { "value-seen" } },
				},
			},
			{
				id = "throttling",
				name = "Throttling",
				environment = "roblox-live",
				timingResolution = 1 / 60,
				timeKind = "range",
				description = "d",
				scenarios = { { id = "load", name = "Load", metrics = { "time" } } },
			},
			{
				id = "memory",
				name = "Memory",
				environment = "roblox-live",
				description = "d",
				scenarios = {
					{ id = "loaded-profiles", name = "Loaded", metrics = { "heap-per-profile" } },
				},
			} :: any,
			{
				id = "geode-edits",
				name = "Edits",
				environment = "lune",
				timingResolution = 0.000001,
				description = "d",
				scenarios = {
					{ id = "increment", name = "Increment", metrics = { "time-per-edit" } },
				},
			},
		},
		metrics = {
			{ id = "time", name = "Time", kind = "timing", description = "d" },
			{ id = "requests", name = "Requests", kind = "requests", description = "d" },
			{ id = "final-save-seen", name = "Final save", kind = "count", description = "d" },
			{ id = "value-seen", name = "Value", kind = "values", description = "d" },
			{
				id = "heap-per-profile",
				name = "Heap",
				kind = "amount",
				unit = "KB",
				description = "d",
			},
			{
				id = "time-per-edit",
				name = "Edit",
				kind = "amount",
				unit = "us",
				description = "d",
			},
		},
		requestMethods = {
			{ id = "UpdateAsync", label = "UpdateAsync", bench = "UpdateAsync" },
			{
				id = "GetAsync:noCache",
				label = "GetAsync past the cache",
				bench = "GetAsync (no cache)",
			},
		},
		lines = { { id = "old", description = "d" }, { id = "new", description = "d" } },
		builds = {
			{ id = "1.0.0", line = "old", sourceTrees = { TREE_OLD } },
			{ id = "2.0.0", line = "new", sourceTrees = { TREE_NEW } },
		},
		subjects = {
			{ id = "geode", library = "Geode", bench = "Geode", lines = { "new" }, config = {} },
			{
				id = "geode-1",
				library = "Geode",
				bench = "Geode",
				lines = { "old" },
				historical = true,
				config = {},
			},
			{ id = "other", library = "Other", bench = "Other", config = {} } :: any,
		},
		notMeasured = {},
	}
	return data
end

local function step(op: string, seconds: number, ok: boolean?, byMethod: { [string]: number }?): any
	return {
		op = op,
		ok = ok ~= false,
		seconds = seconds,
		byMethod = byMethod or { UpdateAsync = 1 },
	}
end

local function run(id: string, date: string, build: string, loads: { number }): any
	local steps = {}
	for _, seconds in loads do
		table.insert(steps, step("loadNew", seconds))
	end
	return {
		run = id,
		date = date,
		build = build,
		geodeSourceTree = if build == "1.0.0" then TREE_OLD else TREE_NEW,
		benchTree = TREE_OLD,
		libraries = {},
		refused = {},
		tasks = {
			{ mode = "perf", library = "Geode", report = { result = { steps = steps } } },
			{
				mode = "perf",
				library = "Other",
				report = { result = { steps = { step("loadNew", 1) } } },
			},
		},
	}
end

local function resultFor(
	results: { any },
	suite: string,
	scenario: string,
	metric: string,
	subject: string
): any
	for _, result in results do
		if
			result.suite == suite
			and result.scenario == scenario
			and result.metric == metric
			and result.subject == subject
		then
			return result
		end
	end
	return nil
end

return function(api: Spec.Api)
	local describe, it, expect = api.describe, api.it, api.expect

	describe("subjects and builds", function()
		it("picks the subject by bench library and build line", function()
			local data = catalog()
			expect(BenchPublish.subjectOf(data, "Geode", "2.0.0")).toBe("geode")
			expect(BenchPublish.subjectOf(data, "Geode", "1.0.0")).toBe("geode-1")
			expect(BenchPublish.subjectOf(data, "Other", "1.0.0")).toBe("other")
			expect(function()
				BenchPublish.subjectOf(data, "Geode", "3.0.0")
			end).toThrow("isn't in")
			expect(function()
				BenchPublish.subjectOf(data, "Unknown", "2.0.0")
			end).toThrow("no subject")
		end)

		it("finds a build by its source tree", function()
			expect(BenchPublish.buildOf(catalog(), TREE_NEW)).toBe("2.0.0")
			expect(BenchPublish.buildOf(catalog(), string.rep("3", 40))).toBeNil()
		end)

		it("adds a build at the end of the list and keeps the rest of the text", function()
			local text =
				'{\n\t"builds": [\n\t\t{ "id": "a", "note": "x ] y" }\n\t],\n\t"after": [1]\n}\n'
			local added = BenchPublish.addBuild(text, { id = "b" })
			local decoded = BenchResults.decode(added)
			expect(#decoded.builds).toBe(2)
			expect(decoded.builds[1].note).toBe("x ] y")
			expect(decoded.builds[2].id).toBe("b")
			expect(decoded.after[1]).toBe(1)
			-- the existing entry and what follows the list keep their text
			expect(string.sub(added, 1, 47)).toBe(string.sub(text, 1, 47))
			expect(string.sub(added, -20)).toBe(string.sub(text, -20))
		end)
	end)

	describe("a run's results", function()
		it("sum up each metric for the run alone", function()
			local data = run("aaaaaaaa", "2026-01-01T00:00:00Z", "2.0.0", { 0.3, 0.1, 0.2 })
			local file = BenchPublish.runFile(catalog(), data)
			expect(file.kind).toBe("run")
			expect(file.tasks[1].subject).toBe("geode")
			local time = resultFor(file.results, "load-save-release", "load-new", "time", "geode")
			expect(time.runs).toEqual({ "aaaaaaaa" })
			expect(time.value.median).toBe(0.2)
			expect(time.value.min).toBe(0.1)
			expect(time.value.max).toBe(0.3)
			expect(time.value.samples).toEqual({ 0.3, 0.1, 0.2 })
			local requests =
				resultFor(file.results, "load-save-release", "load-new", "requests", "geode")
			expect(requests.value.exact).toBe(true)
			expect(requests.value.byMethod).toEqual({ UpdateAsync = { min = 1, max = 1 } })
		end)

		it("count failed steps apart and name request methods by id", function()
			local data = run("aaaaaaaa", "2026-01-01T00:00:00Z", "2.0.0", { 0.2 })
			table.insert(data.tasks[1].report.result.steps, step("loadNew", 9, false))
			table.insert(
				data.tasks[1].report.result.steps,
				step("loadNew", 0.4, true, { UpdateAsync = 2, ["GetAsync (no cache)"] = 1 })
			)
			local file = BenchPublish.runFile(catalog(), data)
			local time = resultFor(file.results, "load-save-release", "load-new", "time", "geode")
			expect(time.value.n).toBe(2)
			expect(time.value.failed).toBe(1)
			local requests =
				resultFor(file.results, "load-save-release", "load-new", "requests", "geode")
			expect(requests.value.exact).toBe(false)
			expect(requests.value.byMethod["GetAsync:noCache"]).toEqual({ min = 0, max = 1 })
			expect(requests.value.byMethod.UpdateAsync).toEqual({ min = 1, max = 2 })
		end)

		it("read hops, kept profiles and throttled steps", function()
			local data = run("aaaaaaaa", "2026-01-01T00:00:00Z", "2.0.0", { 0.2 })
			table.insert(data.tasks, {
				mode = "join",
				library = "Geode",
				report = {
					result = {
						attempts = {
							{ coins = 888, step = step("hopLoad", 0.6) },
							{ coins = 777, step = step("hopLoad", 0.7) },
						},
						keep = { coins = 999, step = step("hopLoad", 0.8) },
					},
				},
			})
			table.insert(data.tasks, {
				mode = "throttle",
				library = "Geode",
				report = { result = { steps = { step("load", 32.5) } } },
			})
			local results = BenchPublish.runFile(catalog(), data).results
			local seen =
				resultFor(results, "server-hop", "old-releases", "final-save-seen", "geode")
			expect(seen.value).toEqual({ kind = "count", passed = 1, total = 2 })
			local kept = resultFor(results, "server-hop", "old-keeps", "value-seen", "geode")
			expect(kept.value.counts).toEqual({ ["999"] = 1 })
			local throttled = resultFor(results, "throttling", "load", "time", "geode")
			expect(throttled.value.kind).toBe("range")
			expect(throttled.value.median).toBeNil()
			expect(throttled.value.max).toBe(32.5)
		end)

		it("read the heap per profile and Geode's edit timings", function()
			local data = run("aaaaaaaa", "2026-01-01T00:00:00Z", "2.0.0", { 0.2 })
			table.insert(data.tasks, {
				mode = "memory",
				library = "Other",
				report = { result = { profiles = 20, perProfileKb = 12.3456 } },
			})
			table.insert(data.tasks, {
				mode = "memory",
				library = "Geode",
				report = { result = { notReadable = "not allowed" } },
			})
			data.lune = { cpu = { editsPerBatch = 1000, batches = { 0.006, 0.008, 0.007 } } }
			local file = BenchPublish.runFile(catalog(), data)
			local heap =
				resultFor(file.results, "memory", "loaded-profiles", "heap-per-profile", "other")
			expect(heap.value).toEqual({
				kind = "amount",
				unit = "KB",
				n = 1,
				median = 12.346,
				min = 12.346,
				max = 12.346,
				samples = { 12.346 },
			})
			expect(file.notRunnable[1].suite).toBe("memory")
			local edits =
				resultFor(file.results, "geode-edits", "increment", "time-per-edit", "geode")
			expect(edits.value.unit).toBe("us")
			expect(edits.value.median).toBe(7)
			expect(edits.value.samples).toEqual({ 6, 8, 7 })
			expect(file.lune).toBe(data.lune)
		end)

		it("list tasks that couldn't run or failed", function()
			local data = run("aaaaaaaa", "2026-01-01T00:00:00Z", "2.0.0", { 0.2 })
			table.insert(
				data.tasks,
				{ mode = "perf", library = "Other", report = { notRunnable = "no physics" } }
			)
			table.insert(
				data.tasks,
				{ mode = "throttle", library = "Other", problem = "timed out" }
			)
			local file = BenchPublish.runFile(catalog(), data)
			expect(file.notRunnable[1]).toEqual({
				subject = "other",
				suite = "load-save-release",
				reason = "no physics",
			})
			expect(file.problems[1]).toEqual({
				subject = "other",
				mode = "throttle",
				problem = "timed out",
			})
		end)
	end)

	describe("latest", function()
		it("gives every current subject the same last runs and a historical one its own", function()
			local runs = {
				run("00000001", "2026-01-01T00:00:00Z", "1.0.0", { 0.5 }),
				run("00000002", "2026-01-02T00:00:00Z", "1.0.0", { 0.6 }),
				run("00000003", "2026-01-03T00:00:00Z", "2.0.0", { 0.3 }),
				run("00000004", "2026-01-04T00:00:00Z", "2.0.0", { 0.2 }),
				run("00000005", "2026-01-05T00:00:00Z", "2.0.0", { 0.1 }),
			}
			local latest = BenchPublish.latest(catalog(), runs)
			expect(latest.updatedAt).toBe("2026-01-05T00:00:00Z")
			local current =
				resultFor(latest.results, "load-save-release", "load-new", "time", "geode")
			expect(current.runs).toEqual({ "00000004", "00000005" })
			local other =
				resultFor(latest.results, "load-save-release", "load-new", "time", "other")
			expect(other.runs).toEqual({ "00000004", "00000005" })
			expect(other.value.n).toBe(2)
			local old =
				resultFor(latest.results, "load-save-release", "load-new", "time", "geode-1")
			expect(old.runs).toEqual({ "00000001", "00000002" })
			expect(#latest.runs).toBe(4)
			-- a run without a measurement isn't listed for it
			runs[5].tasks[2] = nil
			local later = BenchPublish.latest(catalog(), runs)
			local fewer = resultFor(later.results, "load-save-release", "load-new", "time", "other")
			expect(fewer.runs).toEqual({ "00000004" })
			expect(latest.subjects[1].bench).toBeNil()
		end)

		it("leaves out a suite that is only recorded, which the run file keeps", function()
			local data = run("00000001", "2026-01-01T00:00:00Z", "2.0.0", { 0.2 })
			table.insert(data.tasks, {
				mode = "memory",
				library = "Other",
				report = { result = { profiles = 20, perProfileKb = 4 } },
			})
			local recorded = catalog()
			recorded.suites[4].recordedOnly = true
			local latest = BenchPublish.latest(recorded, { data })
			expect(
				resultFor(latest.results, "memory", "loaded-profiles", "heap-per-profile", "other")
			).toBeNil()
			expect(resultFor(latest.results, "load-save-release", "load-new", "time", "other")).never.toBeNil()
			expect(latest.suites[4].recordedOnly).toBe(true)
			local file = BenchPublish.runFile(recorded, data)
			expect(
				resultFor(file.results, "memory", "loaded-profiles", "heap-per-profile", "other")
			).never.toBeNil()
		end)

		it("is the same file for the same runs in any order", function()
			local a = run("00000001", "2026-01-01T00:00:00Z", "2.0.0", { 0.5 })
			local b = run("00000002", "2026-01-02T00:00:00Z", "2.0.0", { 0.6 })
			local one = BenchPublish.files(catalog(), { a, b }, "{}")
			local two = BenchPublish.files(catalog(), { b, a }, "{}")
			expect(one).toEqual(two)
		end)
	end)

	describe("the real catalog", function()
		it("covers every kept run", function()
			local data = BenchResults.decode(fs.readFile("benchmarks/catalog.json"))
			for _, name in fs.readDir("benchmarks/runs") do
				local kept = BenchResults.decode(fs.readFile(`benchmarks/runs/{name}`))
				local file = BenchPublish.runFile(data, kept)
				expect(#file.results > 0).toBe(true)
				expect(BenchPublish.buildOf(data, kept.geodeSourceTree)).toBe(kept.build)
			end
		end)
	end)
end
