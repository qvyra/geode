--!strict

-- Client side of replication. Holds the data the server shares with this player, read only,
-- and exposes it as atoms you can read, subscribe to and combine. Writes go through declared
-- remote ops, never straight to state

local Document = require("./Matrix/Document")
local Path = require("./Matrix/Path")
local RealServices = require("./Quartz/Real/Services")
local Tree = require("./Matrix/Tree")
local Types = require("./Quartz/Types")

type PathLike = Path.PathLike

export type Atom<T> = {
	get: (self: Atom<T>) -> T,
	subscribe: (self: Atom<T>, callback: (new: T, old: T) -> ()) -> Types.Connection,
}

-- All `charm` needs from Charm: a function that makes an atom, and atoms that read when
-- called with nothing and write when called with a value
export type CharmLike = {
	atom: (initial: any) -> any,
}

type Fields = {
	userId: number,
	_services: Types.ClientServices,
	_replication: Types.ClientRemote,
	_ops: Types.ClientRemote?,
	_owners: { [number]: Document.Document },
	_ready: boolean,
	_readyWaiters: { thread },
}

local GeodeClient = {}
GeodeClient.__index = GeodeClient

export type GeodeClient = typeof(setmetatable({} :: Fields, GeodeClient))

local REPLICATION_REMOTE = "GeodeReplication"
local OPS_REMOTE = "GeodeOps"

-- atoms read inside a `computed` body land here, innermost computation last
local tracking: { { [any]: boolean } } = {}

--[=[
	Connects to the server and asks for a snapshot. Yields until the remotes exist. Tests pass
	client services, live code leaves them out

	@within GeodeClient
]=]
function GeodeClient.start(services: Types.ClientServices?): GeodeClient
	local resolved = services or RealServices.client()
	local self = setmetatable(
		{
			userId = resolved.userId,
			_services = resolved,
			_replication = resolved.remote(REPLICATION_REMOTE),
			_ops = nil,
			_owners = {},
			_ready = false,
			_readyWaiters = {},
		} :: Fields,
		GeodeClient
	)
	self._replication:onEvent(function(changes: unknown)
		self:_apply(changes)
	end)
	self._replication:fire({ kind = "ready" })
	return self
end

function GeodeClient._owner(self: GeodeClient, owner: number): Document.Document
	-- unknown first: Luau won't compare the Document class type with nil
	local existing: unknown = self._owners[owner]
	if existing == nil then
		self._owners[owner] = Document.new({ data = {} })
	end
	return self._owners[owner]
end

function GeodeClient._apply(self: GeodeClient, changes: unknown)
	if type(changes) ~= "table" then
		return
	end
	-- Staged per player, committed once at the end. Otherwise a resync sending the same values
	-- makes subscribers see them vanish and come back
	local staged: { [number]: unknown } = {}
	local function stage(owner: number): unknown
		if staged[owner] == nil then
			local existing: unknown = self._owners[owner]
			staged[owner] = if existing ~= nil then self._owners[owner]:snapshot() else {}
		end
		return staged[owner]
	end
	for _, change in changes :: { any } do
		if change.op == "reset" then
			for owner in self._owners do
				staged[owner] = {}
			end
			for owner in staged do
				staged[owner] = {}
			end
		elseif change.op == "drop" then
			staged[change.owner] = {}
		elseif change.op == "set" then
			staged[change.owner] =
				Tree.set(stage(change.owner), Path.parse(change.path), change.value)
		end
	end
	for owner, state in staged do
		self:_owner(owner):transact(function(tx)
			tx:set({}, state)
		end)
	end
	if not self._ready then
		self._ready = true
		local waiting = self._readyWaiters
		self._readyWaiters = {}
		for _, thread in waiting do
			self._services.clock:resume(thread)
		end
	end
end

--[=[
	Whether the first snapshot has arrived
]=]
function GeodeClient.isReady(self: GeodeClient): boolean
	return self._ready
end

--[=[
	Yields until the first snapshot arrives
]=]
function GeodeClient.waitUntilReady(self: GeodeClient)
	if self._ready then
		return
	end
	table.insert(self._readyWaiters, coroutine.running())
	coroutine.yield()
