--!strict

local Types = require("./Types")

type AdapterError = Types.AdapterError
type ErrorKind = Types.ErrorKind

local Errors = {}

-- DS errors start with a three digit code, e.g. "304: UpdateAsync request dropped".
-- TODO(verify): table below is from memory of the Roblox error code reference. Anything
-- missing falls back to "unknown" so nothing is retried on a guess
local CODE_KINDS: { [number]: ErrorKind } = {
	[101] = "invalidKey", -- key name empty
	[102] = "invalidKey", -- key name too long
	[103] = "invalidValue", -- value type not allowed
	[104] = "invalidValue", -- value can't be serialized
	[105] = "tooLarge", -- serialized value over the size limit
	[106] = "invalidValue", -- sorted value isn't an integer in range
	[301] = "throttled", -- GetAsync
	[302] = "throttled", -- SetAsync
	[303] = "throttled", -- IncrementAsync
	[304] = "throttled", -- UpdateAsync
	[305] = "throttled", -- GetSortedAsync
	[306] = "throttled", -- RemoveAsync
	[401] = "noAccess",
	[402] = "noAccess",
	[403] = "noAccess", -- Studio API access disabled
	[404] = "internal",
	[501] = "internal",
	[502] = "internal",
	[503] = "internal",
	[504] = "internal",
	[505] = "internal",
}

-- MemoryStore and MessagingService errors have no numeric code, so match on wording.
-- Exact MS error strings are unverified
local PHRASE_KINDS: { { pattern: string, kind: ErrorKind } } = {
	{ pattern = "throttled", kind = "throttled" },
	{ pattern = "throttling", kind = "throttled" },
	{ pattern = "too large", kind = "tooLarge" },
	{ pattern = "exceeds", kind = "tooLarge" },
	{ pattern = "not found", kind = "notFound" },
	{ pattern = "internal", kind = "internal" },
}

--[=[
	Turns whatever a Roblox service threw into an `AdapterError`

	@within Raw
	@param raw unknown -- the value caught by pcall
	@return AdapterError
]=]
function Errors.classify(raw: unknown): AdapterError
	local message = tostring(raw)
	local code = tonumber(string.match(message, "^(%d%d%d):"))
	if code then
		return { kind = CODE_KINDS[code] or "unknown", code = code, message = message }
	end

	local lowered = string.lower(message)
	for _, entry in PHRASE_KINDS do
		if string.find(lowered, entry.pattern, 1, true) then
			return { kind = entry.kind, message = message }
		end
	end
	return { kind = "unknown", message = message }
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
