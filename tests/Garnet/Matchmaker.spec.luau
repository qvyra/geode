--!strict

-- Matchmaking acceptance tests. The main one runs two matchers on the same queue at once and
-- checks that no player ever lands in two matches

local Fixture = require("../Quartz/Contracts/Fixture")
local Matchmaker = require("../../src/Garnet/Matchmaker")
local Spec = require("../_lib/Spec")
local Types = require("../../src/Quartz/Types")
local Universe = require("../../src/Quartz/Mock/Universe")

local unwrap = Fixture.unwrap

-- mock servers are full Services at runtime
local function services(server: Universe.MockServer): Types.Services
	return server :: any
end

local function make(server: Universe.MockServer, extra: { [string]: any }?): Matchmaker.Matchmaker
	local options: { [string]: any } = {
		name = "Arena",
		placeId = 99,
		matchSize = 4,
		services = services(server),
		reportError = function() end,
	}
	local overrides: { [string]: any } = extra or {}
	for key, value in overrides do
		options[key] = value
	end
	return Matchmaker.new(options :: any)
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("matchmaking", function()
		it("groups close ratings into full matches and reserves a server", function()
			local universe = Universe.new()
			local matches: { Matchmaker.Match } = {}
			local mm = make(universe:server(), {
				onMatch = function(match: Matchmaker.Match)
					table.insert(matches, match)
				end,
			})
			universe.clock:run(function()
				for userId = 1, 4 do
					unwrap(mm:enqueue({ userId }, 1000 + userId))
				end
				unwrap(mm:enqueue({ 5 }, 5000))
				mm:runOnce()
			end)
			expect(#matches).toBe(1)
			table.sort(matches[1].players)
			expect(matches[1].players).toEqual({ 1, 2, 3, 4 })
			expect(matches[1].reservedCode).never.toBeNil()
		end)

		it("keeps parties together and never splits them", function()
			local universe = Universe.new()
			local mm = make(universe:server())
			local made: { Matchmaker.Match } = {}
			universe.clock:run(function()
				unwrap(mm:enqueue({ 1, 2, 3 }, 1000))
				unwrap(mm:enqueue({ 4, 5 }, 1000))
				unwrap(mm:enqueue({ 6 }, 1010))
				made = mm:runOnce()
			end)
			expect(#made).toBe(1)
			table.sort(made[1].players)
			expect(made[1].players).toEqual({ 1, 2, 3, 6 })
		end)

		it("widens the band the longer tickets wait", function()
			local universe = Universe.new()
			local mm = make(universe:server(), {
				matchSize = 2,
				band = { start = 50, widenPerSecond = 10, max = 500 },
			})
			universe.clock:run(function()
				unwrap(mm:enqueue({ 1 }, 1000))
				unwrap(mm:enqueue({ 2 }, 1200))
				expect(#mm:runOnce()).toBe(0)
			end)
			universe.clock:advance(20)
			universe.clock:run(function()
				expect(#mm:runOnce()).toBe(1)
			end)
		end)

		it("reports status and lets the player's server teleport them", function()
			local universe = Universe.new()
			local server = universe:server()
			local mm = make(server, { matchSize = 2 })
			local ticketId = ""
			universe.clock:run(function()
				ticketId = unwrap(mm:enqueue({ 1 }, 1000))
				expect(unwrap(mm:status(ticketId)).state).toBe("waiting")
				unwrap(mm:enqueue({ 2 }, 1000))
				mm:runOnce()
				local status = unwrap(mm:status(ticketId))
				expect(status.state).toBe("matched")
				unwrap(mm:teleport(status.ticket :: Matchmaker.Ticket, { "player1" }))
			end)
			expect(#universe.teleports).toBe(1)
			expect(universe.teleports[1].placeId).toBe(99)
		end)

		it("cancels waiting tickets but not matched ones", function()
			local universe = Universe.new()
			local mm = make(universe:server(), { matchSize = 2 })
			universe.clock:run(function()
				local lonely = unwrap(mm:enqueue({ 1 }, 1000))
				expect(unwrap(mm:cancel(lonely))).toBe(true)
			end)
			universe.clock:advance(2)
			universe.clock:run(function()
				local a = unwrap(mm:enqueue({ 2 }, 1000))
				unwrap(mm:enqueue({ 3 }, 1000))
				expect(#mm:runOnce()).toBe(1)
				expect(unwrap(mm:cancel(a))).toBe(false)
			end)
		end)

		it("never claims the same player twice with two matchers running at once", function()
			local universe = Universe.new()
			local serverA = universe:server({ jobId = "A" })
			local serverB = universe:server({ jobId = "B" })
			local mmA = make(serverA, { elect = false, band = { start = 10000 } })
			local mmB = make(serverB, { elect = false, band = { start = 10000 } })
			-- Slow reads and claims, so both matchers read the same queue before either claims
			for _, server in { serverA, serverB } do
				server:inject({
					service = "sortedMap",
					method = "getRange",
					fault = { latency = 0.5 },
				})
				server:inject({
					service = "sortedMap",
					method = "update",
					fault = { latency = 0.1 },
				})
			end
			local matches: { Matchmaker.Match } = {}
			local nextUser = 0
			for round = 1, 10 do
				universe.clock:run(function()
					for _ = 1, 10 do
						nextUser += 1
						unwrap(mmA:enqueue({ nextUser }, 900 + (nextUser * 37) % 200))
					end
				end)
				-- both matchers race to claim the same queue
				-- index loop, iterating values loses the Matchmaker type
				local matchers = { mmA, mmB }
				for index = 1, #matchers do
					universe.clock:spawn(function()
						for _, match in matchers[index]:runOnce() do
							table.insert(matches, match)
						end
					end)
				end
				universe.clock:advance(round)
			end

			local seen: { [number]: number } = {}
			for _, match in matches do
				expect(#match.players).toBe(4)
				for _, userId in match.players do
					seen[userId] = (seen[userId] or 0) + 1
				end
			end
			local placed = 0
			for _, times in seen do
				expect(times).toBe(1)
				placed += 1
			end
			expect(placed > 0).toBe(true)
		end)

		it("elects one matcher and hands over when it dies", function()
			local universe = Universe.new()
			local serverA = universe:server({ jobId = "A" })
			local serverB = universe:server({ jobId = "B" })
			local mmA = make(serverA, { lease = 6, tick = 2 })
			local mmB = make(serverB, { lease = 6, tick = 2 })
			mmA:start()
			universe.clock:advance(1)
			mmB:start()
			universe.clock:advance(5)
			expect(mmA:isMatcher()).toBe(true)
			expect(mmB:isMatcher()).toBe(false)

			serverA:crash()
			universe.clock:advance(20)
			expect(mmB:isMatcher()).toBe(true)
			mmB:stop()
		end)
	end)
end
