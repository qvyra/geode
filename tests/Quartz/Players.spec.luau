--!strict

local FakeRoblox = require("./FakeRoblox")
local Spec = require("../_lib/Spec")
local Types = require("../../src/Quartz/Types")
local Universe = require("../../src/Quartz/Mock/Universe")

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	local function suite(label: string, servicesOf: (server: Universe.MockServer) -> Types.Services)
		describe(`players and purchases ({label})`, function()
			it("reports joins and leaves to handlers", function()
				local universe = Universe.new()
				local server = universe:server()
				local services = servicesOf(server)
				local events = {}
				services.players:onJoin(function(userId: number)
					table.insert(events, `join {userId}`)
				end)
				local connection = services.players:onLeave(function(userId: number)
					table.insert(events, `leave {userId}`)
				end)
				server:join(1)
				server:join(2)
				server:leave(1)
				universe.clock:advance(0)
				expect(events).toEqual({ "join 1", "join 2", "leave 1" })

				connection:disconnect()
				server:leave(2)
				universe.clock:advance(0)
				expect(#events).toBe(3)
			end)

			it("lists who is on the server", function()
				local universe = Universe.new()
				local server = universe:server()
				local services = servicesOf(server)
				server:join(7)
				server:join(3)
				local ids = {}
				for _, entry in services.players:list() do
					table.insert(ids, entry.userId)
				end
				expect(ids).toEqual({ 7, 3 })
			end)

			it("routes purchases to the receipt callback", function()
				local universe = Universe.new()
				local server = universe:server()
				local services = servicesOf(server)
				services.marketplace:setProcessReceipt(function(info: any)
					return `granted {info.PurchaseId}`
				end)
				expect(server:purchase({ PurchaseId = "p1" })).toBe("granted p1")
			end)
		end)
	end

	suite("mock", function(server)
		return server
	end)
	suite("real over fakes", FakeRoblox.services)

	describe("mock players", function()
		it("makes a kicked player leave", function()
			local universe = Universe.new()
			local server = universe:server()
			server:join(4)
			server.players:kick(4, "bye")
			expect(server.players:isPresent(4)).toBe(false)
			expect(universe.kicks[1].reason).toBe("bye")
		end)
	end)
end
