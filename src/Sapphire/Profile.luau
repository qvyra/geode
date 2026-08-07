--!strict

-- One player's data while this server holds its session lease. Reads and writes go through
-- the document, so every change runs the full pipeline. Saves check the lease inside the
-- same UpdateAsync that writes, so a server that lost the session can never overwrite the
-- data of the server that took it

local Document = require("../Matrix/Document")
local Record = require("./Record")
local Scheduler = require("../Quartz/Scheduler")
local Signal = require("../Quartz/Signal")
local Size = require("../Obsidian/Size")
local Transaction = require("../Matrix/Transaction")
local Types = require("../Quartz/Types")
local Validate = require("../Obsidian/Validate")
local Schema = require("../Obsidian/Schema")

type PathLike = string | { string | number }

-- `any` because the Profile type is defined further down
export type SessionLostPolicy = "kick" | "none" | (profile: any, reason: string) -> ()

-- Everything a profile needs from its store. Plain data, so Profile doesn't have to
-- require the store module
export type Backend = {
	key: string,
	schedulerKey: string,
	dataStore: Types.DataStore,
	scheduler: Scheduler.Scheduler,
	clock: Types.Clock,
	json: Types.Json,
	players: Types.Players,
	owner: Record.Owner,
	userIds: { number },
	userId: number?,
	schema: Schema.Schema?,
	schemaVersion: number,
	receipts: { string },
	receiptHistory: number,
	mailboxCursor: number,
	sizeBudget: Size.Budget,
	autosaveInterval: number,
	onSessionLost: SessionLostPolicy,
	report: (message: string) -> (),
	onClosed: (profile: any) -> (),
}

export type SaveErrorKind = "adapter" | "lost" | "tooLarge" | "closed"

export type SaveResult =
	{ ok: true }
	| { ok: false, error: { kind: SaveErrorKind, message: string } }

export type State = "active" | "releasing" | "released" | "lost"

type Fields = {
	key: string,
	userId: number?,
	-- Fires once, with the reason, when another server took the session
	sessionLost: Signal.Signal,
	released: Signal.Signal,
	_document: Document.Document,
	_backend: Backend,
	_state: State,
	_savedRevision: number,
	_receipts: { string },
	_mailboxCursor: number,
	-- bumped on receipt or mailbox cursor changes so isSaved sees unsaved metadata
	_metaVersion: number,
	_savedMetaVersion: number,
	_autosaveToken: number,
	_releasing: { thread }?,
}

local Profile = {}
Profile.__index = Profile

export type Profile = typeof(setmetatable({} :: Fields, Profile))

local function failure(kind: SaveErrorKind, message: string): SaveResult
	return { ok = false, error = { kind = kind, message = message } }
end

function Profile.new(document: Document.Document, backend: Backend): Profile
	local self: Fields = {
		key = backend.key,
		userId = backend.userId,
		sessionLost = Signal.new(backend.report),
		released = Signal.new(backend.report),
		_document = document,
		_backend = backend,
		_state = "active",
		_savedRevision = document:revision(),
		_receipts = table.clone(backend.receipts),
		_mailboxCursor = backend.mailboxCursor,
		_metaVersion = 0,
		_savedMetaVersion = 0,
		_autosaveToken = 0,
		_releasing = nil,
	}
	local profile = setmetatable(self, Profile)
	profile:_scheduleAutosave()
	return profile
end

-- Reading and writing

function Profile.get(self: Profile, path: PathLike?): unknown
	return self._document:get(path)
end

function Profile.snapshot(self: Profile): unknown
	return self._document:snapshot()
end

function Profile.revision(self: Profile): number
	return self._document:revision()
end

function Profile.state(self: Profile): State
	return self._state
end

function Profile.isActive(self: Profile): boolean
	return self._state == "active"
end

function Profile.transact(
	self: Profile,
	body: (tx: Transaction.Transaction) -> (),
	options: Document.TransactOptions?
): Document.TxResult
	return self._document:transact(body, options)
end

function Profile.set(self: Profile, path: PathLike, value: unknown): Document.TxResult
	return self._document:set(path, value)
end

function Profile.update(
	self: Profile,
	path: PathLike,
	transform: (current: unknown) -> unknown
): Document.TxResult
	return self._document:update(path, transform)
end

function Profile.increment(self: Profile, path: PathLike, amount: number?): Document.TxResult
	return self._document:increment(path, amount)
