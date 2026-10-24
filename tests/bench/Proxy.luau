--!strict

-- A stand-in for DataStoreService that every benchmarked library gets instead of the real one.
-- It forwards each call unchanged and logs it, which is how the bench counts the requests a
-- load or a save makes. It also refuses any DataStore other than the one the library was given,
-- so the bench can't touch anything else. Plain Luau, so it runs in Lune against a fake service

export type Call = {
	method: string,
	store: string,
	scope: string?,
	key: string?,
	started: number,
	finished: number?,
	ok: boolean?,
	err: string?,
	-- a GetAsync told to skip the cache (DataStoreGetOptions.UseCache = false)
	noCache: boolean?,
}

-- Where an extra DataStore a library asks for ends up instead: the allowed name, under a scope
export type Alias = {
	scope: string,
}

export type Options = {
	real: any,
	allowed: string,
	clock: () -> number,
	-- extra DataStore names the library uses, each moved under a scope of the allowed name
	aliases: { [string]: Alias }?,
}

export type Proxy = {
	service: any,
	calls: { Call },
	allowed: string,
}

-- Store methods that reach the DataStore backend. Anything else on a store is refused, so a
-- library can't make a request the log doesn't see
local STORE_METHODS = {
	"GetAsync",
	"SetAsync",
	"UpdateAsync",
	"RemoveAsync",
	"IncrementAsync",
	"GetVersionAsync",
	"GetVersionAtTimeAsync",
	"ListVersionsAsync",
	"RemoveVersionAsync",
	"ListKeysAsync",
}

local Proxy = {}

local function refuse(what: string): never
	error(`bench proxy: {what} isn't allowed here`, 0)
end

function Proxy.new(options: Options): Proxy
	local calls: { Call } = {}
	local aliases = options.aliases or {}

	local function wrapStore(real: any, store: string, scope: string?): any
		local methods: { [string]: (...any) -> ...any } = {}
		for _, method in STORE_METHODS do
			methods[method] = function(_self: any, ...: any): ...any
				local key = select(1, ...)
				local call: Call = {
					method = method,
					store = store,
					scope = scope,
					key = if type(key) == "string" or type(key) == "number"
						then tostring(key)
						else nil,
					started = options.clock(),
				}
				if method == "GetAsync" then
					local getOptions = select(2, ...)
					local read, useCache = pcall(function()
						return getOptions.UseCache
					end)
					call.noCache = getOptions ~= nil and read and useCache == false
				end
				table.insert(calls, call)
				local results = table.pack(pcall(real[method], real, ...))
				call.finished = options.clock()
				call.ok = results[1]
				if not results[1] then
					call.err = tostring(results[2])
					-- rethrown as is, libraries match on the message text
					error(results[2], 0)
				end
				return table.unpack(results, 2, results.n)
			end
		end
		return setmetatable({}, {
			__index = function(_self: any, member: string): any
				local method = methods[member]
				if method == nil then
					refuse(`DataStore member {member}`)
				end
				return method
			end,
			__newindex = function()
				refuse("changing a DataStore")
			end,
		})
	end

	local service = {}

	function service.GetDataStore(_self: any, name: string, scope: string?, ...: any): any
		local alias = aliases[name]
		if name ~= options.allowed and alias == nil then
			refuse(`the DataStore {name}`)
		end
		local realName = options.allowed
		local realScope = scope
		if alias then
			realScope = if scope == nil or scope == "global"
				then alias.scope
				else `{alias.scope}-{scope}`
		end
		-- same arguments the library passed, so a nil scope stays nil
		local real = if select("#", ...) > 0 or realScope ~= nil
			then options.real:GetDataStore(realName, realScope, ...)
			else options.real:GetDataStore(realName)
		return wrapStore(real, realName, realScope)
	end

	function service.GetRequestBudgetForRequestType(_self: any, requestType: any): number
		return options.real:GetRequestBudgetForRequestType(requestType)
	end

	local proxied = setmetatable({}, {
		__index = function(_self: any, member: string): any
			local value = (service :: any)[member]
			if value == nil then
				refuse(`DataStoreService member {member}`)
			end
			return value
		end,
		__newindex = function()
			refuse("changing DataStoreService")
		end,
	})

	return {
		service = proxied,
		calls = calls,
		allowed = options.allowed,
	}
end

-- ProfileStore and ProfileService take DataStoreService when they're first required. The runner
-- points that line at `active`, and the bench sets the proxy before requiring them
local active: Proxy? = nil

function Proxy.setActive(proxy: Proxy?)
	active = proxy
end

function Proxy.active(): any
	if active == nil then
		error("bench proxy: no proxy is active, the bench sets one before requiring a library", 0)
	end
	return (active :: Proxy).service
end

-- Calls that started at or after `since`, optionally only those for one key
function Proxy.since(proxy: Proxy, since: number, key: string?): { Call }
	local found = {}
	for _, call in proxy.calls do
		if call.started >= since and (key == nil or call.key == key) then
			table.insert(found, call)
		end
	end
	return found
end

return Proxy
