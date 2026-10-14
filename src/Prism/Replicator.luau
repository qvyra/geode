--!strict

-- Sends player data to clients. A tracked profile marks paths "private" (never sent, the
-- default), "owner" (sent to its own player) or "public" (sent to everyone). After each
-- commit only visible paths that changed get queued, and the queue goes out once per frame.
-- A client that connects or asks to resync gets a full snapshot first

local Path = require("../Matrix/Path")
local Profile = require("../Sapphire/Profile")
local Registry = require("../Vein/Registry")
local VeinBridge = require("../Vein/Bridge")
local Tree = require("../Matrix/Tree")
local Types = require("../Quartz/Types")

export type Visibility = "private" | "owner" | "public"

export type Change =
	{ op: "set", owner: number, path: string, value: unknown }
	| { op: "drop", owner: number }
	| { op: "reset" }

export type Request = { kind: "ready" } | { kind: "resync" }

type Owned = {
	source: Profile.Profile,
	paths: { { path: string, visibility: Visibility } },
	last: { [string]: unknown },
	connection: Types.Connection,
}

type Fields = {
	_services: Types.Services,
	_remote: Types.ServerRemote,
	_owners: { [number]: Owned },
	_viewers: { [number]: boolean },
	_queues: { [number]: { Change } },
	_lastSnapshot: { [number]: number },
	_flushing: boolean,
	_report: (message: string) -> (),
	_connections: { Types.Connection },
	_handle: Registry.Handle,
}

--[=[
	@class Replicator

	Sends player data to clients by visibility. `Geode.replicator` returns the one for a game
]=]
local Replicator = {}
Replicator.__index = Replicator

export type Replicator = typeof(setmetatable({} :: Fields, Replicator))

Replicator.REMOTE = "GeodeReplication"

local VISIBILITY: { [string]: boolean } = { private = true, owner = true, public = true }
local STRICTNESS: { [string]: number } = { public = 0, owner = 1, private = 2 }

-- min seconds between two snapshots for one client
local RESYNC_COOLDOWN = 1

--[=[
	Checks a visibility map and returns it as a list, skipping private paths
]=]
function Replicator.parseVisibility(
	map: { [string]: string }
): { { path: string, visibility: Visibility } }
	local paths = {}
	local parsed: { [string]: Path.Path } = {}
	for path, visibility in map do
		assert(type(path) == "string", "visibility is keyed by path")
		assert(
			VISIBILITY[visibility],
			`{path} must be "private", "owner" or "public", got {tostring(visibility)}`
		)
		parsed[path] = Path.parse(path)
	end
	-- a shared path sends everything under it, so nothing below may be stricter
	for outer, outerPath in parsed do
		for inner, innerPath in parsed do
			if
				inner ~= outer
				and Path.startsWith(innerPath, outerPath)
				and STRICTNESS[map[inner]] > STRICTNESS[map[outer]]
			then
				error(
					`{inner} is {map[inner]} but sits under {outer}, which is {map[outer]} and would send it anyway`,
					2
				)
			end
		end
	end
	for path, visibility in map do
		if visibility ~= "private" then
			table.insert(
				paths,
				{ path = Path.format(Path.parse(path)), visibility = visibility :: Visibility }
			)
		end
	end
	table.sort(paths, function(a, b)
		return a.path < b.path
	end)
	return paths
end

--[=[
	Creates a replicator on `services`. There's normally one per game, see Geode.replicator

	@within Replicator
]=]
function Replicator.new(
	services: Types.Services,
	reportError: ((message: string) -> ())?
): Replicator
	VeinBridge.ensure(services)
	local self = setmetatable(
		{
			_services = services,
			_remote = services.remote(Replicator.REMOTE),
			_owners = {},
			_viewers = {},
			_queues = {},
			_lastSnapshot = {},
			_flushing = false,
			_report = reportError or function(message: string)
				warn(message)
			end,
			_connections = {},
			_handle = nil :: any,
		} :: Fields,
		Replicator
	)
	self._handle = Registry.register("replicator", "players", function()
		local owners, viewers = 0, 0
		for _ in self._owners do
			owners += 1
		end
		for _ in self._viewers do
			viewers += 1
		end
		return { owners = owners, viewers = viewers }
	end)

	table.insert(
		self._connections,
		self._remote:onEvent(function(userId: number, request: unknown)
			if type(request) ~= "table" then
				return
			end
			local kind = (request :: { kind: unknown }).kind
			if kind == "ready" or kind == "resync" then
				-- each snapshot sends everything this player may see, so cap how often a
				-- client can ask
				local now = services.clock:now()
				local last = self._lastSnapshot[userId]
				if last and now - last < RESYNC_COOLDOWN then
					return
				end
				self._lastSnapshot[userId] = now
				self:_snapshot(userId)
			end
		end)
	)
	table.insert(
		self._connections,
		services.players:onLeave(function(userId: number)
			self._viewers[userId] = nil
			self._queues[userId] = nil
			self._lastSnapshot[userId] = nil
		end)
	)
	return self
