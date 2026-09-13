--!strict

-- server to client replication, and client intent through remote ops

local RealServices = require("./Quartz/Real/Services")
local RemoteOps = require("@self/RemoteOps")
local Replicator = require("@self/Replicator")
local Types = require("./Quartz/Types")

local Prism = {}

-- one replicator per services table, so every store in a game shares one remote
local replicators: { [Types.Services]: Replicator.Replicator } = setmetatable({}, { __mode = "k" }) :: any

--[=[
	The replicator for `services`, made on first use. Live services when left out

	@within Geode
]=]
function Prism.replicator(
	services: Types.Services?,
	reportError: ((message: string) -> ())?
): Replicator.Replicator
	local resolved = services or RealServices.live()
	local existing = replicators[resolved]
	if existing then
		return existing
	end
	local made = Replicator.new(resolved, reportError)
	replicators[resolved] = made
	return made
end

--[=[
	Lets clients ask for a registered op on their own profile. See RemoteOps

	@within Geode
]=]
function Prism.remoteOp(name: string, options: RemoteOps.Options)
	RemoteOps.define(name, options)
end

Prism.onRemoteOp = RemoteOps.onRequest

return Prism
