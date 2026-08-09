--!strict

local Errors = require("../Errors")
local Types = require("../Types")

type Fields = {
	name: string,
	invisibilityTimeout: number,
	_queue: MemoryStoreQueue,
}

local RealQueue = {}
RealQueue.__index = RealQueue

export type RealQueue = typeof(setmetatable({} :: Fields, RealQueue))

function RealQueue.new(
	queue: MemoryStoreQueue,
	name: string,
	invisibilityTimeout: number
): RealQueue
	local self: Fields = {
		name = name,
		invisibilityTimeout = invisibilityTimeout,
		_queue = queue,
	}
	return setmetatable(self, RealQueue)
end

function RealQueue.add(
	self: RealQueue,
	value: unknown,
	ttl: number,
	priority: number?
): Types.Result<nil>
	local ok, err = pcall(function()
		self._queue:AddAsync(value, ttl, priority or 0)
	end)
	if not ok then
		return Errors.failWith(Errors.classify(err, "memoryStore"))
	end
	return Errors.ok(nil)
end

function RealQueue.read(
	self: RealQueue,
	options: Types.QueueReadOptions
): Types.Result<Types.QueueRead>
	local ok, items, id = pcall(function(): ({ unknown }, string?)
		local readItems, readId = self._queue:ReadAsync(
			options.count,
			options.allOrNothing == true,
			options.waitTimeout or 0
		)
		return readItems :: { unknown }, readId :: string?
	end)
	if not ok then
		return Errors.failWith(Errors.classify(items, "memoryStore"))
	end
	return Errors.ok({ items = items or {}, id = id })
end

function RealQueue.remove(self: RealQueue, id: string): Types.Result<nil>
	local ok, err = pcall(function()
		self._queue:RemoveAsync(id)
	end)
	if not ok then
		return Errors.failWith(Errors.classify(err, "memoryStore"))
	end
	return Errors.ok(nil)
end

return RealQueue
