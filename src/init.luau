--!strict

local Quartz = require("@self/Quartz")
local QuartzTypes = require("@self/Quartz/Types")
local Scheduler = require("@self/Quartz/Scheduler")

export type Services = QuartzTypes.Services
export type Clock = QuartzTypes.Clock
export type Result<T> = QuartzTypes.Result<T>
export type AdapterError = QuartzTypes.AdapterError
export type Scheduler = Scheduler.Scheduler
export type Priority = Scheduler.Priority

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

--[=[
	@prop Raw Raw
	@within Geode
	@readonly
]=]
Geode.Raw = Quartz.Raw

--[=[
	@prop Testing Testing
	@within Geode
	@readonly
]=]
Geode.Testing = Quartz.Testing

return table.freeze(Geode)
