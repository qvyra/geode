--!strict

local Document = require("@self/Matrix/Document")
local Matrix = require("@self/Matrix")
local Facet = require("@self/Facet")
local FacetTypes = require("@self/Facet/Facet")
local Guards = require("@self/Obsidian/Guards")
local Moonstone = require("@self/Moonstone")
local Obsidian = require("@self/Obsidian")
local Opal = require("@self/Opal")
local SharedStoreModule = require("@self/Opal/SharedStore")
local PlayerDataModule = require("@self/Polish/PlayerData")
local PlayerProfileModule = require("@self/Polish/PlayerProfile")
local Polish = require("@self/Polish")
local ObsidianIssues = require("@self/Obsidian/Issues")
local ObsidianSchema = require("@self/Obsidian/Schema")
local Quartz = require("@self/Quartz")
local QuartzTypes = require("@self/Quartz/Types")
local ProfileModule = require("@self/Sapphire/Profile")
local ProfileStore = require("@self/Sapphire/ProfileStore")
local Sapphire = require("@self/Sapphire")
local Scheduler = require("@self/Quartz/Scheduler")
local Transaction = require("@self/Matrix/Transaction")

export type Services = QuartzTypes.Services
export type PlayerData = PlayerDataModule.PlayerData
export type SharedStore = SharedStoreModule.SharedStore
export type SharedStoreOptions = SharedStoreModule.Options
export type PlayerDataOptions = PlayerDataModule.Options
export type PlayerProfile = PlayerProfileModule.PlayerProfile
export type SetupOptions = Polish.SetupOptions
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
export type Bundle = FacetTypes.Bundle
export type Reaction = FacetTypes.Reaction
export type Derived = FacetTypes.Derived
export type FacetSet = FacetTypes.FacetSet
export type Profile = ProfileModule.Profile
export type ProfileStore = ProfileStore.ProfileStore

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
	--[=[
		@function facets
		@within Raw
		@param options FacetSetOptions
		@return FacetSet -- attach it to a document before any guard set
	]=]
	facets = Facet.set,
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
	@function bundle
	@within Geode
	@param fields { PathLike }
	@param normalize (tx: Transaction) -> ()
	@param options BundleOptions?
	@return Bundle
]=]
Geode.bundle = Facet.bundle

--[=[
	@function react
	@within Geode
	@param deps { PathLike }
	@param run (tx: Transaction) -> ()
	@param options ReactionOptions
	@return Reaction
]=]
Geode.react = Facet.react

--[=[
	@function derive
	@within Geode
	@param name string
	@param deps { PathLike }
	@param compute (state: unknown) -> unknown
	@return Derived
]=]
Geode.derive = Facet.derive

--[=[
	@prop Profile Profile
	@within Geode
	@readonly

	Session locked player data: `Geode.Profile.store({ ... })`
]=]
Geode.Profile = Sapphire.Profile

--[=[
	@prop Shared Shared
	@within Geode
	@readonly

	Stores any server may write, with every write run through the pipeline inside UpdateAsync
]=]
Geode.Shared = Opal

--[=[
	@prop Ephemeral Ephemeral
	@within Geode
	@readonly

	MemoryStore hash maps, sorted maps and queues with validation and retries
]=]
Geode.Ephemeral = Moonstone.Ephemeral

--[=[
	@prop Presence Presence
	@within Geode
	@readonly

	Which server each player is on. `Geode.Presence.new(options)`
]=]
Geode.Presence = Moonstone.Presence

--[=[
	@prop Mutex Mutex
	@within Geode
	@readonly

	Locks shared by every server, with fencing tokens. `Geode.Mutex.new(name, options)`
]=]
Geode.Mutex = Moonstone.Mutex

--[=[
	@prop Counter Counter
	@within Geode
	@readonly

	Counters any server can change atomically. `Geode.Counter.new(name, options)`
]=]
Geode.Counter = Moonstone.Counter

--[=[
	@prop RateLimiter RateLimiter
	@within Geode
	@readonly

	Limits shared by every server. `Geode.RateLimiter.new(name, { limit, window })`
]=]
Geode.RateLimiter = Moonstone.RateLimiter

--[=[
	@prop JobQueue JobQueue
	@within Geode
	@readonly

	Jobs any server adds and one server at a time claims. `Geode.JobQueue.new(name, options)`
]=]
Geode.JobQueue = Moonstone.JobQueue

--[=[
	@function receipts
	@within Geode
	@param store ProfileStore
	@param handlers { [number]: ReceiptHandler }
	@param options ReceiptOptions?
	@return (info: ReceiptInfo) -> ProductPurchaseDecision

	Builds a ProcessReceipt callback. Each purchase is granted exactly once
]=]
Geode.receipts = Sapphire.receipts

--[=[
	@function erase
	@within Geode
	@param userId number
	@param services Services?
	@return EraseReport

	Erases a player's data from every profile store. Yields

	Live reads see the erasure right away. Older versions of each key stay readable for 30 days
	on Roblox's side and RemoveVersionAsync is deprecated, so those can't be purged early. A
	player who joins again starts over from the template
]=]
Geode.erase = Sapphire.erase

--[=[
	@function players
	@within Geode
	@param options PlayerDataOptions
	@return PlayerData

	Player data with joins, leaves, shutdown, session loss and purchases handled for you. See
	Polish
]=]
Geode.players = Polish.players

--[=[
	@function setup
	@within Geode
	@param options SetupOptions

	Sets the defaults every `Geode.players` store made afterwards starts from
]=]
Geode.setup = Polish.setup

--[=[
	@function op
	@within Geode
	@param name string
	@param handler OpHandler

	Registers a custom op for the whole game. See Transaction.register
]=]
Geode.op = Matrix.Transaction.register

return table.freeze(Geode)
