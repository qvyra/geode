--!strict

-- Runs the Studio checks headlessly against live services via Open Cloud: builds the check place
-- with Rojo, uploads it to the test place as a saved version, runs each group as a Luau Execution
-- task against that version and exits non-zero on any failed check, failed task or timeout.
-- The API key comes from ROBLOX_API_KEY and is never printed

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local task = require("@lune/task")

type Config = {
	universeId: number,
	placeId: number,
}

type Result = {
	kind: "pass" | "fail" | "observed",
	name: string,
	detail: string?,
}

type Report = {
	results: { Result },
	pass: number,
	fail: number,
	observed: number,
}

local CONFIG_PATH = "tests/studio/live.json"
local PROJECT_PATH = "tests/studio/studio.project.json"
local PLACE_PATH = ".cache/live/GeodeStudioCheck.rbxl"
local API = "https://apis.roblox.com"
-- one task per group so none of them hits the five minute task limit
local GROUPS = { "services", "contracts", "profile" }
local TASK_TIMEOUT = 300
-- How long to wait on one task before calling it failed. A bit over the task's own limit, so a
-- task that ran out of time gets reported by Roblox first
local WAIT_LIMIT = TASK_TIMEOUT + 60
local POLL_INTERVAL = 5

local function fail(message: string): never
	stdio.ewrite(`live checks: {message}\n`)
	process.exit(1)
	error("unreachable")
end

local function readConfig(): Config
	if not fs.isFile(CONFIG_PATH) then
		fail(`{CONFIG_PATH} is missing`)
	end
	local config = serde.decode("json", fs.readFile(CONFIG_PATH))
	if type(config.universeId) ~= "number" or type(config.placeId) ~= "number" then
		fail(`{CONFIG_PATH} needs a numeric universeId and placeId`)
	end
	return config :: Config
end

local function apiKey(): string
	local key = process.env.ROBLOX_API_KEY
	if key == nil or key == "" then
		fail("ROBLOX_API_KEY isn't set")
	end
	return key :: string
end

-- Sends a request with the key and returns the decoded JSON body. Errors name the call and
-- status, never the key
local function call(
	key: string,
	method: "GET" | "POST",
	path: string,
	body: (string | buffer)?,
	contentType: string?
): any
	local headers: { [string]: string } = {
		["x-api-key"] = key,
		["content-type"] = contentType or "application/json",
	}
	local response = net.request({
		url = API .. path,
		-- Lune's typings want their own method union, this narrower one fits at runtime
		method = method :: any,
		headers = headers,
		body = body,
	})
	if not response.ok then
		fail(
			`{method} {path} answered {response.statusCode} {response.statusMessage}: {response.body}`
		)
	end
	if response.body == "" then
		return nil
	end
	return serde.decode("json", response.body)
end

local function build()
	if not fs.isDir(".cache/live") then
		fs.writeDir(".cache/live")
	end
	local result = process.exec("rojo", { "build", PROJECT_PATH, "--output", PLACE_PATH })
	if not result.ok then
		fail(`rojo build failed: {result.stderr}`)
	end
end

local function upload(key: string, config: Config): number
	local place = fs.readFile(PLACE_PATH)
	local answer = call(
		key,
		"POST",
		`/universes/v1/{config.universeId}/places/{config.placeId}/versions?versionType=Saved`,
		place,
		"application/octet-stream"
	)
	local version = answer and answer.versionNumber
	if type(version) ~= "number" then
		fail("the upload didn't return a version number")
	end
	return version
end

local function taskScript(group: string): string
	return table.concat({
		'local HttpService = game:GetService("HttpService")',
		'local Checks = require(game:GetService("ServerScriptService").GeodeCheck.tests.studio.Checks)',
		`return HttpService:JSONEncode(Checks.run(\{ "{group}" \}))`,
	}, "\n")
end

local function runGroup(
	key: string,
	config: Config,
	version: number,
	group: string
): (Report?, string?)
	local created = call(
		key,
		"POST",
		`/cloud/v2/universes/{config.universeId}/places/{config.placeId}/versions/{version}/luau-execution-session-tasks`,
		serde.encode("json", { script = taskScript(group), timeout = `{TASK_TIMEOUT}s` })
	)
	local path = created.path :: string
	local started = os.clock()
	local current = created
	while
		current.state ~= "COMPLETE"
		and current.state ~= "FAILED"
		and current.state ~= "CANCELLED"
	do
		if os.clock() - started > WAIT_LIMIT then
			return nil, `the {group} task didn't finish within {WAIT_LIMIT} seconds`
		end
		task.wait(POLL_INTERVAL)
		current = call(key, "GET", `/cloud/v2/{path}`)
	end

	local logs = call(key, "GET", `/cloud/v2/{path}/logs`)
	for _, chunk in logs and logs.luauExecutionSessionTaskLogs or {} do
		for _, line in chunk.messages or {} do
			print(`  {line}`)
		end
	end

	if current.state ~= "COMPLETE" then
		local reason = current.error and current.error.message or current.state
		return nil, `the {group} task ended {current.state}: {reason}`
	end
	local results = current.output and current.output.results
	if type(results) ~= "table" or type(results[1]) ~= "string" then
		return nil, `the {group} task returned no report`
	end
	return serde.decode("json", results[1]) :: Report, nil
end

local function main()
	local key = apiKey()
	local config = readConfig()

	print("building the check place")
	build()
	print("uploading it as a saved version")
	local version = upload(key, config)
	print(`running against version {version}`)

	local passed, failed, observed = {}, {}, {}
	local taskFailures = {}
	for _, group in GROUPS do
		print(`\n{group}:`)
		local report, problem = runGroup(key, config, version, group)
		if problem then
			table.insert(taskFailures, problem)
			continue
		end
		for _, result in (report :: Report).results do
			local line = if result.detail then `{result.name}: {result.detail}` else result.name
			if result.kind == "pass" then
				table.insert(passed, line)
			elseif result.kind == "fail" then
				table.insert(failed, line)
			else
				table.insert(observed, line)
			end
		end
	end

	print(`\n{#passed} passed, {#failed} failed, {#observed} observed`)
	if #observed > 0 then
		print("\nobserved, not judged:")
		for _, line in observed do
			print(`  {line}`)
		end
	end
	for _, line in failed do
		stdio.ewrite(`FAIL {line}\n`)
	end
	for _, problem in taskFailures do
		stdio.ewrite(`TASK {problem}\n`)
	end
	if #failed > 0 or #taskFailures > 0 then
		process.exit(1)
	end
end

main()

-- .lune/live.luau requires this, and a module has to return one value
return nil
