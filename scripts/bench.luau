--!strict

-- Benchmarks Geode next to ProfileStore, ProfileService, Lapis and DataStore2 on live Roblox
-- services. Downloads each library at the commit pinned in tests/bench/libraries.json, refuses
-- any whose license no longer matches the recorded hash, builds a place holding the usual Studio
-- checks plus the bench, uploads it to the test place as a saved version, and runs the bench
-- modes as Luau Execution tasks. Results land in .cache/bench as JSON and a markdown summary.
-- The API key comes from ROBLOX_API_KEY and is never printed
--
--   lune run bench [library,library,...]

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local OpenCloud = require("./OpenCloud")

type Pin = {
	name: string,
	repo: string,
	ref: string,
	version: string,
	dependencyOf: string?,
	license: { path: string, name: string, sha256: string },
	files: { [string]: string },
	mount: string,
	swap: { file: string, find: string, replace: string }?,
}

type TaskRecord = {
	mode: string,
	library: string,
	problem: string?,
	report: any,
	logTail: { string },
}

local PINS_PATH = "tests/bench/libraries.json"
local STUDIO_PROJECT = "tests/studio/studio.project.json"
local STUDIO_BASE = "tests/studio"
local OUT = ".cache/bench"
local LIBS = `{OUT}/libs`
local PROJECT_PATH = `{OUT}/bench.project.json`
local PLACE_PATH = `{OUT}/GeodeBench.rbxl`
local RESULTS_PATH = `{OUT}/results.json`
local SUMMARY_PATH = `{OUT}/summary.md`
local LIBRARIES = { "Geode", "ProfileStore", "ProfileService", "Lapis", "DataStore2" }
local TASK_TIMEOUT = OpenCloud.TASK_LIMIT
local WAIT_LIMIT = TASK_TIMEOUT + 90
local LOG_TAIL = 40

--// downloads

local function writeFile(path: string, contents: string)
	local folder = string.match(path, "^(.*)/[^/]+$")
	if folder and not fs.isDir(folder) then
		fs.writeDir(folder)
	end
	fs.writeFile(path, contents)
end

local function fetch(pin: Pin, path: string): (string?, string?)
	local url = `https://raw.githubusercontent.com/{pin.repo}/{pin.ref}/{path}`
	local response = net.request(url)
	if not response.ok then
		return nil, `{url} answered {response.statusCode}`
	end
	return response.body, nil
end

local function countPlain(text: string, find: string): number
	local count, start = 0, 1
	while true do
		local first, last = string.find(text, find, start, true)
		if first == nil then
			return count
		end
		count += 1
		start = (last :: number) + 1
	end
end

-- Downloads one library. Returns a reason when it can't be run
local function download(pin: Pin): string?
	local license, problem = fetch(pin, pin.license.path)
	if license == nil then
		return problem
	end
	local hash = serde.hash("sha256", license)
	if hash ~= pin.license.sha256 then
		return `its license changed (sha256 {hash}, recorded {pin.license.sha256} for {pin.license.name})`
	end
	local folder = `{LIBS}/{pin.name}`
	if fs.isDir(folder) then
		fs.removeDir(folder)
	end
	for source, target in pin.files do
		local body, failure = fetch(pin, source)
		if body == nil then
			return failure
		end
		local text = body :: string
		local swap = pin.swap
		if swap and swap.file == source then
			-- the one place the library picks up DataStoreService, pointed at the bench proxy
			local found = countPlain(text, swap.find)
			if found ~= 1 then
				return `the line the bench swaps shows up {found} times in {source}, expected once`
			end
			local first, last = string.find(text, swap.find, 1, true)
			text = string.sub(text, 1, (first :: number) - 1)
				.. swap.replace
				.. string.sub(text, (last :: number) + 1)
		end
		writeFile(`{folder}/{target}`, text)
	end
	return nil
end

--// the bench place

-- Joins a path onto a base and folds `.` and `..` parts
local function normalize(path: string): string
	local parts = {}
	for part in string.gmatch(path, "[^/]+") do
		if part == ".." and #parts > 0 and parts[#parts] ~= ".." then
			table.remove(parts)
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return table.concat(parts, "/")
end

