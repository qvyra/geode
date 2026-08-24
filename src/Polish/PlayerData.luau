--!strict

-- Player data with the lifecycle handled: a profile loads on join, is released on leave, and
-- shutdown, session loss and purchases are wired up. Only the public API of the profile
-- store is used here, and the store stays reachable as `PlayerData.store`

local Document = require("../Matrix/Document")
local Profile = require("../Sapphire/Profile")
local ProfileStore = require("../Sapphire/ProfileStore")
local Receipts = require("../Sapphire/Receipts")
local PlayerProfile = require("./PlayerProfile")
local Signal = require("../Quartz/Signal")
local Types = require("../Quartz/Types")

export type Visibility = "private" | "owner" | "public"

export type Options = ProfileStore.Options & {
	products: { [number]: Receipts.Handler }?,
	-- Which paths reach which clients. Checked now, takes effect once replication ships
	replicate: { [string]: Visibility }?,
	-- extra load attempts before the player is kicked, default 3
	loadRetries: number?,
	-- what the receipt callback returns, defaults to Enum.ProductPurchaseDecision
	decisions: Receipts.Decisions?,
}

type Entry = {
	userId: number,
	player: unknown,
	handle: PlayerProfile.PlayerProfile,
	profile: Profile.Profile?,
	left: boolean,
	settled: boolean,
	waiting: { thread },
	connections: { Types.Connection },
}

type Fields = {
	store: ProfileStore.ProfileStore,
	-- (player, profile) when a player's data loads
	loaded: Signal.Signal,
	-- (player, profile) when the data is released or the session is lost
	released: Signal.Signal,
	_services: Types.Services,
	_report: (message: string) -> (),
	_defaults: Document.Document,
	_entries: { [number]: Entry },
	_loadRetries: number,
	_connections: { Types.Connection },
}

local PlayerData = {}
PlayerData.__index = PlayerData

export type PlayerData = typeof(setmetatable({} :: Fields, PlayerData))

local KICK_MESSAGE = "Couldn't load your data, please rejoin"
local RETRY_DELAY = 2
local RELEASE_TRIES = 3

-- Load failures that can clear up on their own. Retrying anything else is pointless
local RETRYABLE: { [string]: boolean } = {
	adapter = true,
	leaseHeld = true,
	alreadyLoaded = true,
}

local function userIdOf(player: unknown): number
	local userId = if type(player) == "table" or typeof(player) == "Instance"
		then (player :: any).UserId
		else nil
	assert(type(userId) == "number", "expected a player")
	return userId
end

function PlayerData.new(
	store: ProfileStore.ProfileStore,
	services: Types.Services,
	template: { [string]: unknown },
	options: { loadRetries: number?, report: (message: string) -> () }
): PlayerData
	local self = setmetatable(
		{
			store = store,
			loaded = Signal.new(options.report),
			released = Signal.new(options.report),
			_services = services,
			_report = options.report,
			_defaults = Document.new({ data = template }),
			_entries = {},
			_loadRetries = options.loadRetries or 3,
			_connections = {},
		} :: Fields,
		PlayerData
	)

	local players = services.players
	table.insert(
		self._connections,
		players:onJoin(function(userId: number, player: unknown)
			self:_join(userId, player)
		end)
	)
	table.insert(
		self._connections,
		players:onLeave(function(userId: number)
			self:_leave(userId)
		end)
	)
	for _, entry in players:list() do
		services.clock:spawn(function()
			self:_join(entry.userId, entry.player)
		end)
	end
	return self
end

-- Lifecycle

function PlayerData._join(self: PlayerData, userId: number, player: unknown)
	if self._entries[userId] then
		return
	end
	local entry: Entry = {
		userId = userId,
		player = player,
		handle = PlayerProfile.new(userId, player, self._defaults),
		profile = nil,
		left = false,
		settled = false,
		waiting = {},
		connections = {},
	}
	self._entries[userId] = entry

	local store = self.store
	local clock = self._services.clock
	local key = store:keyForUser(userId)
	local lastError = "no attempt was made"
	for attempt = 1, self._loadRetries + 1 do
		if entry.left then
			break
		end
		local result = store:load(key, { userId = userId })
		if result.ok then
			self:_loaded(entry, result.profile)
			return
		end
		lastError = result.error.message
		if not RETRYABLE[result.error.kind] then
			break
		end
		if attempt <= self._loadRetries then
			clock:wait(RETRY_DELAY * attempt)
		end
	end

	self:_settle(entry)
	if not entry.left then
		self._report(`couldn't load the data of player {userId}: {lastError}`)
		self._services.players:kick(userId, KICK_MESSAGE)
	end
	if self._entries[userId] == entry then
		self._entries[userId] = nil
	end
