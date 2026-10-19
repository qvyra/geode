--!strict

-- One adapter per benchmarked library, all with the same shape, so the bench runs the same steps
-- on each. Every library gets the counting DataStoreService proxy instead of the real service,
-- through whatever way it offers: Geode through its services, Lapis through setConfig, DataStore2
-- through the modules it monkey patches in its own tests, and ProfileStore and ProfileService
-- through a one line swap the runner makes when it downloads them (see libraries.json).
-- Data goes through each library's documented API, nothing reaches into their internals

local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Geode = require("../../src")
local Proxy = require("./Proxy")
local RobloxApi = require("../../src/Quartz/Real/RobloxApi")

export type Handle = {
	-- the DataStore key the library writes, as the proxy logs it
	key: string,
	value: any,
}

export type Context = {
	proxy: Proxy.Proxy,
	-- yields until a write to `key` that started at or after `since` finished, or the timeout
	waitWrite: (key: string, since: number, timeout: number) -> boolean,
	-- seconds a ProfileStore load may keep trying before it's cancelled
	loadLimit: number,
	-- seconds an adapter waits for a write it started on another thread
	writeLimit: number,
}

export type Adapter = {
	name: string,
	-- whether the library keeps a session lock at all
	locks: boolean,
	load: (key: string) -> Handle,
	coins: (handle: Handle) -> number?,
	set: (handle: Handle, field: string, value: unknown) -> (),
	-- each of these yields until the library's DataStore write is done, and errors if it failed
	save: (handle: Handle) -> (),
	release: (handle: Handle) -> (),
	-- calls back once if the library tells this server it lost the session
	watch: (handle: Handle, onLost: (reason: string) -> ()) -> (),
}

local Libraries = {}

Libraries.NAMES = { "Geode", "ProfileStore", "ProfileService", "Lapis", "DataStore2" }

-- The same starting data for every library
function Libraries.template(): { [string]: any }
	return {
		coins = 0,
		level = 1,
		inventory = {},
		settings = { music = true, volume = 0.5 },
	}
end

function Libraries.storeName(library: string): string
	return `GeodeStudioCheck_Bench_{library}`
end

local function vendored(name: string): ModuleScript
	local folder = (script.Parent :: Instance):FindFirstChild("Vendor")
	local module = folder and folder:FindFirstChild(name)
	if module == nil or not module:IsA("ModuleScript") then
		error(`the bench place has no {name} module, was it downloaded?`)
	end
	return module :: ModuleScript
end

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in value do
		copy[key] = deepCopy(child)
	end
	return copy
end

--// Geode

local function geode(context: Context): Adapter
	local name = Libraries.storeName("Geode")
	-- Execution tasks may report being Studio. A live server isn't, so Geode is told so
	-- and runs exactly as it would there, steals and handoffs included
	local runService: any = if RunService:IsStudio()
		then {
			IsStudio = function()
				return false
			end,
			IsServer = function()
				return true
			end,
		}
		else RunService
	local services = Geode.Raw.fromRoblox({
		dataStoreService = context.proxy.service,
		memoryStoreService = MemoryStoreService,
		messagingService = MessagingService,
		teleportService = game:GetService("TeleportService"),
		httpService = game:GetService("HttpService"),
		playersService = game:GetService("Players"),
		marketplaceService = game:GetService("MarketplaceService"),
		replicatedStorage = game:GetService("ReplicatedStorage"),
		serverStorage = ServerStorage,
		runService = runService,
		bindToClose = function(callback: () -> ())
			game:BindToClose(callback)
		end,
		jobId = game.JobId,
		placeId = game.PlaceId,
		api = RobloxApi.live(),
	})
	local store = Geode.Profile.store({
		name = name,
		template = Libraries.template(),
		services = services,
	})

	return {
		name = "Geode",
		locks = true,
		load = function(key: string): Handle
			local result = store:load(key)
			if not result.ok then
				error(`{result.error.kind}: {result.error.message}`, 0)
			end
			return { key = key, value = result.profile }
		end,
		coins = function(handle: Handle): number?
			return handle.value:get("coins")
		end,
		set = function(handle: Handle, field: string, value: unknown)
			local result = handle.value:set(field, value)
			if not result.ok then
				error(`set {field} failed: {result.error.message}`, 0)
			end
		end,
		save = function(handle: Handle)
			local result = handle.value:save()
			if not result.ok then
				error(`{result.error.kind}: {result.error.message}`, 0)
			end
		end,
		release = function(handle: Handle)
			local result = handle.value:release()
			if not result.ok then
				error(`{result.error.kind}: {result.error.message}`, 0)
			end
		end,
		watch = function(handle: Handle, onLost: (reason: string) -> ())
			handle.value.sessionLost:connect(function(reason: string)
				onLost(`sessionLost: {reason}`)
			end)
			-- a holder asked to let go releases, which is how a handoff shows up here
			handle.value.released:connect(function()
				onLost("released")
			end)
		end,
	}
