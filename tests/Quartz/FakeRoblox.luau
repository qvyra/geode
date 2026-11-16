--!strict

-- Fake Roblox service objects backed by a mock server. They throw and return the way the real
-- services do, so the real adapters' wrapping code (argument order, pcall, key info conversion,
-- paging) runs in Lune. They impersonate classes this runtime doesn't have, hence `any`

local Json = require("../../src/Quartz/Json")
local RealServices = require("../../src/Quartz/Real/Services")
local Types = require("../../src/Quartz/Types")
local Universe = require("../../src/Quartz/Mock/Universe")

local FakeRoblox = {}

local function unwrap<T>(result: Types.Result<T>): T
	if not result.ok then
		error(result.error.message, 0)
	end
	return result.value
end

local function keyInfo(info: Types.KeyInfo?): any
	if info == nil then
		return nil
	end
	return {
		Version = info.version,
		CreatedTime = info.createdTime,
		UpdatedTime = info.updatedTime,
		GetUserIds = function()
			return info.userIds
		end,
		GetMetadata = function()
			return info.metadata
		end,
	}
end

local function pages(items: { unknown }, pageSize: number): any
	local index = 1
	local fake = {}
	local function refresh()
		fake.IsFinished = index + pageSize > #items
	end
	function fake.GetCurrentPage(_self: any)
		local page = {}
		for offset = 0, pageSize - 1 do
			local item = items[index + offset]
			if item == nil then
				break
			end
			table.insert(page, item)
		end
		return page
	end
	function fake.AdvanceToNextPageAsync(_self: any)
		index += pageSize
		refresh()
	end
	refresh()
	return fake
end

local function dataStore(mock: Types.DataStore): any
	return {
		GetAsync = function(_self: any, key: string, options: any)
			local read = unwrap(mock:get(key, options and { useCache = options.UseCache }))
			return read.value, keyInfo(read.info)
		end,
		SetAsync = function(
			_self: any,
			key: string,
			value: unknown,
			userIds: { number }?,
			options: any
		)
			return unwrap(mock:set(key, value, {
				userIds = userIds,
				metadata = options and options.metadata,
			}))
		end,
		UpdateAsync = function(_self: any, key: string, transform: any)
			local update = unwrap(mock:update(key, function(current, info)
				local value, userIds, metadata = transform(current, keyInfo(info))
				if value == nil then
					return nil
				end
				return value, { userIds = userIds, metadata = metadata }
			end))
			if update.cancelled then
				return nil, nil
			end
			return update.value, keyInfo(update.info)
		end,
		RemoveAsync = function(_self: any, key: string)
			local read = unwrap(mock:remove(key))
			return read.value, keyInfo(read.info)
		end,
		IncrementAsync = function(
			_self: any,
			key: string,
			delta: number,
			userIds: { number }?,
			options: any
		)
			return unwrap(mock:increment(key, delta, {
				userIds = userIds,
				metadata = options and options.metadata,
			}))
		end,
		ListVersionsAsync = function(
			_self: any,
			key: string,
			direction: string,
			minDate: number,
			maxDate: number,
			pageSize: number
		)
			local versions = unwrap(mock:listVersions(key, {
				ascending = direction == "Ascending",
				minDate = if minDate == 0 then nil else minDate,
				maxDate = if maxDate == 0 then nil else maxDate,
				limit = math.huge,
			}))
			local items = {}
			for _, version in versions do
				table.insert(items, {
					Version = version.version,
					CreatedTime = version.createdTime,
					IsDeleted = version.deleted,
				})
			end
			return pages(items, pageSize)
		end,
		GetVersionAsync = function(_self: any, key: string, version: string)
			local read = unwrap(mock:getVersion(key, version))
			return read.value, keyInfo(read.info)
		end,
	}
end

