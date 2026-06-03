--!strict

--[=[
	@class Geode

	A layered data framework for Roblox. Modules are added to this table as they land
]=]
local Geode = {}

--[=[
	@prop version string
	@within Geode
	@readonly

	Semantic version of the running Geode build
]=]
Geode.version = "0.0.0"

return table.freeze(Geode)
