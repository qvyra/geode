--!strict

-- The one place in the core that touches Roblox services. Everything above Quartz gets a
-- `Services` value instead, which is how the same code runs on mocks in Lune

local Errors = require("../Errors")
local RealClock = require("./Clock")
local RealDataStore = require("./DataStore")
local RealHashMap = require("./HashMap")
local RealMessaging = require("./Messaging")
local RealOrderedDataStore = require("./OrderedDataStore")
local RealQueue = require("./Queue")
local RealRemotes = require("./Remotes")
local RealSortedMap = require("./SortedMap")
local RealTeleport = require("./Teleport")
local RobloxApi = require("./RobloxApi")
local Types = require("../Types")

export type Roblox = {
	dataStoreService: DataStoreService,
	memoryStoreService: MemoryStoreService,
	messagingService: MessagingService,
	teleportService: TeleportService,
	httpService: HttpService,
	playersService: Players,
	marketplaceService: MarketplaceService,
	replicatedStorage: Instance,
	runService: RunService,
	bindToClose: (callback: () -> ()) -> (),
	jobId: string,
	placeId: number,
	api: RobloxApi.RobloxApi,
	clock: Types.Clock?,
}

local DEFAULT_INVISIBILITY_TIMEOUT = 30

local RealServices = {}

-- real adapters fit the adapter types at runtime, but Luau won't accept their concrete
-- method types where the interface is expected
local function asAdapter<T>(adapter: unknown): T
	return adapter :: any
end

--[=[
	Builds services from explicit Roblox objects. Tests hand in fakes here to exercise the real
	adapters outside Roblox
]=]
function RealServices.fromRoblox(roblox: Roblox): Types.Services
	local cache: { [string]: unknown } = {}
	local function memo<T>(id: string, make: () -> T): T
		if cache[id] == nil then
			cache[id] = make()
		end
		return cache[id] :: T
	end

	local services: Types.Services = {
		jobId = roblox.jobId,
		placeId = roblox.placeId,
		guid = function(): string
			return roblox.httpService:GenerateGUID(false)
		end,
		clock = roblox.clock or RealClock.new(),
		budget = {
			get = function(_self: Types.Budget, budgetType: Types.BudgetType): number
				-- not metered, always reports 0
				if budgetType == "orderedList" then
					return math.huge
				end
				local requestType = roblox.api.budgetTypes[budgetType]
				return roblox.dataStoreService:GetRequestBudgetForRequestType(requestType)
			end,
		},
		json = {
			encode = function(_self: Types.Json, value: unknown): string
				return roblox.httpService:JSONEncode(value)
			end,
		},
		players = {
			kick = function(
				_self: Types.Players,
				userId: number,
				reason: string
			): Types.Result<nil>
				local ok, err = pcall(function()
					local player = roblox.playersService:GetPlayerByUserId(userId)
					if player then
						player:Kick(reason)
					end
				end)
				if not ok then
					return Errors.failWith(Errors.classify(err))
				end
				return Errors.ok(nil)
			end,
			onJoin = function(_self: Types.Players, handler: Types.PlayerHandler): Types.Connection
				local connection = roblox.playersService.PlayerAdded:Connect(
					function(player: Player)
						handler(player.UserId, player)
					end
				)
				return {
					disconnect = function(_connection: Types.Connection)
						connection:Disconnect()
					end,
				}
			end,
			onLeave = function(
				_self: Types.Players,
				handler: Types.PlayerHandler
			): Types.Connection
				local connection = roblox.playersService.PlayerRemoving:Connect(
					function(player: Player)
						handler(player.UserId, player)
					end
				)
				return {
					disconnect = function(_connection: Types.Connection)
						connection:Disconnect()
					end,
				}
			end,
			list = function(_self: Types.Players): { Types.PlayerEntry }
				local entries = {}
				for _, player in roblox.playersService:GetPlayers() do
					table.insert(entries, { userId = player.UserId, player = player })
				end
				return entries
			end,
			isPresent = function(_self: Types.Players, userId: number): boolean
				return roblox.playersService:GetPlayerByUserId(userId) ~= nil
			end,
		},
		marketplace = {
			setProcessReceipt = function(
				_self: Types.Marketplace,
				callback: (info: unknown) -> unknown
			)
				local service = roblox.marketplaceService :: any
				service.ProcessReceipt = callback
			end,
		},
		lifecycle = {
			bindToClose = function(_self: Types.Lifecycle, callback: () -> ())
				roblox.bindToClose(callback)
			end,
			isStudio = function(_self: Types.Lifecycle): boolean
				return roblox.runService:IsStudio()
			end,
		},
		dataStore = function(name: string, scope: string?): Types.DataStore
			local resolved = scope or "global"
			return memo(`dataStore\0{name}\0{resolved}`, function()
				local store = roblox.dataStoreService:GetDataStore(name, resolved)
				return asAdapter(RealDataStore.new(store, name, resolved, roblox.api))
			end)
		end,
		orderedDataStore = function(name: string, scope: string?): Types.OrderedDataStore
			local resolved = scope or "global"
			return memo(`orderedDataStore\0{name}\0{resolved}`, function()
				local store = roblox.dataStoreService:GetOrderedDataStore(name, resolved)
				return asAdapter(RealOrderedDataStore.new(store, name, resolved))
			end)
		end,
		hashMap = function(name: string): Types.HashMap
			return memo(`hashMap\0{name}`, function()
				local map = roblox.memoryStoreService:GetHashMap(name)
				return asAdapter(RealHashMap.new(map, name))
			end)
		end,
		sortedMap = function(name: string): Types.SortedMap
			return memo(`sortedMap\0{name}`, function()
				local map = roblox.memoryStoreService:GetSortedMap(name)
				return asAdapter(RealSortedMap.new(map, name, roblox.api))
			end)
		end,
		queue = function(name: string, invisibilityTimeout: number?): Types.Queue
			return memo(`queue\0{name}`, function()
				local timeout = invisibilityTimeout or DEFAULT_INVISIBILITY_TIMEOUT
				local queue = roblox.memoryStoreService:GetQueue(name, timeout)
				return asAdapter(RealQueue.new(queue, name, timeout))
			end)
		end,
		messaging = asAdapter(RealMessaging.new(roblox.messagingService)),
		teleport = asAdapter(RealTeleport.new(roblox.teleportService, roblox.api)),
		remote = function(name: string): Types.ServerRemote
			return memo(`remote\0{name}`, function()
				return RealRemotes.server(roblox.replicatedStorage, roblox.playersService, name)
			end)
		end,
	}
	return services
