--!strict

-- Ops queued for a profile while its player is somewhere else. Each profile's messages
-- live in their own DS key and apply in order on the next load. The cursor of the last
-- applied message is saved with the profile data, so each message applies exactly once

local Transaction = require("../Matrix/Transaction")

export type Message = {
	seq: number,
	-- one per send, so a retry whose first try landed isn't queued twice
	id: string?,
	op: string,
	args: { unknown },
	sentAt: number,
}

export type Failed = {
	seq: number,
	op: string,
	args: { unknown },
	sentAt: number,
	reason: string,
}

export type Box = {
	nextSeq: number,
	items: { Message },
	-- kept for tooling, never thrown away
	failed: { Failed },
}

local Mailbox = {}

-- `update` isn't here on purpose: it takes a function, and functions can't be stored
local BUILT_IN: { [string]: boolean } = {
	set = true,
	increment = true,
	decrement = true,
	append = true,
	insert = true,
	remove = true,
	clear = true,
	merge = true,
}

function Mailbox.isBuiltIn(op: string): boolean
	return BUILT_IN[op] == true
end

--[=[
	The box as stored, or an empty one. Anything malformed reads as empty and is never written over
]=]
function Mailbox.read(value: unknown): Box?
	if value == nil then
		return { nextSeq = 1, items = {}, failed = {} }
	end
	if type(value) ~= "table" then
		return nil
	end
	local box = value :: { nextSeq: unknown, items: unknown, failed: unknown }
	if type(box.nextSeq) ~= "number" or type(box.items) ~= "table" then
		return nil
	end
	return {
		nextSeq = box.nextSeq :: number,
		items = box.items :: { Message },
		failed = if type(box.failed) == "table" then box.failed :: { Failed } else {},
	}
end

--[=[
	Appends a message to a box and returns it. The box is changed in place
]=]
function Mailbox.push(box: Box, op: string, args: { unknown }, now: number, id: string?): Box
	table.insert(box.items, { seq = box.nextSeq, id = id, op = op, args = args, sentAt = now })
	box.nextSeq += 1
	return box
end

--[=[
	The sequence number of the message sent with `id`, if the box still holds it
]=]
function Mailbox.find(box: Box, id: string): number?
	for _, message in box.items do
		if message.id == id then
			return message.seq
		end
	end
	return nil
end

--[=[
	Messages after `cursor`, oldest first
]=]
function Mailbox.pending(box: Box, cursor: number): { Message }
	local pending = {}
	for _, message in box.items do
		if message.seq > cursor then
			table.insert(pending, message)
		end
	end
	table.sort(pending, function(a, b)
		return a.seq < b.seq
	end)
	return pending
end

--[=[
	Drops messages at or before `cursor` and archives the failed ones. Only call this with a cursor
	that is already saved, so a crash can never lose a message that wasn't applied for good
]=]
function Mailbox.prune(box: Box, cursor: number, failures: { [number]: string }): Box
	local kept = {}
	local archived: { [number]: boolean } = {}
	for _, entry in box.failed do
		archived[entry.seq] = true
	end
	for _, message in box.items do
		local reason = failures[message.seq]
		if reason and not archived[message.seq] then
			table.insert(box.failed, {
				seq = message.seq,
				op = message.op,
				args = message.args,
				sentAt = message.sentAt,
				reason = reason,
			})
		end
		if message.seq > cursor then
			table.insert(kept, message)
		end
	end
	box.items = kept
	return box
end

--[=[
	Runs one message inside a transaction
]=]
function Mailbox.apply(tx: Transaction.Transaction, message: Message)
	local args = message.args
	local op = message.op
	if op == "set" then
		tx:set(args[1] :: string, args[2])
	elseif op == "increment" then
		tx:increment(args[1] :: string, args[2] :: number?)
	elseif op == "decrement" then
		tx:decrement(args[1] :: string, args[2] :: number?)
	elseif op == "append" then
		tx:append(args[1] :: string, args[2])
	elseif op == "insert" then
		tx:insert(args[1] :: string, args[2] :: number, args[3])
	elseif op == "remove" then
		tx:remove(args[1] :: string)
	elseif op == "clear" then
		tx:clear(args[1] :: string?)
	elseif op == "merge" then
		tx:merge(args[1] :: string?, args[2] :: { [string]: unknown })
	else
		tx:op(op, table.unpack(args))
	end
end

return Mailbox
