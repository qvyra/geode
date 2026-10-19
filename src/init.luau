--!strict

local Document = require("@self/Matrix/Document")
local Matrix = require("@self/Matrix")
local Facet = require("@self/Facet")
local FacetTypes = require("@self/Facet/Facet")
local Garnet = require("@self/Garnet")
local Guards = require("@self/Obsidian/Guards")
local Moonstone = require("@self/Moonstone")
local Obsidian = require("@self/Obsidian")
local Opal = require("@self/Opal")
local SharedStoreModule = require("@self/Opal/SharedStore")
local PlayerDataModule = require("@self/Polish/PlayerData")
local PlayerProfileModule = require("@self/Polish/PlayerProfile")
local Polish = require("@self/Polish")
local GeodeClient = require("@self/Client")
local Prism = require("@self/Prism")
local Vein = require("@self/Vein")
local ObsidianIssues = require("@self/Obsidian/Issues")
local ObsidianSchema = require("@self/Obsidian/Schema")
local Quartz = require("@self/Quartz")
local QuartzTypes = require("@self/Quartz/Types")
local ProfileModule = require("@self/Sapphire/Profile")
local ProfileStore = require("@self/Sapphire/ProfileStore")
local Record = require("@self/Sapphire/Record")
local Sapphire = require("@self/Sapphire")
local Scheduler = require("@self/Quartz/Scheduler")
local Topaz = require("@self/Topaz")
local Transaction = require("@self/Matrix/Transaction")
local Version = require("@self/Version")

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
Geode.version = Version

-- Raw gathers the low level pieces of every layer. Quartz can't see the layers above it, so
-- the table gets built here
local QuartzRaw = Quartz.Raw

--[=[
	@prop Raw Raw
	@within Geode
	@readonly
]=]
--[=[
	@function document
	@within Raw
	@param options DocumentOptions?
	@return Document -- in-memory state with the full transaction pipeline
]=]
--[=[
	@function guards
	@within Raw
	@param options GuardSetOptions?
	@return GuardSet -- attach it to a document as its last stage
]=]
--[=[
	@function facets
	@within Raw
	@param options FacetSetOptions
	@return FacetSet -- attach it to a document before any guard set
]=]
--[=[
	@function externalWrite
	@within Raw
	@param stored unknown -- the record as read from the DataStore, decoded from JSON
	@param data unknown -- the new data, in stored form
	@param options { now: number, id: string } -- Unix seconds, and an id fresh for this write
	@return { data: unknown, meta: { [string]: unknown } } -- the record to write back

	For tools that edit a stored profile or shared record directly in the DataStore, outside a
	running Geode. Returns a copy of `stored` the way such a write has to leave it: the new data,
	`meta.revision` one higher, `meta.lastSession` set to `"external:" .. id` with the new
	revision, and `meta.updatedAt` set to `now`. The rest of `meta`, the lease and the format
	included, stays as it was. Errors when `stored` isn't a Geode record

	A server whose release already landed would otherwise take a profile back and write over the
	edit, and shared store caches only take values with a newer revision. A server that still
	holds the lease writes over an external edit on its next save, so edit records with no lease

	```lua
	local HttpService = game:GetService("HttpService")

	local stored = { data = { coins = 5 }, meta = { schemaVersion = 1, revision = 7 } }
	local written = Geode.Raw.externalWrite(stored, { coins = 50 }, {
		now = DateTime.now().UnixTimestampMillis / 1000,
		id = HttpService:GenerateGUID(false),
	})
	print(written.meta.revision) -- 8
	```
]=]
--[=[
	@prop recordFormat number
	@within Raw
	@readonly

	The layout Geode writes into `meta.format` of profile and shared records. Records without
	`meta.format` were written by 0.4.0 to 0.5.0
]=]
Geode.Raw = table.freeze({
	services = QuartzRaw.services,
	fromRoblox = QuartzRaw.fromRoblox,
	classifyError = QuartzRaw.classifyError,
	clock = QuartzRaw.clock,
	scheduler = QuartzRaw.scheduler,
	document = Matrix.Document.new,
	guards = Obsidian.guardSet,
	facets = Facet.set,
	externalWrite = Record.externalWrite,
	recordFormat = Record.FORMAT,
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

Geode.bundle = Facet.bundle

Geode.react = Facet.react

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
	@prop Matchmaker Matchmaker
	@within Geode
	@readonly

	Matchmaking across servers. `Geode.Matchmaker.new(options)`
]=]
Geode.Matchmaker = Garnet

--[=[
	@prop Ranked Ranked
	@within Geode
	@readonly

	Leaderboards. `Geode.Ranked.allTime(name, options)` and `Geode.Ranked.windowed(name, options)`
]=]
Geode.Ranked = Topaz

Geode.replicator = Prism.replicator

Geode.remoteOp = Prism.remoteOp

--[=[
	@prop Client GeodeClient
	@within Geode
	@readonly

	The client side: `Geode.Client.start()` on a LocalScript gives atoms of the shared data
]=]
Geode.Client = GeodeClient

--[=[
	@prop Vein Vein
	@within Geode
	@readonly

	Registry of what's running plus the telemetry bus, for tooling
]=]
Geode.Vein = Vein

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

Geode.players = Polish.players

Geode.setup = Polish.setup

Geode.op = Matrix.Transaction.register

return table.freeze(Geode)