end

--// queueing

function Replicator._push(self: Replicator, viewer: number, change: Change)
	if not self._viewers[viewer] then
		return
	end
	local queue = self._queues[viewer]
	if queue == nil then
		queue = {}
		self._queues[viewer] = queue
	end
	table.insert(queue, change)
	if not self._flushing then
		self._flushing = true
		self._services.clock:delay(0, function()
			self:_flush()
		end)
	end
end

function Replicator._flush(self: Replicator)
	self._flushing = false
	local queues = self._queues
	self._queues = {}
	for viewer, changes in queues do
		if self._viewers[viewer] and #changes > 0 then
			self._remote:fire(viewer, changes)
		end
	end
end

local function canSee(viewer: number, owner: number, visibility: Visibility): boolean
	return visibility == "public" or viewer == owner
end

function Replicator._snapshot(self: Replicator, viewer: number)
	self._viewers[viewer] = true
	self._queues[viewer] = {}
	self:_push(viewer, { op = "reset" })
	for owner, owned in self._owners do
		for _, entry in owned.paths do
			if canSee(viewer, owner, entry.visibility) then
				self:_push(
					viewer,
					{ op = "set", owner = owner, path = entry.path, value = owned.last[entry.path] }
				)
			end
		end
	end
end

--// tracking

--[=[
	Starts replicating a player's profile with the given visibility map. Paths not listed stay
	private
]=]
function Replicator.track(
	self: Replicator,
	owner: number,
	source: Profile.Profile,
	visibility: { [string]: string }
)
	self:untrack(owner)
	local paths = Replicator.parseVisibility(visibility)
	local last: { [string]: unknown } = {}
	for _, entry in paths do
		last[entry.path] = source:get(entry.path)
	end
	local owned: Owned = {
		source = source,
		paths = paths,
		last = last,
		connection = nil :: any,
	}
	owned.connection = source:onCommit(function()
		self:_changed(owner, owned)
	end)
	self._owners[owner] = owned

	for viewer in self._viewers do
		for _, entry in paths do
			if canSee(viewer, owner, entry.visibility) then
				self:_push(
					viewer,
					{ op = "set", owner = owner, path = entry.path, value = last[entry.path] }
				)
			end
		end
	end
end

function Replicator._changed(self: Replicator, owner: number, owned: Owned)
	if self._owners[owner] ~= owned then
		return
	end
	for _, entry in owned.paths do
		local value = owned.source:get(entry.path)
		if not Tree.equal(value, owned.last[entry.path]) then
			owned.last[entry.path] = value
			for viewer in self._viewers do
				if canSee(viewer, owner, entry.visibility) then
					self:_push(
						viewer,
						{ op = "set", owner = owner, path = entry.path, value = value }
					)
				end
			end
		end
	end
end

--[=[
	Stops replicating a player's profile and tells clients to forget it
]=]
function Replicator.untrack(self: Replicator, owner: number)
	local owned = self._owners[owner]
	if owned == nil then
		return
	end
	owned.connection:disconnect()
	self._owners[owner] = nil
	for viewer in self._viewers do
		self:_push(viewer, { op = "drop", owner = owner })
	end
end

--[=[
	Stops the replicator and takes it out of the registry that tooling reads

	@within Replicator
]=]
function Replicator.destroy(self: Replicator)
	for owner in self._owners do
		self:untrack(owner)
	end
	for _, connection in self._connections do
		connection:disconnect()
	end
	self._handle:unregister()
end

return Replicator
