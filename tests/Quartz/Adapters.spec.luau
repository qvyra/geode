--!strict

-- Every contract runs twice: on the mocks, and on the real adapters wrapped around fake Roblox
-- objects. Both have to agree before the mocks count as stand-ins

local DataStoreContract = require("./Contracts/DataStore")
local FakeRoblox = require("./FakeRoblox")
local Fixture = require("./Contracts/Fixture")
local MemoryStoreContract = require("./Contracts/MemoryStore")
local MessagingContract = require("./Contracts/Messaging")
local OrderedDataStoreContract = require("./Contracts/OrderedDataStore")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")

local function mockFixture(): Fixture.Fixture
	local universe = Universe.new()
	return { services = universe:server(), clock = universe.clock }
end

local function realFixture(): Fixture.Fixture
	local universe = Universe.new()
	return { services = FakeRoblox.services(universe:server()), clock = universe.clock }
end

local CONTRACTS = {
	DataStoreContract,
	OrderedDataStoreContract,
	MemoryStoreContract,
	MessagingContract,
}

return function(spec: Spec.Api)
	for _, contract in CONTRACTS do
		contract(spec, "mock", mockFixture)
		contract(spec, "real adapter", realFixture)
	end
end
