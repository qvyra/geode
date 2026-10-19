--!strict

-- The Open Cloud calls the live runners share: building a place with Rojo, uploading it to the
-- test place as a saved version and running Luau Execution tasks against that version. The API
-- key comes from ROBLOX_API_KEY and never shows up in output or errors

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local task = require("@lune/task")

export type Config = {
	universeId: number,
	placeId: number,
}

-- What a Luau Execution task looks like in the API's answers. Only the fields the runners read
export type Task = {
	path: string,
	state: string,
	output: { results: { unknown }? }?,
	error: { message: string? }?,
}

export type Finished = {
	task: Task,
	logs: { string },
	-- the first value the task's script returned, when it returned a string
	result: string?,
	-- set when the task didn't complete
	problem: string?,
}

export type Client = {
	fail: (message: string) -> never,
	config: Config,
	call: (
		method: "GET" | "POST",
		path: string,
		body: (string | buffer)?,
		contentType: string?
	) -> any,
	build: (projectPath: string, placePath: string) -> (),
	upload: (placePath: string) -> number,
	startTask: (version: number, script: string, timeout: number) -> Task,
	tryStartTask: (version: number, script: string, timeout: number) -> (Task?, string?),
	finishTask: (started: Task, waitLimit: number) -> Finished,
}

local CONFIG_PATH = "tests/studio/live.json"
local API = "https://apis.roblox.com"
local POLL_INTERVAL = 5

local OpenCloud = {}

-- A task can't run longer than this, Roblox stops it
OpenCloud.TASK_LIMIT = 300

--[=[
	Makes a client for the test place in tests/studio/live.json. `label` starts every error
	message, so the output says which runner failed
]=]
function OpenCloud.client(label: string): Client
	local function fail(message: string): never
		stdio.ewrite(`{label}: {message}\n`)
		process.exit(1)
		error("unreachable")
	end

	local key = process.env.ROBLOX_API_KEY
	if key == nil or key == "" then
		fail("ROBLOX_API_KEY isn't set")
	end

	if not fs.isFile(CONFIG_PATH) then
		fail(`{CONFIG_PATH} is missing`)
	end
	local config = serde.decode("json", fs.readFile(CONFIG_PATH))
	if type(config.universeId) ~= "number" or type(config.placeId) ~= "number" then
		fail(`{CONFIG_PATH} needs a numeric universeId and placeId`)
	end

	-- Sends a request with the key. Answers true and the decoded JSON body, or false and a message
	-- naming the call and status, never the key
	local function send(
		method: "GET" | "POST",
		path: string,
		body: (string | buffer)?,
		contentType: string?
	): (boolean, any)
		local headers: { [string]: string } = {
			["x-api-key"] = key :: string,
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
			return false,
				`{method} {path} answered {response.statusCode} {response.statusMessage}: {response.body}`
		end
		if response.body == "" then
			return true, nil
		end
		return true, serde.decode("json", response.body)
	end

	local function call(
		method: "GET" | "POST",
		path: string,
		body: (string | buffer)?,
		contentType: string?
	): any
		local ok, answer = send(method, path, body, contentType)
		if not ok then
			fail(answer)
		end
		return answer
	end

	local function build(projectPath: string, placePath: string)
		local folder = string.match(placePath, "^(.*)/[^/]+$")
		if folder and not fs.isDir(folder) then
			fs.writeDir(folder)
		end
		local result = process.exec("rojo", { "build", projectPath, "--output", placePath })
		if not result.ok then
			fail(`rojo build failed: {result.stderr}`)
		end
	end

	local function upload(placePath: string): number
		local answer = call(
			"POST",
			`/universes/v1/{config.universeId}/places/{config.placeId}/versions?versionType=Saved`,
			fs.readFile(placePath),
			"application/octet-stream"
		)
		local version = answer and answer.versionNumber
		if type(version) ~= "number" then
			fail("the upload didn't return a version number")
		end
		return version
	end

	local function taskPath(version: number): string
		return `/cloud/v2/universes/{config.universeId}/places/{config.placeId}/versions/{version}/luau-execution-session-tasks`
	end

	local function startTask(version: number, script: string, timeout: number): Task
		return call(
			"POST",
			taskPath(version),
			serde.encode("json", { script = script, timeout = `{timeout}s` })
		)
	end

	-- Like startTask, but a refusal comes back as a message instead of ending the run
	local function tryStartTask(version: number, script: string, timeout: number): (Task?, string?)
		local ok, answer = send(
			"POST",
			taskPath(version),
			serde.encode("json", { script = script, timeout = `{timeout}s` })
		)
		if not ok then
			return nil, answer
		end
		return answer, nil
	end

	-- Polls until the task is done or `waitLimit` seconds pass, then fetches its logs
	local function finishTask(started: Task, waitLimit: number): Finished
		local path = started.path
		local begun = os.clock()
		local current = started
		while
			current.state ~= "COMPLETE"
			and current.state ~= "FAILED"
			and current.state ~= "CANCELLED"
		do
			if os.clock() - begun > waitLimit then
				return {
					task = current,
					logs = {},
					result = nil,
					problem = `didn't finish within {waitLimit} seconds`,
				}
			end
			task.wait(POLL_INTERVAL)
			current = call("GET", `/cloud/v2/{path}`)
		end

		local lines = {}
		local logs = call("GET", `/cloud/v2/{path}/logs`)
		for _, chunk in logs and logs.luauExecutionSessionTaskLogs or {} do
			for _, line in chunk.messages or {} do
				table.insert(lines, line)
			end
		end

		if current.state ~= "COMPLETE" then
			local reason = current.error and current.error.message or current.state
			return {
				task = current,
				logs = lines,
				result = nil,
				problem = `ended {current.state}: {reason}`,
			}
		end
		local results = current.output and current.output.results
		local first = if type(results) == "table" then results[1] else nil
		return {
			task = current,
			logs = lines,
			result = if type(first) == "string" then first else nil,
			problem = nil,
		}
	end

	return {
		fail = fail,
		config = config :: Config,
		call = call,
		build = build,
		upload = upload,
		startTask = startTask,
		tryStartTask = tryStartTask,
		finishTask = finishTask,
	}
end

return OpenCloud