local function orderedDataStore(mock: Types.OrderedDataStore): any
	return {
		GetAsync = function(_self: any, key: string)
			return unwrap(mock:get(key))
		end,
		SetAsync = function(_self: any, key: string, value: number)
			unwrap(mock:set(key, value))
		end,
		UpdateAsync = function(_self: any, key: string, transform: any)
			local update = unwrap(mock:update(key, transform))
			return if update.cancelled then nil else update.value
		end,
		RemoveAsync = function(_self: any, key: string)
			return unwrap(mock:remove(key))
		end,
		IncrementAsync = function(_self: any, key: string, delta: number)
			return unwrap(mock:increment(key, delta))
		end,
		GetSortedAsync = function(
			_self: any,
			ascending: boolean,
			pageSize: number,
			min: number?,
			max: number?
		)
			local entries = unwrap(mock:getSorted({
				ascending = ascending,
				limit = math.huge,
				min = min,
				max = max,
			}))
			return pages(entries, pageSize)
		end,
	}
end

local function hashMap(mock: Types.HashMap): any
	return {
		GetAsync = function(_self: any, key: string)
			return unwrap(mock:get(key))
		end,
		SetAsync = function(_self: any, key: string, value: unknown, ttl: number)
			unwrap(mock:set(key, value, ttl))
			return true
		end,
		UpdateAsync = function(_self: any, key: string, transform: any, ttl: number)
			local update = unwrap(mock:update(key, transform, ttl))
			return if update.cancelled then nil else update.value
		end,
		RemoveAsync = function(_self: any, key: string)
			unwrap(mock:remove(key))
		end,
		ListItemsAsync = function(_self: any, count: number)
			return pages(unwrap(mock:list(math.huge)), count)
		end,
	}
end

local function sortedMap(mock: Types.SortedMap): any
	return {
		GetAsync = function(_self: any, key: string)
			local entry = unwrap(mock:get(key))
			if entry == nil then
				return nil, nil
			end
			return entry.value, entry.sortKey
		end,
		SetAsync = function(
			_self: any,
			key: string,
			value: unknown,
			ttl: number,
			sortKey: Types.SortKey?
		)
			unwrap(mock:set(key, value, ttl, sortKey))
			return true
		end,
		UpdateAsync = function(_self: any, key: string, transform: any, ttl: number)
			local update = unwrap(mock:update(key, transform, ttl))
			if update.cancelled then
				return nil, nil
			end
			return update.value, update.sortKey
		end,
		RemoveAsync = function(_self: any, key: string)
			unwrap(mock:remove(key))
		end,
		GetRangeAsync = function(
			_self: any,
			direction: string,
			count: number,
			lower: any,
			upper: any
		)
			return unwrap(mock:getRange({
				descending = direction == "Descending",
				count = count,
				lower = lower,
				upper = upper,
			}))
		end,
	}
end

local function queue(mock: Types.Queue): any
	return {
		AddAsync = function(_self: any, value: unknown, ttl: number, priority: number)
			unwrap(mock:add(value, ttl, priority))
		end,
		ReadAsync = function(_self: any, count: number, allOrNothing: boolean, waitTimeout: number)
			local read = unwrap(mock:read({
				count = count,
				allOrNothing = allOrNothing,
				waitTimeout = waitTimeout,
			}))
			return read.items, read.id
		end,
		RemoveAsync = function(_self: any, id: string)
			unwrap(mock:remove(id))
		end,
	}
end

-- A stand-in for Players.PlayerAdded or PlayerRemoving, fed by the mock server's players
local function playerEvent(server: Universe.MockServer, method: "onJoin" | "onLeave"): any
	return {
		Connect = function(_self: any, callback: (player: any) -> ())
			local players: any = server.players
			local connection = players[method](players, function(_userId: number, player: any)
				callback(player)
			end)
			return {
				Disconnect = function()
					connection:disconnect()
				end,
			}
		end,
	}
end