end

function Profile.decrement(self: Profile, path: PathLike, amount: number?): Document.TxResult
	return self._document:decrement(path, amount)
end

function Profile.append(self: Profile, path: PathLike, value: unknown): Document.TxResult
	return self._document:append(path, value)
end

function Profile.insert(
	self: Profile,
	path: PathLike,
	index: number,
	value: unknown
): Document.TxResult
	return self._document:insert(path, index, value)
end

function Profile.remove(self: Profile, path: PathLike): Document.TxResult
	return self._document:remove(path)
end

function Profile.clear(self: Profile, path: PathLike?): Document.TxResult
	return self._document:clear(path)
end

function Profile.merge(
	self: Profile,
	path: PathLike?,
	partial: { [string]: unknown }
): Document.TxResult
	return self._document:merge(path, partial)
end

function Profile.op(self: Profile, name: string, ...: any): Document.TxResult
	return self._document:op(name, ...)
end

function Profile.observe(
	self: Profile,
	path: PathLike,
	callback: Document.Observer
): Types.Connection
	return self._document:observe(path, callback)
end

function Profile.onCommit(
	self: Profile,
	callback: (record: Document.CommitRecord) -> ()
): Types.Connection
	return self._document:onCommit(callback)
end

--// saving

function Profile._encode(self: Profile, snapshot: unknown): unknown
	local schema = self._backend.schema
	if schema then
		return Validate.encode(schema, snapshot)
	end
	return snapshot
end

-- One UpdateAsync that writes the current state and also checks and renews the lease.
-- A release clears the lease in that same write
function Profile._write(self: Profile, releasing: boolean): SaveResult
	local backend = self._backend
	local document = self._document

	-- reset on every transform run, UpdateAsync may call the transform more than once
	local lostReason: string? = nil
	local savedRevision: number? = nil
	local savedMetaVersion: number? = nil
	local oversize: number? = nil

	local result = backend.scheduler:submit({
		priority = if releasing then "release" else "save",
		budget = "update",
		key = backend.schedulerKey,
		write = true,
		run = function()
			return backend.dataStore:update(backend.key, function(current: unknown)
				lostReason, savedRevision, savedMetaVersion, oversize = nil, nil, nil, nil
				if not Record.isRecord(current) then
					lostReason = "the stored record is missing or corrupt"
					return nil
				end
				local record = Record.copy(current :: Record.Record)
				local now = backend.clock:now()
				if Record.leaseState(record, now, math.huge, backend.owner) ~= "mine" then
					lostReason = "another server took the session"
					return nil
				end

				local revision = document:revision()
				local candidate = Record.copy(record)
				candidate.data = self:_encode(document:snapshot())
				candidate.meta.revision = revision
				candidate.meta.schemaVersion = backend.schemaVersion
				candidate.meta.receipts = table.clone(self._receipts)
				candidate.meta.mailboxCursor = self._mailboxCursor
				local metaVersion = self._metaVersion
				local report = Size.check(backend.json, candidate, backend.sizeBudget)
				if report.level == "hard" then
					-- keep what's stored and only renew the lease. Never trim to fit
					oversize = report.size
				else
					record = candidate
					savedRevision = revision
					savedMetaVersion = metaVersion
					if report.level == "soft" then
						backend.report(
							`profile {backend.key} is {report.size} bytes, close to the size limit`
						)
					end
				end

				record.meta.updatedAt = now
				local lease = record.meta.lease :: Record.Lease
				lease.renewedAt = now
				if releasing and oversize == nil then
					record.meta.lease = nil
				end
				return record, { userIds = backend.userIds }
			end)
		end,
	})

	if not result.ok then
		return failure("adapter", result.error.message)
	end
	if lostReason then
		self:_lose(lostReason)
		return failure("lost", lostReason)
	end
	if savedRevision then
		self._savedRevision = math.max(self._savedRevision, savedRevision)
	end
	if savedMetaVersion then
		self._savedMetaVersion = math.max(self._savedMetaVersion, savedMetaVersion)
	end
	if oversize then
		local message =
			`profile {backend.key} is {oversize} bytes, over the hard limit. Changes stay in memory and weren't saved`
		backend.report(message)
		return failure("tooLarge", message)
	end
	return { ok = true }
end

