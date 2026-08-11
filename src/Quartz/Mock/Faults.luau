--!strict

local Errors = require("../Errors")
local Types = require("../Types")

-- Set one field: `{ code = 304 }`, `{ latency = 2 }`, `{ landed = 304 }` or
-- `{ foreignWrite = fn, rerun = true }`. A foreign write runs before the call as if another
-- server got there first. `rerun` also shows the caller's transform the stale value once,
-- like a real UpdateAsync retry. `landed` lets a DataStore write go through and still reports
-- the error, since Roblox doesn't promise a failed write didn't happen
export type FaultSpec = {
	code: number?,
	landed: number?,
	latency: number?,
	foreignWrite: ((current: unknown) -> unknown)?,
	rerun: boolean?,
}

export type Fault = "throttle" | FaultSpec

export type FaultRule = {
	-- "dataStore", "orderedDataStore", "hashMap", "sortedMap", "queue", "messaging", "teleport"
	service: string?,
	store: string?,
	method: string?,
	key: string?,
	fault: Fault,
	times: number?,
}

export type ForeignWrite = {
	transform: (current: unknown) -> unknown,
	rerun: boolean,
}

type Rule = {
	service: string?,
	store: string?,
	method: string?,
	key: string?,
	fault: Fault,
	remaining: number?,
}

type Fields = {
	_rules: { Rule },
}

local Faults = {}
Faults.__index = Faults

export type Faults = typeof(setmetatable({} :: Fields, Faults))

-- Injected throttles carry the method's throttle code, since that's what `classify` reads
-- first
function Faults.new(): Faults
	return setmetatable({ _rules = {} } :: Fields, Faults)
end

function Faults.add(self: Faults, rule: FaultRule)
	table.insert(self._rules, {
		service = rule.service,
		store = rule.store,
		method = rule.method,
		key = rule.key,
		fault = rule.fault,
		remaining = rule.times,
	})
end

function Faults.clear(self: Faults)
	table.clear(self._rules)
end

local function matches(rule: Rule, service: string, store: string, method: string, key: string?)
	if rule.service and rule.service ~= service then
		return false
	end
	if rule.store and rule.store ~= store then
		return false
	end
	if rule.method and rule.method ~= method then
		return false
	end
	if rule.key then
		return key ~= nil and string.match(key, `^{rule.key}$`) ~= nil
	end
	return true
end

local function throttleError(service: string, method: string): Types.AdapterError
	local code = if service == "dataStore" or service == "orderedDataStore"
		then Errors.THROTTLE_CODES[method]
		else nil
	if code then
		return Errors.classify(`{code}: {method} request was throttled (injected)`)
	end
	return Errors.classify(`Request was throttled (injected {service}.{method})`)
end

--[=[
	Runs every matching rule for one call. Latency waits on the clock, an error ends the call,
	and a foreign write is handed back for the adapter to apply. So is a landed error, which the
	adapter reports after its write went through
]=]
function Faults.apply(
	self: Faults,
	clock: Types.Clock,
	service: string,
	store: string,
	method: string,
	key: string?
): (Types.AdapterError?, ForeignWrite?, Types.AdapterError?)
	local foreign: ForeignWrite? = nil
	local landed: Types.AdapterError? = nil
	for index = #self._rules, 1, -1 do
		local rule = self._rules[index]
		if not matches(rule, service, store, method, key) then
			continue
		end
		if rule.remaining then
			rule.remaining -= 1
			if rule.remaining <= 0 then
				table.remove(self._rules, index)
			end
		end

		local fault = rule.fault
		if fault == "throttle" then
			return throttleError(service, method), nil, nil
		elseif type(fault) == "table" then
			local fields: FaultSpec = fault
			if fields.code then
				return Errors.classify(`{fields.code}: injected fault on {service}.{method}`),
					nil,
					nil
			elseif fields.landed then
				landed = Errors.classify(
					`{fields.landed}: injected fault after the write landed on {service}.{method}`
				)
			elseif fields.latency then
				clock:wait(fields.latency)
			elseif fields.foreignWrite then
				foreign = { transform = fields.foreignWrite, rerun = fields.rerun == true }
			end
		end
	end
	return nil, foreign, landed
end

return Faults
