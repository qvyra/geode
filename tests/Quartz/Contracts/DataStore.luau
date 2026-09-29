--!strict

local Fixture = require("./Fixture")
local Spec = require("../../_lib/Spec")
local Types = require("../../../src/Quartz/Types")

local unwrap, errorKind = Fixture.unwrap, Fixture.errorKind

return function(spec: Spec.Api, label: string, make: Fixture.MakeFixture)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe(`DataStore contract ({label})`, function()
		it("reads nothing for a key never written", function()
			local fixture = make()
			local store = fixture.services.dataStore("Players")
			fixture.clock:run(function()
				local read = unwrap(store:get("missing"))
				expect(read.value).toBeNil()
				expect(read.info).toBeNil()
			end)
		end)

		it("reads back a copy of what was set, with key info", function()
			local fixture = make()
			local store = fixture.services.dataStore("Players")
			fixture.clock:run(function()
				local original = { coins = 10, items = { "sword" } }
				local version = unwrap(
					store:set(
						"p1",
						original,
						{ userIds = { 1 }, metadata = { tag = "a" } :: { [string]: unknown } }
					)
				)
				original.coins = 999

				local read = unwrap(store:get("p1"))
				expect(read.value).toEqual({ coins = 10, items = { "sword" } })
				expect(read.value == original).toBe(false)
				local info = read.info :: Types.KeyInfo
				expect(info.version).toBe(version)
				expect(info.userIds).toEqual({ 1 })
				expect(info.metadata).toEqual({ tag = "a" })
			end)
		end)

		it("keeps metadata when an update leaves it out", function()
			local fixture = make()
			local store = fixture.services.dataStore("Players")
			fixture.clock:run(function()
				unwrap(store:set("p1", 1, { metadata = { tag = "a" } :: { [string]: unknown } }))
				unwrap(store:update("p1", function(current: unknown)
					return (current :: number) + 1, { userIds = { 7 } }
				end))
				local info = unwrap(store:get("p1")).info :: Types.KeyInfo
				expect(info.metadata).toEqual({ tag = "a" })
				expect(info.userIds).toEqual({ 7 })
			end)
		end)

		it("updates against the latest value", function()
			local fixture = make()
			local store = fixture.services.dataStore("Players")
			fixture.clock:run(function()
				unwrap(store:set("p1", { coins = 1 }))
				local update = unwrap(store:update("p1", function(current)
					local data = current :: { coins: number }
					return { coins = data.coins + 5 }, { userIds = { 7 } }
				end))
				expect(update.cancelled).toBe(false)
				expect(update.value).toEqual({ coins = 6 })
				expect((update.info :: Types.KeyInfo).userIds).toEqual({ 7 })
				expect(unwrap(store:get("p1")).value).toEqual({ coins = 6 })
			end)
		end)

		it("cancels an update when the transform returns nil", function()
			local fixture = make()
			local store = fixture.services.dataStore("Players")
			fixture.clock:run(function()
				unwrap(store:set("p1", { coins = 1 }))
				local before = #unwrap(store:listVersions("p1"))
				local update = unwrap(store:update("p1", function()
					return nil
				end))
				expect(update.cancelled).toBe(true)
				expect(update.value).toEqual({ coins = 1 })
				expect(#unwrap(store:listVersions("p1"))).toBe(before)
			end)
		end)

		it("removes a key and returns what was there", function()
			local fixture = make()
			local store = fixture.services.dataStore("Players")
			fixture.clock:run(function()
				unwrap(store:set("p1", "hello"))
				expect(unwrap(store:remove("p1")).value).toBe("hello")
				expect(unwrap(store:get("p1")).value).toBeNil()
			end)
		end)

		it("increments from zero", function()
			local fixture = make()
			local store = fixture.services.dataStore("Counters")
			fixture.clock:run(function()
				expect(unwrap(store:increment("visits", 3))).toBe(3)
				expect(unwrap(store:increment("visits", 4))).toBe(7)
				expect(unwrap(store:get("visits")).value).toBe(7)
			end)
		end)

		it("lists versions in both directions and fetches old ones", function()
			local fixture = make()
			local store = fixture.services.dataStore("Players")
			fixture.clock:run(function()
				local first = unwrap(store:set("p1", 1))
				fixture.clock:wait(1)
				unwrap(store:set("p1", 2))
				fixture.clock:wait(1)
				unwrap(store:set("p1", 3))

				local ascending = unwrap(store:listVersions("p1"))
				expect(#ascending).toBe(3)
				expect(ascending[1].version).toBe(first)

				local descending: { Types.VersionInfo } =
					unwrap(store:listVersions("p1", { ascending = false, limit = 2 }))
				expect(#descending).toBe(2)
				expect(descending[1].createdTime >= descending[2].createdTime).toBe(true)

				expect(unwrap(store:getVersion("p1", first)).value).toBe(1)
			end)
		end)

		it("keeps scopes apart", function()
			local fixture = make()
			fixture.clock:run(function()
				unwrap(fixture.services.dataStore("Players", "live"):set("p1", "live"))
				unwrap(fixture.services.dataStore("Players", "test"):set("p1", "test"))
				expect(unwrap(fixture.services.dataStore("Players", "live"):get("p1")).value).toBe(
					"live"
				)
			end)
		end)

		it("rejects empty keys and values it can't store", function()
			local fixture = make()
			local store = fixture.services.dataStore("Players")
			fixture.clock:run(function()
				expect(errorKind(store:get(""))).toBe("invalidKey")
				expect(errorKind(store:set("p1", { fn = print }))).toBe("invalidValue")
			end)
		end)
	end)
end