end

--[=[
	Asks for a full snapshot again, for when the client suspects it missed something
]=]
function GeodeClient.resync(self: GeodeClient)
	self._replication:fire({ kind = "resync" })
end

-- Atoms

local function track(atom: any)
	local current = tracking[#tracking]
	if current then
		current[atom] = true
	end
end

--[=[
	The value at `path` of a player's shared data, your own by default. Nil until it arrives or
	when the server doesn't share it with you

	@within GeodeClient
]=]
function GeodeClient.atom(self: GeodeClient, path: PathLike, userId: number?): Atom<any>
	local document = self:_owner(userId or self.userId)
	local atom = {} :: Atom<any>
	function atom.get(_atom: Atom<any>): any
		track(atom)
		return document:get(path)
	end
	function atom.subscribe(
		_atom: Atom<any>,
		callback: (new: any, old: any) -> ()
	): Types.Connection
		return document:observe(path, function(new: unknown, old: unknown)
			callback(new, old)
		end)
	end
	return atom
end

--[=[
	An atom computed from other atoms. It reruns when any atom it read changes, and notifies only
	when its result changed

	@within GeodeClient
]=]
function GeodeClient.computed<T>(_self: GeodeClient, compute: () -> T): Atom<T>
	local value: T
	local subscribers: { (new: T, old: T) -> () } = {}
	local connections: { Types.Connection } = {}
	local atom = {} :: Atom<T>

	local evaluate: () -> ()
	function evaluate()
		for _, connection in connections do
			connection:disconnect()
		end
		table.clear(connections)
		local reads: { [any]: boolean } = {}
		table.insert(tracking, reads)
		local ok, result = pcall(compute)
		table.remove(tracking)
		-- subscribe even if compute failed, so a later change can revive the atom
		for source in reads do
			table.insert(
				connections,
				(source :: Atom<any>):subscribe(function()
					evaluate()
				end)
			)
		end
		if not ok then
			error(result, 0)
		end
		local old = value
		value = result
		if not Tree.equal(old, value) then
			for _, callback in table.clone(subscribers) do
				callback(value, old)
			end
		end
	end
	evaluate()

	function atom.get(_atom: Atom<T>): T
		track(atom)
		return value
	end
	function atom.subscribe(_atom: Atom<T>, callback: (new: T, old: T) -> ()): Types.Connection
		table.insert(subscribers, callback)
		return {
			disconnect = function(_connection: Types.Connection)
				local index = table.find(subscribers, callback)
				if index then
					table.remove(subscribers, index)
				end
			end,
		}
	end
	return atom
end

--[=[
	Calls back with the new and old value whenever `path` changes

	@within GeodeClient
]=]
function GeodeClient.observe(
	self: GeodeClient,
	path: PathLike,
	callback: (new: any, old: any) -> (),
	userId: number?
): Types.Connection
	return self:atom(path, userId):subscribe(callback)
end

--// intent and adapters

--[=[
	Asks the server to run a remote op on your own data. The server checks the rate limit and
	the arguments, then runs its guards, so the request can be refused without any answer

	@within GeodeClient
]=]
function GeodeClient.op(self: GeodeClient, name: string, ...: any)
	local ops = self._ops
	if ops == nil then
		ops = self._services.remote(OPS_REMOTE)
		self._ops = ops
	end
	(ops :: Types.ClientRemote):fire(name, ...)
end

--[=[
	Makes Charm atoms that follow replicated paths. You pass the Charm module in, Geode has no
	dependency on it

	@within GeodeClient
]=]
function GeodeClient.charm(
	self: GeodeClient,
	charm: CharmLike
): { atom: (path: PathLike, userId: number?) -> any }
	return {
		atom = function(path: PathLike, userId: number?): any
			local source = self:atom(path, userId)
			local charmAtom = charm.atom(source:get())
			source:subscribe(function(new: any)
				charmAtom(new)
			end)
			return charmAtom
		end,
	}
end

return GeodeClient