--[=[
	Saves now and renews the lease. Yields. Autosave calls this on its own timer
]=]
function Profile.save(self: Profile): SaveResult
	if self._state ~= "active" then
		return failure("closed", `profile {self.key} is {self._state}`)
	end
	return self:_write(false)
end

--[=[
	Whether every committed change, receipt and applied mailbox message has been saved
]=]
function Profile.isSaved(self: Profile): boolean
	return self._savedRevision >= self._document:revision()
		and self._savedMetaVersion >= self._metaVersion
end

-- Receipts and mailbox

--[=[
	Whether a purchase was already granted to this profile
]=]
function Profile.hasReceipt(self: Profile, purchaseId: string): boolean
	return table.find(self._receipts, purchaseId) ~= nil
end

--[=[
	Remembers a granted purchase. It's saved with the data, so a grant and its receipt reach
	the DataStore in the same write or not at all. Only the most recent ones are kept
]=]
function Profile.recordReceipt(self: Profile, purchaseId: string)
	if self:hasReceipt(purchaseId) then
		return
	end
	table.insert(self._receipts, purchaseId)
	local excess = #self._receipts - self._backend.receiptHistory
	if excess > 0 then
		table.move(self._receipts, excess + 1, #self._receipts, 1)
		for _ = 1, excess do
			table.remove(self._receipts)
		end
	end
	self._metaVersion += 1
end

function Profile.mailboxCursor(self: Profile): number
	return self._mailboxCursor
end

function Profile._advanceMailbox(self: Profile, seq: number)
	if seq > self._mailboxCursor then
		self._mailboxCursor = seq
		self._metaVersion += 1
	end
end

--[=[
	Saves a last time and gives up the lease. The profile is read only from the moment the release
	starts, so nothing written after the final snapshot can be silently dropped. If the write
	fails, the profile goes back to active and keeps its data
]=]
function Profile.release(self: Profile): SaveResult
	if self._state == "released" then
		return { ok = true }
	end
	if self._state == "lost" then
		return failure("lost", "the session was already lost")
	end
	if self._state == "releasing" then
		local waiting = self._releasing :: { thread }
		table.insert(waiting, coroutine.running())
		coroutine.yield()
		return if self:state() == "released"
			then { ok = true }
			else failure("adapter", "release didn't finish")
	end

	self._state = "releasing"
	self._releasing = {}
	self._document:setReadOnly(`profile {self.key} is being released`)
	local result = self:_write(true)

	if result.ok then
		self._state = "released"
		self._document:setReadOnly(`profile {self.key} was released`)
		self._autosaveToken += 1
		self._backend.onClosed(self)
		self.released:fire()
	-- state() rather than the field: a lost session can change it while the write yields
	elseif self:state() == "releasing" then
		self._state = "active"
		self._document:clearReadOnly()
		self._backend.report(
			`releasing profile {self.key} failed and will be retried: {result.error.message}`
		)
	end

	local waiting = self._releasing :: { thread }
	self._releasing = nil
	for _, thread in waiting do
		self._backend.clock:resume(thread)
	end
	return result
end

function Profile._scheduleAutosave(self: Profile)
	self._autosaveToken += 1
	local token = self._autosaveToken
	self._backend.clock:delay(self._backend.autosaveInterval, function()
		if token ~= self._autosaveToken or self._state ~= "active" then
			return
		end
		local result = self:save()
		if not result.ok and result.error.kind == "adapter" then
			self._backend.report(
				`autosave of profile {self.key} failed and will be retried: {result.error.message}`
			)
		end
		if self._state == "active" then
			self:_scheduleAutosave()
		end
	end)
end

-- The lease belongs to someone else now. Writes stop at once, the store forgets the profile and
-- the session lost policy runs
function Profile._lose(self: Profile, reason: string)
	if self._state == "lost" or self._state == "released" then
		return
	end
	self._state = "lost"
	self._autosaveToken += 1
	self._document:setReadOnly(`session lost: {reason}`)
	local backend = self._backend
	backend.onClosed(self)
	self.sessionLost:fire(reason)

	local policy = backend.onSessionLost
	if policy == "kick" then
		if backend.userId then
			backend.players:kick(
				backend.userId,
				"Your data was opened on another server. Please rejoin."
			)
		end
	elseif type(policy) == "function" then
		local ok, err = pcall(function()
			policy(self, reason)
		end)
		if not ok then
			backend.report(`onSessionLost handler error: {tostring(err)}`)
		end
	end
end

return Profile
