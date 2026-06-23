--!strict

-- The few Roblox globals the real adapters need besides service objects. Passed in so the
-- adapters stay free of globals and their wrapping code runs in Lune against fake services

local Types = require("../Types")

export type RobloxApi = {
	budgetTypes: { [Types.BudgetType]: Enum.DataStoreRequestType },
	sortAscending: Enum.SortDirection,
	sortDescending: Enum.SortDirection,
	newSetOptions: (metadata: { [string]: unknown }) -> DataStoreSetOptions,
	newIncrementOptions: (metadata: { [string]: unknown }) -> DataStoreIncrementOptions,
	newTeleportOptions: (reservedServerCode: string?, data: unknown?) -> TeleportOptions,
}

local RobloxApi = {}

--[=[
	The real globals. Only call this inside Roblox
]=]
function RobloxApi.live(): RobloxApi
	return {
		budgetTypes = {
			get = Enum.DataStoreRequestType.GetAsync,
			setIncrement = Enum.DataStoreRequestType.SetIncrementAsync,
			update = Enum.DataStoreRequestType.UpdateAsync,
			getSorted = Enum.DataStoreRequestType.GetSortedAsync,
			setIncrementSorted = Enum.DataStoreRequestType.SetIncrementSortedAsync,
			list = Enum.DataStoreRequestType.ListAsync,
		},
		sortAscending = Enum.SortDirection.Ascending,
		sortDescending = Enum.SortDirection.Descending,
		newSetOptions = function(metadata: { [string]: unknown }): DataStoreSetOptions
			local options = Instance.new("DataStoreSetOptions")
			options:SetMetadata(metadata)
			return options
		end,
		newIncrementOptions = function(metadata: { [string]: unknown }): DataStoreIncrementOptions
			local options = Instance.new("DataStoreIncrementOptions")
			options:SetMetadata(metadata)
			return options
		end,
		newTeleportOptions = function(reservedServerCode: string?, data: unknown?): TeleportOptions
			local options = Instance.new("TeleportOptions")
			if reservedServerCode then
				options.ReservedServerAccessCode = reservedServerCode
			end
			if data ~= nil then
				options:SetTeleportData(data :: any)
			end
			return options
		end,
	}
end

return RobloxApi
