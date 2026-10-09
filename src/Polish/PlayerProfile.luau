--!strict

-- What `PlayerData:get(player)` hands out: one player's data, usable from the moment they
-- join. Before the profile loads, reads return the template and writes are refused, so UI can
-- render right away and use `isLoaded` to tell defaults from real data

local Document = require("../Matrix/Document")
local Path = require("../Matrix/Path")
local Profile = require("../Sapphire/Profile")
local Transaction = require("../Matrix/Transaction")
local Types = require("../Quartz/Types")

type PathLike = Path.PathLike

type PendingObserver = {
	path: PathLike,
	callback: Document.Observer,
	connection: Types.Connection?,
	disconnected: boolean,
}

type Fields = {
	userId: number,
	player: unknown,
	_defaults: Document.Document,
	_profile: Profile.Profile?,
	_observers: { PendingObserver },
}

--[=[
	@class PlayerProfile

	One player's data, usable from the moment they join. Until the profile loads, reads return the
	template and writes are refused
]=]
local PlayerProfile = {}
PlayerProfile.__index = PlayerProfile

export type PlayerProfile = typeof(setmetatable({} :: Fields, PlayerProfile))

function PlayerProfile.new(
	userId: number,
	player: unknown,
	defaults: Document.Document
): PlayerProfile
	return setmetatable(
		{
			userId = userId,
			player = player,
			_defaults = defaults,
			_profile = nil,
			_observers = {},
		} :: Fields,
		PlayerProfile
	)
end

-- PlayerData calls this when the profile loads or goes away
function PlayerProfile._attach(self: PlayerProfile, profile: Profile.Profile?)
	self._profile = profile
	for _, observer in self._observers do
		if observer.connection then
			observer.connection:disconnect()
			observer.connection = nil
		end
		if profile and not observer.disconnected then
			observer.connection = profile:observe(observer.path, observer.callback)
		end
	end
end

local function notLoaded(self: PlayerProfile): Document.TxResult
	return {
		ok = false,
		error = {
			kind = "readOnly",
			message = `the data of player {self.userId} isn't loaded yet`,
		},
	}
end

--[=[
	Whether the player's real data has loaded. Until it has, reads return the template

	@within PlayerProfile
]=]
function PlayerProfile.isLoaded(self: PlayerProfile): boolean
	local profile = self._profile
	return profile ~= nil and profile:isActive()
end

--[=[
	The loaded profile, or nil while the data isn't loaded

	@within PlayerProfile
]=]
function PlayerProfile.profile(self: PlayerProfile): Profile.Profile?
	return self._profile
end

--[=[
	Reads a frozen value. Until the data loads you get the template's value

	@within PlayerProfile
]=]
function PlayerProfile.get(self: PlayerProfile, path: PathLike?): unknown
	local profile = self._profile
	if profile then
		return profile:get(path)
	end
	return self._defaults:get(path)
end

--[=[
	The whole value, frozen

	@within PlayerProfile
]=]
function PlayerProfile.snapshot(self: PlayerProfile): unknown
	local profile = self._profile
	if profile then
		return profile:snapshot()
	end
	return self._defaults:snapshot()
end

--[=[
	Calls back after each commit that changes `path`. Observers added before the data loads
	start hearing about changes once it's in

	@within PlayerProfile
]=]
function PlayerProfile.observe(
	self: PlayerProfile,
	path: PathLike,
	callback: Document.Observer
): Types.Connection
	local observer: PendingObserver =
		{ path = path, callback = callback, connection = nil, disconnected = false }
	table.insert(self._observers, observer)
	local profile = self._profile
	if profile then
		observer.connection = profile:observe(path, callback)
	end
	return {
		disconnect = function(_self: Types.Connection)
			observer.disconnected = true
			if observer.connection then
				observer.connection:disconnect()
			end
			local index = table.find(self._observers, observer)
			if index then
				table.remove(self._observers, index)
			end
		end,
	}
end

--// writes (refused until the data loads)

--[=[
	Runs `body` as a single transaction: every op inside lands together or none do

	@within PlayerProfile
]=]
function PlayerProfile.transact(
	self: PlayerProfile,
	body: (tx: Transaction.Transaction) -> (),
	options: Document.TransactOptions?
): Document.TxResult
	local profile = self._profile
	if profile == nil then
		return notLoaded(self)
	end
	return profile:transact(body, options)
end

--[=[
	Sets `path` to `value` as its own transaction

	@within PlayerProfile
]=]
function PlayerProfile.set(self: PlayerProfile, path: PathLike, value: unknown): Document.TxResult
	local profile = self._profile
	return if profile then profile:set(path, value) else notLoaded(self)
end

--[=[
	Replaces the value at `path` with what `transform` returns, as its own transaction

	@within PlayerProfile
]=]
function PlayerProfile.update(
	self: PlayerProfile,
	path: PathLike,
	updater: (current: unknown) -> unknown
): Document.TxResult
	local profile = self._profile
	return if profile then profile:update(path, updater) else notLoaded(self)
end

--[=[
	Adds `amount`, 1 by default, to the number at `path`

	@within PlayerProfile
]=]
function PlayerProfile.increment(
	self: PlayerProfile,
	path: PathLike,
	amount: number?
): Document.TxResult
	local profile = self._profile
	return if profile then profile:increment(path, amount) else notLoaded(self)
end

--[=[
	Subtracts `amount`, 1 by default, from the number at `path`

	@within PlayerProfile
]=]
function PlayerProfile.decrement(
	self: PlayerProfile,
	path: PathLike,
	amount: number?
): Document.TxResult
	local profile = self._profile
	return if profile then profile:decrement(path, amount) else notLoaded(self)
end

--[=[
	Adds `value` to the end of the list at `path`

	@within PlayerProfile
]=]
function PlayerProfile.append(
	self: PlayerProfile,
	path: PathLike,
	value: unknown
): Document.TxResult
	local profile = self._profile
	return if profile then profile:append(path, value) else notLoaded(self)
end

--[=[
	Inserts `value` into the list at `path` at `index`

	@within PlayerProfile
]=]
function PlayerProfile.insert(
	self: PlayerProfile,
	path: PathLike,
	index: number,
	value: unknown
): Document.TxResult
	local profile = self._profile
	return if profile then profile:insert(path, index, value) else notLoaded(self)
end

--[=[
	Removes the value at `path`

	@within PlayerProfile
]=]
function PlayerProfile.remove(self: PlayerProfile, path: PathLike): Document.TxResult
	local profile = self._profile
	return if profile then profile:remove(path) else notLoaded(self)
end

--[=[
	Empties the table at `path`, or everything with no path

	@within PlayerProfile
]=]
function PlayerProfile.clear(self: PlayerProfile, path: PathLike?): Document.TxResult
	local profile = self._profile
	return if profile then profile:clear(path) else notLoaded(self)
end

--[=[
	Copies the fields of `partial` into the table at `path`

	@within PlayerProfile
]=]
function PlayerProfile.merge(
	self: PlayerProfile,
	path: PathLike?,
	values: { [string]: unknown }
): Document.TxResult
	local profile = self._profile
	return if profile then profile:merge(path, values) else notLoaded(self)
end

--[=[
	Runs the custom op `name` with the given arguments as its own transaction

	@within PlayerProfile
]=]
function PlayerProfile.op(self: PlayerProfile, name: string, ...: any): Document.TxResult
	local profile = self._profile
	return if profile then profile:op(name, ...) else notLoaded(self)
end

return PlayerProfile
