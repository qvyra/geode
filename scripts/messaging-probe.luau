--!strict

-- Starts the cloud side of the messaging probe: a Luau Execution task on the test place's latest
-- version that runs tests/studio/MessagingProbe.luau on one topic and reports what it heard.
-- Start a Studio playtest of the same place while it runs and call the probe there with the
-- role "studio" and the topic printed below. The key comes from ROBLOX_API_KEY, never printed
--
--   lune run scripts/messaging-probe [seconds]

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local task = require("@lune/task")

local CONFIG_PATH = "tests/studio/live.json"
local PROBE_PATH = "tests/studio/MessagingProbe.luau"
local API = "https://apis.roblox.com"
local DEFAULT_SECONDS = 200
-- leaves room under the five minute task limit for the probe's own wind down
local MAX_SECONDS = 270
local POLL_INTERVAL = 5

local function fail(message: string): never
	stdio.ewrite(`messaging probe: {message}\n`)
	process.exit(1)
	error("unreachable")
end

local function call(key: string, method: "GET" | "POST", path: string, body: string?): any
	local headers: { [string]: string } =
		{ ["x-api-key"] = key, ["content-type"] = "application/json" }
	local response = net.request({
		url = API .. path,
		method = method :: any,
		headers = headers,
		body = body,
	})
	if not response.ok then
		fail(
			`{method} {path} answered {response.statusCode} {response.statusMessage}: {response.body}`
		)
	end
	return if response.body == "" then nil else serde.decode("json", response.body)
end

-- The task runs against whatever version is live, so the probe goes in as source rather than
-- as a module of an uploaded place
local function taskScript(topic: string, seconds: number): string
	local source = fs.readFile(PROBE_PATH)
	return table.concat({
		"local Probe = (function()",
		source,
		"end)()",
		`local result = Probe.run("{topic}", "cloud", {seconds})`,
		'return game:GetService("HttpService"):JSONEncode(result)',
	}, "\n")
end

local function main()
	local key = process.env.ROBLOX_API_KEY
	if key == nil or key == "" then
		fail("ROBLOX_API_KEY isn't set")
	end
	local config = serde.decode("json", fs.readFile(CONFIG_PATH))
	local seconds = math.min(tonumber(process.args[1]) or DEFAULT_SECONDS, MAX_SECONDS)
	local topic = `geode-check-probe-{os.time()}`

	local created = call(
		key :: string,
		"POST",
		`/cloud/v2/universes/{config.universeId}/places/{config.placeId}/luau-execution-session-tasks`,
		serde.encode("json", { script = taskScript(topic, seconds), timeout = "300s" })
	)
	print(`topic {topic}`)
	print(`cloud side listening for {seconds} seconds, start the Studio side now`)

	local path = created.path :: string
	local current = created
	local started = os.clock()
	while
		current.state ~= "COMPLETE"
		and current.state ~= "FAILED"
		and current.state ~= "CANCELLED"
	do
		if os.clock() - started > 360 then
			fail("the task didn't finish in time")
		end
		task.wait(POLL_INTERVAL)
		current = call(key :: string, "GET", `/cloud/v2/{path}`)
	end

	local logs = call(key :: string, "GET", `/cloud/v2/{path}/logs`)
	for _, chunk in logs and logs.luauExecutionSessionTaskLogs or {} do
		for _, line in chunk.messages or {} do
			print(`  {line}`)
		end
	end
	if current.state ~= "COMPLETE" then
		fail(`the task ended {current.state}: {current.error and current.error.message or "?"}`)
	end
	local results = current.output and current.output.results
	print(`cloud result {results and results[1] or "none"}`)
end

main()

return nil
