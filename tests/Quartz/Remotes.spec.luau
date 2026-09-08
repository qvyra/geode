--!strict

local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("mock remotes", function()
		it("deliver server messages to one client on the next step, as copies", function()
			local universe = Universe.new()
			local server = universe:server()
			server:join(1)
			server:join(2)
			local heard: { [number]: { any } } = { [1] = {}, [2] = {} }
			for userId = 1, 2 do
				server:client(userId).remote("Sync"):onEvent(function(message: any)
					table.insert(heard[userId], message)
				end)
			end
			local message = { coins = 5 }
			server.remote("Sync"):fire(1, message)
			message.coins = 99
			expect(#heard[1]).toBe(0)
			universe.clock:advance(0)
			expect(heard[1]).toEqual({ { coins = 5 } })
			expect(#heard[2]).toBe(0)
		end)

		it("tell the server which player sent a message", function()
			local universe = Universe.new()
			local server = universe:server()
			server:join(7)
			local senders = {}
			server.remote("Ops"):onEvent(function(userId: number, name: string)
				table.insert(senders, `{userId} {name}`)
			end)
			server:client(7).remote("Ops"):fire("buy")
			universe.clock:advance(0)
			expect(senders).toEqual({ "7 buy" })
		end)

		it("drop messages for players who aren't on the server", function()
			local universe = Universe.new()
			local server = universe:server()
			local heard = 0
			server:client(3).remote("Sync"):onEvent(function()
				heard += 1
			end)
			server.remote("Sync"):fire(3, "hello")
			universe.clock:advance(0)
			expect(heard).toBe(0)
		end)
	end)
end
