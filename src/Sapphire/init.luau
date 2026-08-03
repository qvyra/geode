--!strict

-- L2. Session locked profiles

local ProfileStore = require("@self/ProfileStore")

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

return table.freeze(Profile)