-- `.cache/bench` sits two folders down, so repo paths are reached through ../..
local function fromOut(repoPath: string): string
	return `../../{repoPath}`
end

local function rebase(node: any)
	for key, child in node do
		if key == "$path" and type(child) == "string" then
			node[key] = fromOut(normalize(`{STUDIO_BASE}/{child}`))
		elseif type(child) == "table" then
			rebase(child)
		end
	end
end

-- The usual check place with the bench and the downloaded libraries next to the checks, so the
-- test place still runs the Studio checks after a bench upload
local function writeProject(pins: { Pin })
	local project = serde.decode("json", fs.readFile(STUDIO_PROJECT))
	rebase(project.tree)
	project.name = "GeodeBench"
	local vendor: { [string]: unknown } = { ["$className"] = "Folder" }
	for _, pin in pins do
		vendor[pin.name] = { ["$path"] = `libs/{pin.name}/{pin.mount}` }
	end
	local tests = project.tree.ServerScriptService.GeodeCheck.tests
	tests.bench = {
		["$className"] = "Folder",
		Bench = { ["$path"] = fromOut("tests/bench/Bench.luau") },
		Libraries = { ["$path"] = fromOut("tests/bench/Libraries.luau") },
		Proxy = { ["$path"] = fromOut("tests/bench/Proxy.luau") },
		Vendor = vendor,
	}
	writeFile(PROJECT_PATH, serde.encode("json", project, true))
end

--// tasks

local function taskScript(mode: string, library: string, run: string): string
	return table.concat({
		'local HttpService = game:GetService("HttpService")',
		'local Bench = require(game:GetService("ServerScriptService").GeodeCheck.tests.bench.Bench)',
		`return HttpService:JSONEncode(Bench.run(\{ mode = "{mode}", library = "{library}", run = "{run}" \}))`,
	}, "\n")
end