end

function PlayerData._loaded(self: PlayerData, entry: Entry, profile: Profile.Profile)
	if entry.left then
		-- left while loading, give it straight back
		self:_release(entry, profile)
		self:_settle(entry)
		return
	end
	entry.profile = profile
	entry.handle:_attach(profile)
	local function closed()
		if entry.profile ~= profile then
			return
		end
		entry.profile = nil
		entry.handle:_attach(nil)
		for _, connection in entry.connections do
			connection:disconnect()
		end
		self.released:fire(entry.player, profile)
	end
	table.insert(entry.connections, profile.released:connect(closed))
	table.insert(entry.connections, profile.sessionLost:connect(closed))
	self:_settle(entry)
	self.loaded:fire(entry.player, profile)
end

-- wake everyone waiting on this player's load, however it ended
function PlayerData._settle(self: PlayerData, entry: Entry)
	if entry.settled then
		return
	end
	entry.settled = true
	local waiting = entry.waiting
	entry.waiting = {}
	for _, thread in waiting do
		self._services.clock:resume(thread)
	end
end

function PlayerData._leave(self: PlayerData, userId: number)
	local entry = self._entries[userId]
	if entry == nil then
		return
	end
	entry.left = true
	self._entries[userId] = nil
	local profile = entry.profile
	if profile then
		self:_release(entry, profile)
	end
end

function PlayerData._release(self: PlayerData, entry: Entry, profile: Profile.Profile)
	local clock = self._services.clock
	for attempt = 1, RELEASE_TRIES do
		local result = profile:release()
		if result.ok or result.error.kind == "lost" then
			return
		end
		if attempt < RELEASE_TRIES then
			clock:wait(RETRY_DELAY * attempt)
		end
	end
	-- autosave keeps the data safe, shutdown releases it eventually
	self._report(`releasing the data of player {entry.userId} keeps failing, autosave will retry`)
end

-- Public API

--[=[
	Calls back with the player and their profile whenever a player's data loads. Players whose
	data already loaded are included

	@within PlayerData
	@return Connection
]=]
function PlayerData.onLoaded(
	self: PlayerData,
	callback: (player: unknown, profile: Profile.Profile) -> ()
): Types.Connection
	local connection = self.loaded:connect(callback)
	-- iterate keys, iterating values loses the Profile type
	for userId in self._entries do
		local entry = self._entries[userId]
		local profile = entry.profile
		if profile then
			self._services.clock:spawn(function()
				callback(entry.player, profile)
			end)
		end
	end
	return connection
end

--[=[
	Calls back with the player and their profile when the data is released or the session is lost

	@within PlayerData
	@return Connection
]=]
function PlayerData.onReleased(
	self: PlayerData,
	callback: (player: unknown, profile: Profile.Profile) -> ()
): Types.Connection
	return self.released:connect(callback)
end

--[=[
	The player's data, usable right away. Until it loads, reads return the template and writes
	are refused. Nil when the player isn't on this server

	@within PlayerData
]=]
function PlayerData.get(self: PlayerData, player: unknown): PlayerProfile.PlayerProfile?
	local entry = self._entries[userIdOf(player)]
	return if entry then entry.handle else nil
end

--[=[
	Whether the player's real data has loaded

	@within PlayerData
]=]
function PlayerData.isLoaded(self: PlayerData, player: unknown): boolean
	local entry = self._entries[userIdOf(player)]
	return entry ~= nil and entry.handle:isLoaded()
end

--[=[
	Yields until the player's data loads and returns the profile. Returns nil if the load failed,
	the player left, or `timeout` seconds passed first

	@within PlayerData
]=]
function PlayerData.waitFor(self: PlayerData, player: unknown, timeout: number?): Profile.Profile?
	local entry = self._entries[userIdOf(player)]
	if entry == nil then
		return nil
	end
	if entry.settled then
		return entry.profile
	end
	local thread = coroutine.running()
	local clock = self._services.clock
	table.insert(entry.waiting, thread)
	if timeout then
		clock:delay(timeout, function()
			local index = table.find(entry.waiting, thread)
			if index then
				table.remove(entry.waiting, index)
				clock:resume(thread)
			end
		end)
	end
	coroutine.yield()
	return entry.profile
end

--[=[
	Stops handling joins and leaves. Profiles already open stay open until released

	@within PlayerData
]=]
function PlayerData.destroy(self: PlayerData)
	for _, connection in self._connections do
		connection:disconnect()
	end
	table.clear(self._connections)
end

return PlayerData
