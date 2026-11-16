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
	-- Layout of the stored record, see Record.FORMAT. Missing on records written before 0.6.0
	format: number?,
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

export type ExternalWriteOptions = {
	-- Unix time in seconds, written to meta.updatedAt
	now: number,
	-- Fresh for every write, such as HttpService:GenerateGUID(false)
	id: string,
}

local Record = {}

-- The record layout this Geode writes into `meta.format`. Records without it were written by
-- 0.4.0 to 0.5.0, whose layout is the same apart from the missing field. Bump it only when the
-- stored shape changes in a way a tool reading records has to know about
Record.FORMAT = 1

-- Starts the session an external write leaves in meta.lastSession. Geode's own sessions are
-- GUIDs, so a running server never mistakes one for its own
Record.EXTERNAL_SESSION_PREFIX = "external:"

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

function Record.new(data: unknown, now: number, schemaVersion: number): Record
	return {
		data = copy(data),
		meta = {
			format = Record.FORMAT,
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
		and (fields.format == nil or type(fields.format) == "number")
		and (fields.lease == nil or type(fields.lease) == "table")
end

function Record.copy(record: Record): Record
	return copy(record) :: Record
end

-- Did `owner` make the last write? If its lease is gone as well, that write was a release
-- of ours that reported failure but landed, and nobody has touched the record since
function Record.lastWrittenBy(record: Record, owner: Owner): boolean
	local last = record.meta.lastSession
	return last ~= nil and last.session == owner.session and last.revision == record.meta.revision
end

-- What a tool editing a stored record outside a running Geode writes back: `data` in place of
-- the old data, the revision one higher, a session in lastSession that no server owns, and a new
-- updatedAt. Everything else in meta stays as it was, the lease and the format included. Works
-- on profile and shared records alike and never changes `stored`
--
-- The tool writes the result back in one UpdateAsync and returns the key's user IDs and metadata
-- with it. A transform that returns no metadata wipes it (seen live, see Quartz/Real/DataStore).
-- TODO(verify): whether leaving out the user IDs clears them too. The docs say to pass both back
function Record.externalWrite(stored: unknown, data: unknown, options: ExternalWriteOptions): Record
	assert(Record.isRecord(stored), "externalWrite needs a stored Geode record")
	assert(type(options) == "table", "externalWrite needs options with now and id")
	assert(type(options.now) == "number", "externalWrite needs now, in Unix seconds")
	assert(type(options.id) == "string" and options.id ~= "", "externalWrite needs a fresh id")
	local record = copy(stored) :: Record
	local revision = record.meta.revision + 1
	record.data = copy(data)
	record.meta.revision = revision
	record.meta.lastSession = {
		session = Record.EXTERNAL_SESSION_PREFIX .. options.id,
		revision = revision,
	}
	record.meta.updatedAt = options.now
	return record
end

-- Was the last write to `record` an external one?
function Record.writtenExternally(record: Record): boolean
	local last = record.meta.lastSession
	local prefix = Record.EXTERNAL_SESSION_PREFIX
	return last ~= nil
		and type(last.session) == "string"
		and string.sub(last.session, 1, #prefix) == prefix
		and last.revision == record.meta.revision
end

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
