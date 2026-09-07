--!strict

-- The beginner layer. `Geode.players` gives player data with the lifecycle handled and
-- `Geode.setup` sets the defaults it starts from. Both stick to the public API below

local PlayerData = require("@self/PlayerData")
local ProfileStore = require("./Sapphire/ProfileStore")
local Receipts = require("./Sapphire/Receipts")
local RealServices = require("./Quartz/Real/Services")
local Scheduler = require("./Quartz/Scheduler")
local Types = require("./Quartz/Types")

export type SetupOptions = {
	-- services every store uses, live Roblox services by default
	services: Types.Services?,
	-- where data lives in Studio (see ProfileStore), "mock" by default
	studio: ProfileStore.StudioMode?,
	reportError: ((message: string) -> ())?,
}

type Defaults = {
	services: Types.Services?,
	scheduler: Scheduler.Scheduler?,
	studio: ProfileStore.StudioMode?,
	reportError: ((message: string) -> ())?,
}

local VISIBILITY: { [string]: boolean } = { private = true, owner = true, public = true }

local defaults: Defaults = {}
local storesMade = 0
local warnedLateSetup = false
local warnedReplicate = false
local receiptsSet = false

local Polish = {}

local function report(message: string)
	local handler = defaults.reportError
	if handler then
		handler(message)
	else
		warn(message)
	end
end

--[=[
	Sets the defaults that every `Geode.players` store made after this call starts from: the
	services, one shared scheduler, error reporting and the Studio mode. Options passed to a
	store still win. Call it once, before any store is made

	@within Geode
	@param options SetupOptions

	```lua
	Geode.setup({ studio = "scope" })
	```
]=]
function Polish.setup(options: SetupOptions)
	if storesMade > 0 and not warnedLateSetup then
		warnedLateSetup = true
		report(
			"Geode.setup was called after a store was made. Stores that already exist keep their old defaults"
		)
	end
	local services = options.services
	defaults = {
		services = services,
		scheduler = if services
			then Scheduler.new({ clock = services.clock, budget = services.budget })
			else nil,
		studio = options.studio,
		reportError = options.reportError,
	}
end

local function checkReplicate(
	replicate: { [string]: string }?,
	reportError: ((message: string) -> ())?
)
	if replicate == nil then
		return
	end
	for path, visibility in replicate do
		assert(type(path) == "string", "replicate is keyed by path")
		assert(
			VISIBILITY[visibility],
			`replicate.{path} must be "private", "owner" or "public", got {tostring(visibility)}`
		)
	end
	if not warnedReplicate then
		warnedReplicate = true
		local message =
			"the replicate option is checked but has no effect yet, replication isn't available"
		if reportError then
			reportError(message)
		else
			report(message)
		end
	end
end

--[=[
	Player data with the lifecycle handled. Each player's profile loads when they join and is
	released when they leave, shutdown releases everything, and purchases listed in `products`
	are granted exactly once. Every profile store option works here too, and the store itself is
	`PlayerData.store`

	Until a player's data loads, reads through `PlayerData:get(player)` return the template and
	writes are refused. Use `isLoaded`, `waitFor` or `onLoaded` to know when the real data is in

	@within Geode
	@param options PlayerDataOptions
	@return PlayerData

	```lua
	local PlayerData = Geode.players({
		name = "PlayerData",
		template = { coins = 0, xp = 0, level = 1, inventory = {} },
	})

	PlayerData:onLoaded(function(player, profile)
		profile:increment("coins", 100)
	end)
	```
]=]
function Polish.players(options: PlayerData.Options): PlayerData.PlayerData
	local reportError = options.reportError or defaults.reportError
	checkReplicate(options.replicate, reportError)
	local services = options.services or defaults.services or RealServices.live()

	-- everything the profile store understands passes through untouched. Options is an
	-- intersection type, which Luau won't cast to a plain table directly
	local storeOptions = table.clone(options :: any) :: { [string]: unknown }
	storeOptions.products = nil
	storeOptions.replicate = nil
	storeOptions.loadRetries = nil
	storeOptions.decisions = nil
	storeOptions.services = services
	storeOptions.reportError = reportError
	storeOptions.scheduler = options.scheduler
		or (if services == defaults.services then defaults.scheduler else nil)
	storeOptions.studio = options.studio or defaults.studio
	local store = ProfileStore.new(storeOptions :: any)
	storesMade += 1

	local playerData = PlayerData.new(store, services, options.template, {
		loadRetries = options.loadRetries,
		report = reportError or report,
	})

	local products = options.products
	if products then
		assert(
			not receiptsSet,
			"only one Geode.players store can take products, a game has one ProcessReceipt"
		)
		receiptsSet = true
		local process = Receipts.build(
			store,
			products,
			{ reportError = reportError, decisions = options.decisions }
		)
		services.marketplace:setProcessReceipt(function(info: unknown): unknown
			return process(info :: Receipts.ReceiptInfo)
		end)
	end
	return playerData
end

-- reset module state, tests only
function Polish._reset()
	defaults = {}
	storesMade = 0
	warnedLateSetup = false
	warnedReplicate = false
	receiptsSet = false
end

return Polish
