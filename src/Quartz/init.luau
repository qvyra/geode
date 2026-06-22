--!strict

-- L0: thin adapters over Roblox services, their in-memory mocks, and the clock everything
-- waits on

local Errors = require("@self/Errors")
local MockClock = require("@self/Mock/Clock")
local RealClock = require("@self/Real/Clock")
local RealServices = require("@self/Real/Services")
local Universe = require("@self/Mock/Universe")

--[=[
	@class Raw

	Direct access to the real adapters. Stores take a `Services` value, and this is where the
	real one comes from
]=]
local Raw = {
	--[=[
		@function services
		@within Raw
		@return Services -- the running game's services, built once

		```lua
		local services = Geode.Raw.services()
		local result = services.dataStore("PlayerData"):get("player_1")
		```
	]=]
	services = RealServices.live,
	--[=[
		@function fromRoblox
		@within Raw
		@param roblox Roblox -- explicit service objects and Roblox globals
		@return Services
	]=]
	fromRoblox = RealServices.fromRoblox,
	--[=[
		@function classifyError
		@within Raw
		@param raw unknown -- an error thrown by a Roblox service
		@return AdapterError
	]=]
	classifyError = Errors.classify,
	--[=[
		@function clock
		@within Raw
		@return Clock -- a clock on wall time and the task library
	]=]
	clock = RealClock.new,
}

--[=[
	@class Testing

	In-memory stand-ins for every Roblox service Geode uses, with fault injection and virtual
	time. Mock servers can share one universe to test cross-server behavior

	```lua
	local universe = Geode.Testing.universe()
	local server = universe:server()
	server:inject({ method = "update", fault = "throttle", times = 2 })
	```
]=]
local Testing = {
	--[=[
		@function universe
		@within Testing
		@param options UniverseOptions?
		@return Universe
	]=]
	universe = Universe.new,
	--[=[
		@function clock
		@within Testing
		@param start number?
		@return MockClock
	]=]
	clock = MockClock.new,
}

return {
	Raw = table.freeze(Raw),
	Testing = table.freeze(Testing),
}