end

--// ProfileStore

local function profileStore(context: Context): Adapter
	local ProfileStore = require(vendored("ProfileStore")) :: any
	local store = ProfileStore.New(Libraries.storeName("ProfileStore"), Libraries.template())

	-- Save and EndSession start the write on a new thread, so the adapter waits for the write
	-- itself to finish
	local function written(handle: Handle, start: () -> ())
		local since = os.clock()
		start()
		if not context.waitWrite(handle.key, since, context.writeLimit) then
			error("the write didn't finish", 0)
		end
	end

	return {
		name = "ProfileStore",
		locks = true,
		load = function(key: string): Handle
			local deadline = os.clock() + context.loadLimit
			local profile = store:StartSessionAsync(key, {
				Cancel = function()
					return os.clock() > deadline
				end,
			})
			if profile == nil then
				error("StartSessionAsync returned nil", 0)
			end
			return { key = key, value = profile }
		end,
		coins = function(handle: Handle): number?
			return handle.value.Data.coins
		end,
		set = function(handle: Handle, field: string, value: unknown)
			handle.value.Data[field] = deepCopy(value)
		end,
		save = function(handle: Handle)
			written(handle, function()
				handle.value:Save()
			end)
		end,
		release = function(handle: Handle)
			written(handle, function()
				handle.value:EndSession()
			end)
		end,
		watch = function(handle: Handle, onLost: (reason: string) -> ())
			handle.value.OnLastSave:Connect(function(reason: string)
				onLost(`OnLastSave: {reason}`)
			end)
		end,
	}
end

--// ProfileService

local function profileService(context: Context): Adapter
	local ProfileService = require(vendored("ProfileService")) :: any
	local store =
		ProfileService.GetProfileStore(Libraries.storeName("ProfileService"), Libraries.template())

	local function written(handle: Handle, start: () -> ())
		local since = os.clock()
		start()
		if not context.waitWrite(handle.key, since, context.writeLimit) then
			error("the write didn't finish", 0)
		end
	end

	return {
		name = "ProfileService",
		locks = true,
		load = function(key: string): Handle
			-- "ForceLoad" is what ProfileService's own examples pass. It can't be cancelled, the
			-- bench stops waiting on any step that runs too long
			local profile = store:LoadProfileAsync(key, "ForceLoad")
			if profile == nil then
				error("LoadProfileAsync returned nil", 0)
			end
			return { key = key, value = profile }
		end,
		coins = function(handle: Handle): number?
			return handle.value.Data.coins
		end,
		set = function(handle: Handle, field: string, value: unknown)
			handle.value.Data[field] = deepCopy(value)
		end,
		save = function(handle: Handle)
			written(handle, function()
				handle.value:Save()
			end)
		end,
		release = function(handle: Handle)
			written(handle, function()
				handle.value:Release()
			end)
		end,
		watch = function(handle: Handle, onLost: (reason: string) -> ())
			handle.value:ListenToRelease(function()
				onLost("ListenToRelease")
			end)
		end,
	}
end

--// Lapis

local function lapis(context: Context): Adapter
	local Lapis = require(vendored("Lapis")) :: any
	Lapis.setConfig({ dataStoreService = context.proxy.service })
	local collection = Lapis.createCollection(Libraries.storeName("Lapis"), {
		defaultData = Libraries.template(),
	})

	return {
		name = "Lapis",
		locks = true,
		load = function(key: string): Handle
			return { key = key, value = collection:load(key):expect() }
		end,
		coins = function(handle: Handle): number?
			return handle.value:read().coins
		end,
		set = function(handle: Handle, field: string, value: unknown)
			-- data is frozen by default and replaced with write
			local data = table.clone(handle.value:read())
			data[field] = deepCopy(value)
			handle.value:write(data)
		end,
		save = function(handle: Handle)
			handle.value:save():expect()
		end,
		release = function(handle: Handle)
			handle.value:close():expect()
		end,
		watch = function(_handle: Handle, _onLost: (reason: string) -> ())
			-- Lapis has no signal for this, a later save fails with SessionLockStolen
		end,
	}