local function tail(lines: { string }): { string }
	local from = math.max(1, #lines - LOG_TAIL + 1)
	return table.move(lines, from, #lines, 1, {})
end

local function record(mode: string, library: string, finished: OpenCloud.Finished): TaskRecord
	local report = nil
	local problem = finished.problem
	if problem == nil then
		if finished.result then
			local ok, decoded = pcall(serde.decode, "json" :: "json", finished.result :: string)
			if ok then
				report = decoded
			else
				problem = "returned a report that isn't JSON"
			end
		else
			problem = "returned no report"
		end
	end
	if report and report.error then
		print(`  {mode} {library}: the bench reported {report.error}`)
	end
	if report and report.notRunnable then
		print(`  {mode} {library}: not runnable here, {report.notRunnable}`)
	end
	if problem then
		print(`  {mode} {library}: the task {problem}`)
	end
	return {
		mode = mode,
		library = library,
		problem = problem,
		report = report,
		logTail = tail(finished.logs),
	}
end

local function runOne(
	client: OpenCloud.Client,
	version: number,
	mode: string,
	library: string,
	run: string
): TaskRecord
	print(`{mode} {library}`)
	local started = client.startTask(version, taskScript(mode, library, run), TASK_TIMEOUT)
	return record(mode, library, client.finishTask(started, WAIT_LIMIT))
end

-- Starts the old and the new server of a hop together. Whether Roblox runs both at once is part
-- of what this finds out, so a refused second task is recorded rather than fatal
local function runHop(
	client: OpenCloud.Client,
	version: number,
	library: string,
	run: string
): { TaskRecord }
	print(`hop {library}`)
	local holder = client.startTask(version, taskScript("hold", library, run), TASK_TIMEOUT)
	local joiner, refused =
		client.tryStartTask(version, taskScript("join", library, run), TASK_TIMEOUT)
	local records = { record("hold", library, client.finishTask(holder, WAIT_LIMIT)) }
	if joiner then
		table.insert(records, record("join", library, client.finishTask(joiner, WAIT_LIMIT * 2)))
	else
		print(`  the second task was refused: {refused}`)
		table.insert(records, {
			mode = "join",
			library = library,
			problem = `refused while the first ran: {refused}`,
			report = nil,
			logTail = {},
		})
	end
	return records
end

--// summary

local function median(values: { number }): number?
	if #values == 0 then
		return nil
	end
	local sorted = table.clone(values)
	table.sort(sorted)
	local middle = (#sorted + 1) / 2
	if middle % 1 == 0 then
		return sorted[middle]
	end
	return (sorted[math.floor(middle)] + sorted[math.ceil(middle)]) / 2
end

local function seconds(value: number?): string
	return if value then string.format("%.2f", value) else "-"
end

local function spread(values: { number }): string
	if #values == 0 then
		return "-"
	end
	local sorted = table.clone(values)
	table.sort(sorted)
	return `{seconds(median(sorted))} ({seconds(sorted[1])} to {seconds(sorted[#sorted])}, n={#sorted})`
end

local function counts(values: { number }): string
	if #values == 0 then
		return "-"
	end
	local sorted = table.clone(values)
	table.sort(sorted)
	if sorted[1] == sorted[#sorted] then
		return tostring(sorted[1])
	end
	return `{sorted[1]} to {sorted[#sorted]}`
end

-- Why a library couldn't run in a mode, if it couldn't
local function notRunnable(records: { TaskRecord }, modes: { string }, library: string): string?
	for _, entry in records do
		local reason = entry.report and entry.report.notRunnable
		if reason and entry.library == library and table.find(modes, entry.mode) then
			return reason
		end
	end
	return nil
end

local function summarize(records: { TaskRecord }): string
	local lines = {
		"| Library | Load new (s) | Load stored (s) | Save (s) | Release (s) | Requests: load / save / release |",
		"| --- | --- | --- | --- | --- | --- |",
	}
	for _, library in LIBRARIES do
		local blocked = notRunnable(records, { "perf" }, library)
		if blocked then
			table.insert(lines, `| {library} | not measured: {blocked} |`)
			continue
		end
		local times: { [string]: { number } } = { loadNew = {}, load = {}, save = {}, release = {} }
		local requests: { [string]: { number } } = { load = {}, save = {}, release = {} }
		local failures = 0
		for _, entry in records do
			local result = entry.report and entry.report.result
			if entry.mode == "perf" and entry.library == library and result then
				for _, step in result.steps do
					if not step.ok then
						failures += 1
						continue
					end
					if times[step.op] then
						table.insert(times[step.op], step.seconds)
					end
					local kind = if step.op == "loadNew" then "load" else step.op
					if requests[kind] then
						table.insert(requests[kind], step.requests)
					end
				end
			end
		end
		table.insert(
			lines,
			`| {library}{if failures > 0 then ` ({failures} failed steps)` else ""} | {spread(
				times.loadNew
			)} | {spread(times.load)} | {spread(times.save)} | {spread(times.release)} | {counts(
				requests.load
			)} / {counts(requests.save)} / {counts(requests.release)} |`
		)
	end

	table.insert(lines, "")
	table.insert(
		lines,
		"| Library | Hop after release (s) | Got the final save | Holder keeps it (s) | Coins seen | Same JobId |"
	)
	table.insert(lines, "| --- | --- | --- | --- | --- | --- |")
	for _, library in LIBRARIES do
		local blocked = notRunnable(records, { "hold", "join" }, library)
		if blocked then
			table.insert(lines, `| {library} | not measured: {blocked} |`)
			continue
		end
		local hops, latest, total = {}, 0, 0
		local keepTime, keepCoins, sameJob = "-", "-", "-"
		for _, entry in records do
			local result = entry.report and entry.report.result
			if entry.mode == "join" and entry.library == library and result then
				for _, attempt in result.attempts do
					if attempt.step then
						total += 1
						if attempt.step.ok then
							table.insert(hops, attempt.step.seconds)
						end
						if attempt.coins == 888 then
							latest += 1
						end
						sameJob = tostring(attempt.sameJobId)
					end
				end
				local keep = result.keep
				if keep and keep.step then
					keepTime = if keep.step.ok
						then seconds(keep.step.seconds)
						else `failed after {seconds(keep.step.seconds)}: {keep.step.err}`
					keepCoins = tostring(keep.coins)
				end
			end
		end
		table.insert(
			lines,
			`| {library} | {spread(hops)} | {latest} of {total} | {keepTime} | {keepCoins} | {sameJob} |`
		)
	end

	table.insert(lines, "")
	table.insert(lines, "| Library | Burst | Load | Save | Release | Failed requests |")
	table.insert(lines, "| --- | --- | --- | --- | --- | --- |")
	for _, library in LIBRARIES do
		local blocked = notRunnable(records, { "throttle" }, library)
		if blocked then
			table.insert(lines, `| {library} | not measured: {blocked} |`)
			continue
		end
		for _, entry in records do
			local result = entry.report and entry.report.result
			if entry.mode == "throttle" and entry.library == library and result then
				local cells = { load = "-", save = "-", release = "-" }
				local failedRequests = 0
				for _, step in result.steps do
					cells[step.op] = if step.ok
						then `{seconds(step.seconds)} s`
						else `failed after {seconds(step.seconds)} s`
					failedRequests += step.failedRequests
				end
				local burst = result.burst
				table.insert(
					lines,
					`| {library} | {burst.sent} sent, {burst.failed} failed, {burst.pending} pending | {cells.load} | {cells.save} | {cells.release} | {failedRequests} |`
				)
			end
		end
	end
	return table.concat(lines, "\n") .. "\n"
end

--// main

local function main()
	local wanted = LIBRARIES
	if process.args[1] then
		wanted = {}
		for name in string.gmatch(process.args[1], "[^,]+") do
			table.insert(wanted, name)
		end
	end

	local manifest = serde.decode("json", fs.readFile(PINS_PATH))
	local pins: { Pin } = manifest.libraries
	local mounted: { Pin } = {}
	local refused: { [string]: string } = {}
	for _, pin in pins do
		print(`downloading {pin.name} {pin.version}`)
		local problem = download(pin)
		if problem then
			print(`  refusing {pin.name}: {problem}`)
			refused[pin.name] = problem
		else
			table.insert(mounted, pin)
		end
	end
	-- a library is only run when it and everything it depends on came through
	local runnable: { string } = {}
	for _, library in wanted do
		local blocked = refused[library] ~= nil
		for _, pin in pins do
			if pin.dependencyOf == library and refused[pin.name] then
				blocked = true
			end
		end
		if blocked then
			refused[library] = refused[library] or "a dependency was refused"
		else
			table.insert(runnable, library)
		end
	end

	print("building the bench place")
	writeProject(mounted)
	-- everything up to here works without the key, which helps when changing the bench
	local client = OpenCloud.client("bench")
	client.build(PROJECT_PATH, PLACE_PATH)
	print("uploading it as a saved version")
	local version = client.upload(PLACE_PATH)
	print(`running against version {version}`)

	local run = string.format("%08x", math.random(0, 0x7fffffff))
	local records: { TaskRecord } = {}
	for _, library in runnable do
		table.insert(records, runOne(client, version, "perf", library, run))
	end
	for _, library in runnable do
		for _, entry in runHop(client, version, library, run) do
			table.insert(records, entry)
		end
	end
	for _, library in runnable do
		table.insert(records, runOne(client, version, "throttle", library, run))
	end

	local pinned = {}
	for _, pin in pins do
		table.insert(pinned, {
			name = pin.name,
			repo = pin.repo,
			ref = pin.ref,
			version = pin.version,
			license = pin.license.name,
			licenseSha256 = pin.license.sha256,
		})
	end
	local results = {
		run = run,
		date = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		placeVersion = version,
		pins = pinned,
		refused = refused,
		tasks = records,
	}
	writeFile(RESULTS_PATH, serde.encode("json", results, true))
	local summary = `## Bench run {run}, place version {version}\n\n{summarize(records)}`
	writeFile(SUMMARY_PATH, summary)
	print(`\n{summary}`)

	local problems = 0
	for _, entry in records do
		if entry.problem then
			problems += 1
			stdio.ewrite(`TASK {entry.mode} {entry.library} {entry.problem}\n`)
		end
	end
	for name, reason in refused do
		stdio.ewrite(`REFUSED {name}: {reason}\n`)
	end
	if problems > 0 or next(refused) ~= nil then
		process.exit(1)
	end
end

main()

-- .lune/bench.luau requires this, and a module has to return one value
return nil
