--!strict

-- Fast server hops. A server that wants a profile held elsewhere asks the holder over
-- MessagingService to release it, and the holder announces when it has. A short lived MS key
-- repeats that announcement in case messages are slow or lost. Neither is trusted for
-- correctness, they only say "try now". The lease check inside UpdateAsync still decides

local Types = require("../Quartz/Types")

export type Message = {
	kind: string,
	key: string,
	from: string,
	[string]: unknown,
}

type Sleeper = {
	thread: thread,
	done: boolean,
	woken: boolean,
}

type Fields = {
	enabled: boolean,
	_services: Types.Services,
	_topic: string,
	_mapKeyPrefix: string,
	_report: (message: string) -> (),
	_subscribed: boolean,
	_connection: Types.Connection?,
	_sleepers: { [string]: { Sleeper } },
	_onRequest: ((key: string, from: string) -> ())?,
	_handlers: { [string]: (message: Message) -> () },
}

local Handoff = {}
Handoff.__index = Handoff

export type Handoff = typeof(setmetatable({} :: Fields, Handoff))

-- How long the handoff key outlives a release
local KEY_TTL = 30
-- how often a waiting load polls the handoff key when no message shows up
local POLL_INTERVAL = 2
local MAP_NAME = "geode_handoff"

function Handoff.new(
	services: Types.Services,
	storeName: string,
	enabled: boolean,
	report: (message: string) -> ()
): Handoff
	return setmetatable(
		{
			enabled = enabled,
			_services = services,
			_topic = `geode_release_{storeName}`,
			_mapKeyPrefix = `{storeName}/`,
			_report = report,
			_subscribed = false,
			_connection = nil,
			_sleepers = {},
			_onRequest = nil,
			_handlers = {},
		} :: Fields,
		Handoff
	)
end

--[=[
	Sets what runs when another server asks for a key this server may hold
]=]
function Handoff.onRequest(self: Handoff, handler: (key: string, from: string) -> ())
	self._onRequest = handler
end

-- subscribe lazily, a store that never loads costs nothing
function Handoff.start(self: Handoff)
	if not self.enabled or self._subscribed then
		return
	end
	self._subscribed = true
	local result = self._services.messaging:subscribe(self._topic, function(data: unknown)
		self:_receive(data)
	end)
	if result.ok then
		self._connection = result.value
	else
		self._report(
			`couldn't listen for release messages, hops fall back to retries: {result.error.message}`
		)
	end
end

function Handoff._receive(self: Handoff, data: unknown)
	if type(data) ~= "table" then
		return
	end
	local message = data :: Message
	if type(message.key) ~= "string" or message.from == self._services.jobId then
		return
	end
	if message.kind == "request" then
		local handler = self._onRequest
		if handler then
			handler(message.key, message.from)
		end
	elseif message.kind == "released" then
		self:_wake(message.key)
	else
		local handler = self._handlers[message.kind]
		if handler then
			handler(message)
		end
	end
end

--[=[
	Handles other message kinds on the same topic, e.g. rollbacks sent to the holder
]=]
function Handoff.on(self: Handoff, kind: string, handler: (message: Message) -> ())
	self._handlers[kind] = handler
end

--[=[
	Sends a message of `kind` to every server listening on this store. False when handoff is off
	or the publish failed
]=]
function Handoff.send(self: Handoff, kind: string, key: string, fields: { [string]: any }): boolean
	if not self.enabled then
		return false
	end
	local message = table.clone(fields)
	message.kind = kind
	message.key = key
	message.from = self._services.jobId
	return self._services.messaging:publish(self._topic, message).ok
end

--[=[
	Asks whoever holds `key` to release it
]=]
function Handoff.request(self: Handoff, key: string)
	if not self.enabled then
		return
	end
	self._services.messaging:publish(
		self._topic,
		{ kind = "request", key = key, from = self._services.jobId }
	)
end

--[=[
	Tells waiting servers that this server released `key`. Best effort, since a failure only
	costs speed
]=]
function Handoff.announce(self: Handoff, key: string, revision: number)
	if not self.enabled then
		return
	end
	local services = self._services
	services.messaging:publish(self._topic, { kind = "released", key = key, from = services.jobId })
	services
		.hashMap(MAP_NAME)
		:set(self._mapKeyPrefix .. key, { jobId = services.jobId, revision = revision }, KEY_TTL)
end

function Handoff._wake(self: Handoff, key: string)
	local sleepers = self._sleepers[key]
	if sleepers == nil then
		return
	end
	self._sleepers[key] = nil
	for _, sleeper in sleepers do
		if not sleeper.done then
			sleeper.done = true
			sleeper.woken = true
			self._services.clock:resume(sleeper.thread)
		end
	end
end

-- Sleeps until `seconds` pass or someone announces a release of `key`. True if the
-- announcement is what woke it
function Handoff._park(self: Handoff, key: string, seconds: number): boolean
	local clock = self._services.clock
	local sleeper: Sleeper = { thread = coroutine.running(), done = false, woken = false }
	local sleepers = self._sleepers[key] or {}
	self._sleepers[key] = sleepers
	table.insert(sleepers, sleeper)
	clock:delay(seconds, function()
		if sleeper.done then
			return
		end
		sleeper.done = true
		local list = self._sleepers[key]
		local index = if list then table.find(list, sleeper) else nil
		if list and index then
			table.remove(list, index)
			if #list == 0 then
				self._sleepers[key] = nil
			end
		end
		clock:resume(sleeper.thread)
	end)
	coroutine.yield()
	return sleeper.woken
end

function Handoff._releasedBy(self: Handoff, key: string, holder: string): boolean
	local result = self._services.hashMap(MAP_NAME):get(self._mapKeyPrefix .. key)
	if not result.ok or type(result.value) ~= "table" then
		return false
	end
	return (result.value :: { jobId: unknown }).jobId == holder
end

--[=[
	Waits up to `seconds` before the next acquire attempt on `key`. Returns early when the holder
	announces its release, or when `checkKey` is set and the handoff key shows it did
]=]
function Handoff.wait(
	self: Handoff,
	key: string,
	seconds: number,
	holder: string,
	checkKey: boolean
): boolean
	local clock = self._services.clock
	if not self.enabled then
		clock:wait(seconds)
		return false
	end
	local deadline = clock:now() + seconds
	while true do
		local remaining = deadline - clock:now()
		if remaining <= 0 then
			return false
		end
		local slice = if checkKey then math.min(POLL_INTERVAL, remaining) else remaining
		if self:_park(key, slice) then
			return true
		end
		if checkKey and self:_releasedBy(key, holder) then
			return true
		end
	end
end

function Handoff.stop(self: Handoff)
	if self._connection then
		self._connection:disconnect()
		self._connection = nil
	end
end

return Handoff
