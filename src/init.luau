--!strict

local Obsidian = require("@self/Obsidian")
local ObsidianIssues = require("@self/Obsidian/Issues")
local ObsidianSchema = require("@self/Obsidian/Schema")
local Quartz = require("@self/Quartz")
local QuartzTypes = require("@self/Quartz/Types")
local Scheduler = require("@self/Quartz/Scheduler")

export type Services = QuartzTypes.Services
export type Clock = QuartzTypes.Clock
export type Result<T> = QuartzTypes.Result<T>
export type AdapterError = QuartzTypes.AdapterError
export type Scheduler = Scheduler.Scheduler
export type Priority = Scheduler.Priority
export type Schema = ObsidianSchema.Schema
export type Codec = ObsidianSchema.Codec
export type ValidationResult = ObsidianIssues.Result
export type Issue = ObsidianIssues.Issue

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

--[=[
	@prop t t
	@within Geode
	@readonly

	Schema builders: `Geode.t.number({ min = 0 })`, `Geode.t.struct({ ... })` and the rest
]=]
Geode.t = Obsidian.t

--[=[
	@prop codec CodecSet
	@within Geode
	@readonly

	Codecs for Roblox datatypes, usable anywhere a schema is
]=]
Geode.codec = Obsidian.codec

--[=[
	@prop schema Schema
	@within Geode
	@readonly
]=]
Geode.schema = Obsidian.schema

return table.freeze(Geode)
