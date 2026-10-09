--!strict

local SharedStore = require("@self/SharedStore")

--[=[
	@class Shared

	Stores any server may write. Every write runs the whole pipeline inside UpdateAsync
]=]
local Shared = {
	store = SharedStore.new,
}

return table.freeze(Shared)
