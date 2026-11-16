--!strict

-- Runs the Studio checks headlessly against live services via Open Cloud: builds the check place
-- with Rojo, uploads it to the test place as a saved version, runs each group as a Luau Execution
-- task against that version and exits non-zero on any failed check, failed task or timeout.
-- The API key comes from ROBLOX_API_KEY and is never printed

local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local OpenCloud = require("./OpenCloud")

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

local PROJECT_PATH = "tests/studio/studio.project.json"
local PLACE_PATH = ".cache/live/GeodeStudioCheck.rbxl"
-- one task per group so none of them hits the five minute task limit
local GROUPS = { "services", "contracts", "profile" }
local TASK_TIMEOUT = OpenCloud.TASK_LIMIT
-- How long to wait on one task before calling it failed. A bit over the task's own limit, so a
-- task that ran out of time gets reported by Roblox first
local WAIT_LIMIT = TASK_TIMEOUT + 60

local function taskScript(group: string): string
	return table.concat({
		'local HttpService = game:GetService("HttpService")',
		'local Checks = require(game:GetService("ServerScriptService").GeodeCheck.tests.studio.Checks)',
		`return HttpService:JSONEncode(Checks.run(\{ "{group}" \}))`,
	}, "\n")
end

local function runGroup(
	client: OpenCloud.Client,
	version: number,
	group: string
): (Report?, string?)
	local started = client.startTask(version, taskScript(group), TASK_TIMEOUT)
	local finished = client.finishTask(started, WAIT_LIMIT)
	for _, line in finished.logs do
		print(`  {line}`)
	end
	if finished.problem then
		return nil, `the {group} task {finished.problem}`
	end
	if finished.result == nil then
		return nil, `the {group} task returned no report`
	end
	return serde.decode("json", finished.result :: string) :: Report, nil
end

local function main()
	local client = OpenCloud.client("live checks")

	print("building the check place")
	client.build(PROJECT_PATH, PLACE_PATH)
	print("uploading it as a saved version")
	local version = client.upload(PLACE_PATH)
	print(`running against version {version}`)

	local passed, failed, observed = {}, {}, {}
	local taskFailures = {}
	for _, group in GROUPS do
		print(`\n{group}:`)
		local report, problem = runGroup(client, version, group)
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
