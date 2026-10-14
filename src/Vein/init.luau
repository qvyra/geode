--!strict

-- What tooling reads: a registry of what's running and the telemetry bus

local Bridge = require("@self/Bridge")
local Bus = require("@self/Bus")
local Snapshot = require("@self/Snapshot")
local Types = require("./Quartz/Types")

export type ModuleReport = Snapshot.ModuleReport
export type Snapshot = Snapshot.Snapshot

--[=[
	@class Vein

	The registry of what's running right now, plus the telemetry bus. Meant for tooling
]=]
local Vein = {}

--[=[
	Everything running right now, with live details, plus the optional features nothing uses

	@within Vein
]=]
function Vein.snapshot(): Snapshot
	return Snapshot.take()
end

--[=[
	Calls back with every telemetry message from now on. Messages are frozen tables shaped
	`{ v, type, at, ... }`

	@within Vein
]=]
function Vein.subscribe(callback: (message: Bus.Message) -> ()): Types.Connection
	return Bus.subscribe(callback)
end

Vein.VERSION = Bus.VERSION

--[=[
	Turns the Studio bridge that development tools connect to on or off. It's on by default and
	only ever opens in a Studio playtest. Turning it off closes any bridge already open

	@within Vein
]=]
function Vein.setBridgeEnabled(on: boolean)
	Bridge.setEnabled(on)
end

return table.freeze(Vein)
