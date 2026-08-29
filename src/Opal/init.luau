--!strict

local SharedStore = require("@self/SharedStore")

--[=[
	@class Shared
]=]
local Shared = {
	--[=[
		@function store
		@within Shared
		@param options SharedStoreOptions
		@return SharedStore
	]=]
	store = SharedStore.new,
}

return table.freeze(Shared)
