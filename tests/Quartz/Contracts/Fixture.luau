--!strict

-- What every contract suite needs: services to test and the clock that drives them. Contracts
-- only touch `services`, so the same suite can later run against real services in Studio

local MockClock = require("../../../src/Quartz/Mock/Clock")
local Types = require("../../../src/Quartz/Types")

export type Fixture = {
	services: Types.Services,
	clock: MockClock.MockClock,
}

export type MakeFixture = () -> Fixture

local Fixture = {}

--[=[
	Unwraps an ok result, or fails the test with the adapter's error
]=]
function Fixture.unwrap<T>(result: Types.Result<T>): T
	if not result.ok then
		error(`expected ok, got {result.error.kind}: {result.error.message}`, 2)
	end
	return result.value
end

--[=[
	Error kind of a failed result, nil when it succeeded
]=]
function Fixture.errorKind<T>(result: Types.Result<T>): Types.ErrorKind?
	if result.ok then
		return nil
	end
	return result.error.kind
end

return Fixture
