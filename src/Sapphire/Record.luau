--!strict

-- How a profile looks in its DS key: the player's data next to the metadata that keeps it
-- safe. The session lease lives here too, so taking or checking it happens in the same
-- UpdateAsync that reads and writes the data

export type Lease = {
	jobId: string,
	placeId: number,
	-- Tells two sessions on the same server apart
	session: string,
	acquiredAt: number,
	renewedAt: number,
}

export type Meta = {
	schemaVersion: number,
	revision: number,
	lease: Lease?,
	-- Purchase ids already granted, newest last
	receipts: { string },
	mailboxCursor: number,
	createdAt: number,
	updatedAt: number,
	-- Set when the player's data was erased. The record then holds no data
	erasedAt: number?,
	-- The session behind the last write and the revision it left. A write that failed may still
	-- have landed, and this is how a retry recognizes its own earlier write
	lastSession: LastSession?,
}

export type LastSession = {
	session: string,
	revision: number,
}

export type Record = {
	data: unknown,
	meta: Meta,
}

export type Owner = {
	jobId: string,
	-- unique per load, so loading the same key twice on one server gives two sessions
	session: string,
}

export type LeaseState = "free" | "mine" | "stale" | "held"

local Record = {}

local function copy(value: unknown): unknown
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value :: { [unknown]: unknown } do
		result[key] = copy(child)
	end
	return result
end

--[=[
	A fresh record around `data`
]=]
function Record.new(data: unknown, now: number, schemaVersion: number): Record
	return {
		data = copy(data),
		meta = {
			schemaVersion = schemaVersion,
			revision = 0,
			lease = nil,
			receipts = {},
			mailboxCursor = 0,
			createdAt = now,
			updatedAt = now,
		},
	}
end

--[=[
	Whether a stored value has the record shape. Anything else in a profile key is treated as
	corrupt and never overwritten
]=]
function Record.isRecord(value: unknown): boolean
	if type(value) ~= "table" then
		return false
	end
	local meta = (value :: { meta: unknown }).meta
	if type(meta) ~= "table" then
		return false
	end
	local fields = meta :: { [string]: unknown }
	return type(fields.revision) == "number"
		and type(fields.schemaVersion) == "number"
		and (fields.lease == nil or type(fields.lease) == "table")
end

--[=[
	A deep copy, so a transform can edit it without touching what the DataStore handed over
]=]
function Record.copy(record: Record): Record
	return copy(record) :: Record
end

--[=[
	Whether `owner` made the last write to `record`. When its lease is gone too, that write was a
	release of ours that reported failure but landed, and nobody has touched the record since
]=]
function Record.lastWrittenBy(record: Record, owner: Owner): boolean
	local last = record.meta.lastSession
	return last ~= nil and last.session == owner.session and last.revision == record.meta.revision
end

--[=[
	Who holds the lease, from the point of view of `owner` at time `now`
]=]
function Record.leaseState(record: Record, now: number, timeout: number, owner: Owner): LeaseState
	local lease = record.meta.lease
	if lease == nil then
		return "free"
	end
	if lease.jobId == owner.jobId and lease.session == owner.session then
		return "mine"
	end
	if now - lease.renewedAt > timeout then
		return "stale"
	end
	return "held"
end

return Record
