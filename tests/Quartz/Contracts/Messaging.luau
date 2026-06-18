--!strict

local Fixture = require("./Fixture")
local Spec = require("../../_lib/Spec")

local unwrap = Fixture.unwrap

return function(spec: Spec.Api, label: string, make: Fixture.MakeFixture)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe(`Messaging contract ({label})`, function()
		it("delivers published data to subscribers with the send time", function()
			local fixture = make()
			local received = {}
			fixture.clock:run(function()
				unwrap(fixture.services.messaging:subscribe("release", function(data, sentAt)
					table.insert(received, { data = data, sentAt = sentAt })
				end))
				unwrap(fixture.services.messaging:publish("release", { key = "p1" }))
				fixture.clock:wait(1)
			end)
			expect(#received).toBe(1)
			expect(received[1].data).toEqual({ key = "p1" })
			expect(type(received[1].sentAt)).toBe("number")
		end)

		it("stops delivering after disconnect", function()
			local fixture = make()
			local count = 0
			fixture.clock:run(function()
				local connection = unwrap(fixture.services.messaging:subscribe("t", function()
					count += 1
				end))
				connection:disconnect()
				unwrap(fixture.services.messaging:publish("t", "x"))
				fixture.clock:wait(1)
			end)
			expect(count).toBe(0)
		end)
	end)

	describe(`Teleport contract ({label})`, function()
		it("reserves servers with distinct codes", function()
			local fixture = make()
			fixture.clock:run(function()
				local a = unwrap(fixture.services.teleport:reserveServer(10))
				local b = unwrap(fixture.services.teleport:reserveServer(10))
				expect(type(a.code)).toBe("string")
				expect(a.code == b.code).toBe(false)
				unwrap(
					fixture.services.teleport:teleport(
						10,
						{ "player" },
						{ reservedServerCode = a.code }
					)
				)
			end)
		end)
	end)
end
