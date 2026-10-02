--!strict

local Context = require("./Context")
local Errors = require("../Errors")
local Types = require("../Types")
local Values = require("./Values")

type Context = Context.Context
type QueueItem = Context.QueueItem

type Fields = {
	name: string,
	invisibilityTimeout: number,
	_context: Context,
	_items: { QueueItem },
}

local MockQueue = {}
MockQueue.__index = MockQueue

export type MockQueue = typeof(setmetatable({} :: Fields, MockQueue))

local SERVICE = "queue"

-- poll interval for a waiting read. Virtual time only, costs nothing real
local POLL_INTERVAL = 0.25

local DEFAULT_INVISIBILITY_TIMEOUT = 30

local MAX_READ_COUNT = 100

function MockQueue.new(context: Context, name: string, invisibilityTimeout: number?): MockQueue
	local queues = context.shared.queues
	queues[name] = queues[name] or {}
	local self: Fields = {
		name = name,
		invisibilityTimeout = invisibilityTimeout or DEFAULT_INVISIBILITY_TIMEOUT,
		_context = context,
		_items = queues[name],
	}
	return setmetatable(self, MockQueue)
end

-- drops expired items, returns the visible ones by priority (high first), then oldest first
function MockQueue._visible(self: MockQueue): { QueueItem }
	local now = self._context.shared.clock:now()
	for index = #self._items, 1, -1 do
		if self._items[index].expiresAt <= now then
			table.remove(self._items, index)
		end
	end

	local visible = {}
	for _, item in self._items do
		if item.invisibleUntil <= now then
			table.insert(visible, item)
		end
	end
	table.sort(visible, function(a, b)
		if a.priority ~= b.priority then
			return a.priority > b.priority
		end
		return a.seq < b.seq
	end)
	return visible
end

function MockQueue.add(
	self: MockQueue,
	value: unknown,
	ttl: number,
	priority: number?
): Types.Result<nil>
	local err = Context.enter(self._context, SERVICE, self.name, "add", nil)
	if err then
		return Errors.failWith(err)
	end
	if ttl <= 0 then
		return Errors.fail("invalidValue", "ttl must be positive")
	end
	local ok, copy = Values.copy(value)
	if not ok then
		return Errors.fail("invalidValue", tostring(copy))
	end
	local sizeError = Context.checkSize(self._context.shared, copy)
	if sizeError then
		return Errors.failWith(sizeError)
	end

	local shared = self._context.shared
	shared.sequence += 1
	table.insert(self._items, {
		seq = shared.sequence,
		value = copy,
		priority = priority or 0,
		expiresAt = shared.clock:now() + ttl,
		invisibleUntil = 0,
		readId = nil,
	})
	return Errors.ok(nil)
end

function MockQueue.read(
	self: MockQueue,
	options: Types.QueueReadOptions
): Types.Result<Types.QueueRead>
	local err = Context.enter(self._context, SERVICE, self.name, "read", nil)
	if err then
		return Errors.failWith(err)
	end

	if options.count < 1 or options.count > MAX_READ_COUNT or options.count % 1 ~= 0 then
		return Errors.fail(
			"invalidValue",
			`count must be a whole number from 1 to {MAX_READ_COUNT}`
		)
	end

	local clock = self._context.shared.clock
	local deadline = clock:now() + (options.waitTimeout or 0)
	local needed = if options.allOrNothing then options.count else 1
	local visible = self:_visible()
	while #visible < needed and clock:now() < deadline do
		clock:wait(math.min(POLL_INTERVAL, deadline - clock:now()))
		visible = self:_visible()
	end
	if #visible < needed then
		return Errors.ok({ items = {}, id = nil })
	end

	local id = Context.nextId(self._context.shared)
	local items = {}
	for index = 1, math.min(options.count, #visible) do
		local item = visible[index]
		item.invisibleUntil = clock:now() + self.invisibilityTimeout
		item.readId = id
		table.insert(items, Values.clone(item.value))
	end
	return Errors.ok({ items = items, id = id })
end

function MockQueue.remove(self: MockQueue, id: string): Types.Result<nil>
	local err = Context.enter(self._context, SERVICE, self.name, "remove", nil)
	if err then
		return Errors.failWith(err)
	end
	-- After the invisibility timeout the read no longer owns its items and removing does
	-- nothing, also once the same items were read again under a new id
	local now = self._context.shared.clock:now()
	for index = #self._items, 1, -1 do
		local item = self._items[index]
		if item.readId == id and item.invisibleUntil > now then
			table.remove(self._items, index)
		end
	end
	return Errors.ok(nil)
end

return MockQueue