end

--// DataStore2

-- DataStore2 keys its data by a Player. The bench has no players, so it hands over a stand-in
-- with the parts DataStore2 reads: UserId, AncestryChanged and IsDescendantOf
local function standInPlayer(userId: number): any
	local ancestry = Instance.new("BindableEvent")
	local inGame = true
	local player = {
		isBenchPlayer = true,
		UserId = userId,
		Name = `bench_{userId}`,
		AncestryChanged = ancestry.Event,
	}
	function player.IsDescendantOf(_self: any, _ancestor: Instance): boolean
		return inGame
	end
	function player.leave()
		inGame = false
		ancestry:Fire()
	end
	return player
end

local function dataStore2(context: Context): Adapter
	local module = vendored("DataStore2")
	if RunService:IsStudio() and ServerStorage:FindFirstChild("SaveInStudio") == nil then
		-- DataStore2 skips saves in Studio unless this exists. Made at runtime, never saved
		local flag = Instance.new("BoolValue")
		flag.Name = "SaveInStudio"
		flag.Value = true
		flag.Parent = ServerStorage
	end
	-- the same two monkey patches DataStore2's own tests use
	local retriever =
		require(module:FindFirstChild("DataStoreServiceRetriever") :: ModuleScript) :: any
	retriever.Get = function()
		return context.proxy.service
	end
	local isPlayer = require(module:FindFirstChild("IsPlayer") :: ModuleScript) :: any
	local realCheck = isPlayer.Check
	isPlayer.Check = function(object: any): boolean
		return (type(object) == "table" and object.isBenchPlayer == true) or realCheck(object)
	end
	local DataStore2 = require(module) :: any
	-- The default saving method opens a DataStore and an OrderedDataStore per player, named
	-- after the player, which the bench's one allowed name rules out. Standard keeps one
	-- DataStore keyed by user id
	DataStore2.PatchGlobalSettings({ SavingMethod = "Standard" })
	local name = Libraries.storeName("DataStore2")

	return {
		name = "DataStore2",
		locks = false,
		load = function(key: string): Handle
			local userId = tonumber(key)
			if userId == nil then
				error("DataStore2 keys are user ids", 0)
			end
			local player = standInPlayer(userId)
			local store = DataStore2(name, player)
			store:Get(Libraries.template())
			return { key = key, value = { store = store, player = player } }
		end,
		coins = function(handle: Handle): number?
			local data = handle.value.store:Get(nil, true)
			return data and data.coins
		end,
		set = function(handle: Handle, field: string, value: unknown)
			local data = handle.value.store:Get(nil, true) or Libraries.template()
			data = deepCopy(data)
			data[field] = deepCopy(value)
			handle.value.store:Set(data)
		end,
		save = function(handle: Handle)
			local ok, result = handle.value.store:SaveAsync():await()
			if not ok then
				error(tostring(result), 0)
			end
		end,
		release = function(handle: Handle)
			-- what happens when a player leaves: DataStore2 saves on AncestryChanged
			local since = os.clock()
			handle.value.player.leave()
			if not context.waitWrite(handle.key, since, context.writeLimit) then
				error("the leave save didn't finish", 0)
			end
		end,
		watch = function(_handle: Handle, _onLost: (reason: string) -> ())
			-- no session lock, so nothing to lose
		end,
	}
end

local MAKERS: { [string]: (Context) -> Adapter } = {
	Geode = geode,
	ProfileStore = profileStore,
	ProfileService = profileService,
	Lapis = lapis,
	DataStore2 = dataStore2,
}

function Libraries.make(name: string, context: Context): Adapter
	local maker = MAKERS[name]
	if maker == nil then
		error(`unknown library {name}`)
	end
	return maker(context)
end

-- Keys the bench uses for a library. DataStore2 keys by user id, so its keys are numbers
function Libraries.key(library: string, run: string, label: string, index: number): string
	if library == "DataStore2" then
		-- the run id is hex, its first six digits plus a label number make a unique id
		local base = tonumber(string.sub(run, 1, 6), 16) :: number
		local labels = { perf = 1, hop = 2, keep = 3, throttle = 4 }
		return tostring(base * 1000 + (labels[label] or 9) * 100 + index)
	end
	return `{run}-{label}-{index}`
end

return Libraries
