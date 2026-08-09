--!strict

local Types = require("./Types")

type AdapterError = Types.AdapterError
type ErrorKind = Types.ErrorKind

local Errors = {}

-- DataStore errors lead with a three digit code ("304: UpdateAsync request dropped").
-- Only throttled and internal get retried, so an unlisted code stays "unknown" and is never
-- retried on a guess
local CODE_KINDS: { [number]: ErrorKind } = {
	[101] = "invalidKey", -- key name empty
	[102] = "invalidKey", -- key name too long
	[103] = "invalidValue", -- value type not allowed
	[104] = "invalidValue", -- value can't be serialized
	[105] = "tooLarge", -- serialized value over the size limit
	[106] = "invalidValue", -- sorted value isn't an integer in range
	[107] = "invalidValue",
	[301] = "throttled", -- GetAsync
	[302] = "throttled", -- SetAsync
	[303] = "throttled", -- IncrementAsync
	[304] = "throttled", -- UpdateAsync
	[305] = "throttled", -- GetSortedAsync
	[306] = "throttled", -- RemoveAsync
	[401] = "unavailable", -- the server is shutting down
	[402] = "unavailable", -- the server is shutting down
	[403] = "noAccess", -- Studio API access disabled
	[404] = "internal", -- the ordered store doesn't exist yet, documented as try again later
	[501] = "internal",
	[502] = "internal",
	-- "nothing found where something should be", can mean corruption. Still documented as
	-- retryable
	[503] = "internal",
	[504] = "internal",
	[505] = "internal",
	[509] = "noAccess", -- writes blocked on a personal server
	[511] = "invalidValue", -- metadata too large
	[512] = "invalidValue", -- too many user ids
	[513] = "invalidValue", -- user id or metadata in the wrong format
}

-- Newer throttles carry a name instead of a code, like KeyThrottled or
-- StandardWriteGameServerThrottled
local THROTTLE_NAME = "%u%a*Throttled"

-- MemoryStore and messaging errors have no code and no documented wording, so match loosely
local PHRASE_KINDS: { { pattern: string, kind: ErrorKind } } = {
	{ pattern = "throttled", kind = "throttled" },
	{ pattern = "throttling", kind = "throttled" },
	{ pattern = "too large", kind = "tooLarge" },
	{ pattern = "exceeds", kind = "tooLarge" },
	{ pattern = "not found", kind = "notFound" },
	{ pattern = "internal", kind = "internal" },
}

Errors.THROTTLE_CODES = table.freeze({
	get = 301,
	set = 302,
	increment = 303,
	update = 304,
	getSorted = 305,
	remove = 306,
} :: { [string]: number })

--[=[
	Turns whatever a Roblox service threw into an `AdapterError`.

	DataStore errors are matched by code or throttle name. MemoryStore and MessagingService
	errors have no documented wording, so when nothing matches they count as a retryable
	internal error. A DataStore error that matches nothing stays `unknown` and is never retried

	@within Raw
	@param raw unknown -- the value caught by pcall
	@param service ErrorSource? -- which service threw it, defaults to "dataStore"
	@return AdapterError
]=]
function Errors.classify(raw: unknown, service: Types.ErrorSource?): AdapterError
	local message = tostring(raw)
	local code = tonumber(string.match(message, "^(%d%d%d):"))
	if code then
		return { kind = CODE_KINDS[code] or "unknown", code = code, message = message }
	end
	if string.find(message, THROTTLE_NAME) then
		return { kind = "throttled", message = message }
	end

	local lowered = string.lower(message)
	for _, entry in PHRASE_KINDS do
		if string.find(lowered, entry.pattern, 1, true) then
			return { kind = entry.kind, message = message }
		end
	end
	local fallback: ErrorKind = if service == "memoryStore" or service == "messaging"
		then "internal"
		else "unknown"
	return { kind = fallback, message = message }
end

function Errors.ok<T>(value: T): Types.Result<T>
	return { ok = true, value = value }
end

function Errors.fail<T>(kind: ErrorKind, message: string, code: number?): Types.Result<T>
	return { ok = false, error = { kind = kind, code = code, message = message } }
end

function Errors.failWith<T>(err: AdapterError): Types.Result<T>
	return { ok = false, error = err }
end

return Errors
