--!strict

local Document = require("@self/Matrix/Document")
local Matrix = require("@self/Matrix")
local Guards = require("@self/Obsidian/Guards")
local Obsidian = require("@self/Obsidian")
local ObsidianIssues = require("@self/Obsidian/Issues")
local ObsidianSchema = require("@self/Obsidian/Schema")
local Quartz = require("@self/Quartz")
local QuartzTypes = require("@self/Quartz/Types")
local Scheduler = require("@self/Quartz/Scheduler")
local Transaction = require("@self/Matrix/Transaction")

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
export type Document = Document.Document
export type CommitRecord = Document.CommitRecord
export type TxResult = Document.TxResult
export type Transaction = Transaction.Transaction
export type Source = Transaction.Source
export type Guard = Guards.Guard
export type GuardSet = Guards.GuardSet
export type Violation = Guards.Violation

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

-- Raw gathers the low level pieces of every layer. Quartz can't see the layers above it, so
-- the table gets built here
local QuartzRaw = Quartz.Raw

--[=[
	@prop Raw Raw
	@within Geode
	@readonly
]=]
Geode.Raw = table.freeze({
	services = QuartzRaw.services,
	fromRoblox = QuartzRaw.fromRoblox,
	classifyError = QuartzRaw.classifyError,
	clock = QuartzRaw.clock,
	scheduler = QuartzRaw.scheduler,
	--[=[
		@function document
		@within Raw
		@param options DocumentOptions?
		@return Document -- in-memory state with the full transaction pipeline
	]=]
	document = Matrix.Document.new,
	--[=[
		@function guards
		@within Raw
		@param options GuardSetOptions?
		@return GuardSet -- attach it to a document as its last stage
	]=]
	guards = Obsidian.guardSet,
})

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

--[=[
	@prop guard guard
	@within Geode
	@readonly

	Guard builders: `Geode.guard.range("coins", { min = 0 })` and the rest
]=]
Geode.guard = Obsidian.guard

--[=[
	@function op
	@within Geode
	@param name string
	@param handler OpHandler

	Registers a custom op for the whole game. See Transaction.register
]=]
Geode.op = Matrix.Transaction.register

return table.freeze(Geode)
