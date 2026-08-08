--!strict

-- L2. Session locked profiles

local ProfileStore = require("@self/ProfileStore")
local Receipts = require("@self/Receipts")
local Registry = require("@self/Registry")

--[=[
	@class Profile

	Player data held under a session lease, so only one server writes it at a time
]=]
local Profile = {
	--[=[
		@function store
		@within Profile
		@param options ProfileStoreOptions
		@return ProfileStore
	]=]
	store = ProfileStore.new,
}

return {
	Profile = table.freeze(Profile),
	receipts = Receipts.build,
	erase = Registry.erase,
}