--[=[
	Real services wired to fake Roblox objects, all backed by `server`
]=]
function FakeRoblox.services(server: Universe.MockServer): Types.Services
	local roblox: any = {
		dataStoreService = {
			GetRequestBudgetForRequestType = function(_self: any, requestType: string)
				return server.budget:get(requestType :: any)
			end,
			GetDataStore = function(_self: any, name: string, scope: string)
				return dataStore(server.dataStore(name, scope))
			end,
			GetOrderedDataStore = function(_self: any, name: string, scope: string)
				return orderedDataStore(server.orderedDataStore(name, scope))
			end,
		},
		memoryStoreService = {
			GetHashMap = function(_self: any, name: string)
				return hashMap(server.hashMap(name))
			end,
			GetSortedMap = function(_self: any, name: string)
				return sortedMap(server.sortedMap(name))
			end,
			GetQueue = function(_self: any, name: string, invisibilityTimeout: number)
				return queue(server.queue(name, invisibilityTimeout))
			end,
		},
		messagingService = {
			PublishAsync = function(_self: any, topic: string, data: unknown)
				unwrap(server.messaging:publish(topic, data))
			end,
			SubscribeAsync = function(_self: any, topic: string, callback: any)
				local connection = unwrap(server.messaging:subscribe(topic, function(data, sentAt)
					callback({ Data = data, Sent = sentAt })
				end))
				return {
					Disconnect = function()
						connection:disconnect()
					end,
				}
			end,
		},
		teleportService = {
			ReserveServer = function(_self: any, placeId: number)
				local reserved = unwrap(server.teleport:reserveServer(placeId))
				return reserved.code, reserved.serverId
			end,
			TeleportAsync = function(
				_self: any,
				placeId: number,
				players: { unknown },
				options: any
			)
				unwrap(server.teleport:teleport(placeId, players, {
					reservedServerCode = options and options.code,
					data = options and options.data,
				}))
			end,
		},
		runService = {
			IsStudio = function()
				return server.lifecycle:isStudio()
			end,
		},
		bindToClose = function(callback: () -> ())
			server.lifecycle:bindToClose(callback)
		end,
		playersService = {
			GetPlayerByUserId = function(_self: any, userId: number)
				return {
					Kick = function(_player: any, reason: string)
						unwrap(server.players:kick(userId, reason))
					end,
				}
			end,
			GetPlayers = function(_self: any)
				local players = {}
				for _, entry in server.players:list() do
					table.insert(players, entry.player)
				end
				return players
			end,
			PlayerAdded = playerEvent(server, "onJoin"),
			PlayerRemoving = playerEvent(server, "onLeave"),
		},
		marketplaceService = setmetatable({}, {
			__newindex = function(_self: any, field: string, value: any)
				assert(field == "ProcessReceipt", `unexpected field {field}`)
				server.marketplace:setProcessReceipt(value)
			end,
		}),
		httpService = {
			JSONEncode = function(_self: any, value: unknown)
				return Json.encode(value)
			end,
			GenerateGUID = function(_self: any, _wrap: boolean)
				return server.guid()
			end,
		},
		jobId = server.jobId,
		placeId = server.placeId,
		clock = server.clock,
		api = {
			budgetTypes = {
				standardRead = "standardRead",
				standardWrite = "standardWrite",
				standardList = "standardList",
				standardRemove = "standardRemove",
				orderedRead = "orderedRead",
				orderedWrite = "orderedWrite",
				orderedList = "orderedList",
				orderedRemove = "orderedRemove",
			},
			sortAscending = "Ascending",
			sortDescending = "Descending",
			newSetOptions = function(metadata)
				return { metadata = metadata }
			end,
			newGetOptions = function(useCache)
				return { UseCache = useCache }
			end,
			newIncrementOptions = function(metadata)
				return { metadata = metadata }
			end,
			newTeleportOptions = function(code, data)
				return { code = code, data = data }
			end,
		},
	}
	return RealServices.fromRoblox(roblox)
end

return FakeRoblox