end

local liveClient: Types.ClientServices? = nil

--[=[
	What client code gets on a live Roblox client: the local player's id, a real clock and remotes
	that wait for the server to create them

	@within Raw
	@return ClientServices
]=]
function RealServices.client(): Types.ClientServices
	if liveClient == nil then
		local replicatedStorage = game:GetService("ReplicatedStorage")
		local localPlayer = game:GetService("Players").LocalPlayer
		liveClient = {
			userId = localPlayer.UserId,
			clock = RealClock.new(),
			remote = function(name: string): Types.ClientRemote
				return RealRemotes.client(replicatedStorage, name)
			end,
		}
	end
	return liveClient :: Types.ClientServices
end

local live: Types.Services? = nil

--[=[
	The services of the running game, built once on first use

	@within Raw
	@return Services
]=]
function RealServices.live(): Types.Services
	if live == nil then
		live = RealServices.fromRoblox({
			dataStoreService = game:GetService("DataStoreService"),
			memoryStoreService = game:GetService("MemoryStoreService"),
			messagingService = game:GetService("MessagingService"),
			teleportService = game:GetService("TeleportService"),
			httpService = game:GetService("HttpService"),
			playersService = game:GetService("Players"),
			marketplaceService = game:GetService("MarketplaceService"),
			replicatedStorage = game:GetService("ReplicatedStorage"),
			runService = game:GetService("RunService"),
			bindToClose = function(callback: () -> ())
				game:BindToClose(callback)
			end,
			jobId = game.JobId,
			placeId = game.PlaceId,
			api = RobloxApi.live(),
		})
	end
	return live :: Types.Services
end

return RealServices
