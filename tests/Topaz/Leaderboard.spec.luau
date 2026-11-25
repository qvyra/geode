--!strict

local Fixture = require("../Quartz/Contracts/Fixture")
local Leaderboard = require("../../src/Topaz/Leaderboard")
local MockClock = require("../../src/Quartz/Mock/Clock")
local Polish = require("../../src/Polish")
local Spec = require("../_lib/Spec")
local Types = require("../../src/Quartz/Types")
local Universe = require("../../src/Quartz/Mock/Universe")

local unwrap = Fixture.unwrap

local DAY = 86400

-- Mock servers are full Services at runtime. Cast once here so options tables type check
local function services(server: Universe.MockServer): Types.Services
	return server :: any
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("all-time boards", function()
		it("keep the best score in max mode and rank it", function()
			local universe = Universe.new()
			local board = Leaderboard.allTime("Wins", { services = services(universe:server()) })
			universe.clock:run(function()
				unwrap(board:submit(1, 50))
				unwrap(board:submit(1, 30))
				unwrap(board:submit(2, 70))
				unwrap(board:submit(3, 10))
				expect(unwrap(board:get(1))).toBe(50)
				local top = unwrap(board:top(2))
				expect(top).toEqual({ { userId = 2, score = 70 }, { userId = 1, score = 50 } })
			end)
		end)

		it("add up in sum mode and keep the lowest in min mode", function()
			local universe = Universe.new()
			local server = services(universe:server())
			local kills = Leaderboard.allTime("Kills", { services = server, mode = "sum" })
			local times = Leaderboard.allTime("Times", { services = server, mode = "min" })
			universe.clock:run(function()
				unwrap(kills:submit(1, 3))
				unwrap(kills:submit(1, 4))
				expect(unwrap(kills:get(1))).toBe(7)
				unwrap(times:submit(1, 90))
				unwrap(times:submit(1, 80))
				unwrap(times:submit(2, 120))
				expect(unwrap(times:top(1))).toEqual({ { userId = 1, score = 80 } })
			end)
		end)

		it("serve top lists from cache for a while", function()
			local universe = Universe.new()
			local board = Leaderboard.allTime(
				"Wins",
				{ services = services(universe:server()), cacheTtl = 30 }
			)
			universe.clock:run(function()
				unwrap(board:submit(1, 5))
				expect(#unwrap(board:top(10))).toBe(1)
				unwrap(board:submit(2, 9))
				expect(#unwrap(board:top(10))).toBe(1)
			end)
			universe.clock:advance(30)
			universe.clock:run(function()
				expect(#unwrap(board:top(10))).toBe(2)
			end)
		end)
	end)

	describe("windowed boards", function()
		it("start over each UTC day", function()
			local clock = MockClock.new()
			clock:advance(10 * DAY + 3600)
			local universe = Universe.new({ clock = clock })
			local board = Leaderboard.windowed(
				"Daily",
				{
					services = services(universe:server()),
					window = "daily",
					cacheTtl = 0,
				} :: Leaderboard.WindowedOptions
			)
			universe.clock:run(function()
				unwrap(board:submit(1, 40))
				unwrap(board:submit(2, 60, "latest"))
				expect(unwrap(board:top(5))[1]).toEqual({ userId = 2, score = 60 })
			end)
			local yesterday = board:windowIndex()
			-- Ten minutes into the next day, inside the one hour grace period
			universe.clock:advance(DAY - 3600 + 600)
			universe.clock:run(function()
				expect(#unwrap(board:top(5))).toBe(0)
				unwrap(board:submit(1, 5, "sum"))
				unwrap(board:submit(1, 5, "sum"))
				expect(unwrap(board:get(1))).toBe(10)
				expect(#unwrap(board:top(5, yesterday))).toBe(2)
			end)
		end)

		it("put week boundaries on Monday", function()
			local universe = Universe.new()
			local board = Leaderboard.windowed(
				"Weekly",
				{
					services = services(universe:server()),
					window = "weekly",
				} :: Leaderboard.WindowedOptions
			)
			-- 1970-01-05 was a Monday, four days after the epoch
			local sunday = 3 * DAY + 3600
			local monday = 4 * DAY + 60
			expect(board:windowIndex(monday) - board:windowIndex(sunday)).toBe(1)
			expect(board:windowIndex(monday + 6 * DAY)).toBe(board:windowIndex(monday))
		end)

		it("expire a grace period after the window closes", function()
			local universe = Universe.new()
			local board = Leaderboard.windowed(
				"Hourly",
				{
					services = services(universe:server()),
					window = 3600,
					grace = 600,
					cacheTtl = 0,
				} :: Leaderboard.WindowedOptions
			)
			local index = board:windowIndex()
			universe.clock:run(function()
				unwrap(board:submit(1, 1))
			end)
			universe.clock:advance(3600 + 601)
			universe.clock:run(function()
				expect(#unwrap(board:top(5, index))).toBe(0)
			end)
		end)
	end)

	describe("removing a player", function()
		it("takes their key off an all-time board and drops cached tops", function()
			local universe = Universe.new()
			local board = Leaderboard.allTime("Wins", { services = services(universe:server()) })
			universe.clock:run(function()
				unwrap(board:submit(1, 50))
				unwrap(board:submit(2, 30))
				expect(#unwrap(board:top(5))).toBe(2)
				unwrap(board:remove(1))
				expect(unwrap(board:get(1))).toBeNil()
				expect(unwrap(board:top(5))).toEqual({ { userId = 2, score = 30 } })
			end)
		end)

		it("clears the current window and every earlier one still kept", function()
			local clock = MockClock.new()
			clock:advance(10 * DAY + 3600)
			local universe = Universe.new({ clock = clock })
			local board = Leaderboard.windowed("Daily", {
				services = services(universe:server()),
				window = "daily",
				grace = 2 * DAY,
			})
			local indexes = {}
			for _ = 1, 4 do
				universe.clock:run(function()
					table.insert(indexes, board:windowIndex())
					unwrap(board:submit(1, 10))
					unwrap(board:submit(2, 20))
				end)
				universe.clock:advance(DAY)
			end
			-- windows from three and four days back closed more than the grace ago, and expired
			universe.clock:run(function()
				local current = board:windowIndex()
				unwrap(board:remove(1))
				for _, index in indexes do
					local top = unwrap(board:top(5, index))
					if index >= current - 2 then
						expect(top).toEqual({ { userId = 2, score = 20 } })
					else
						expect(#top).toBe(0)
					end
				end
			end)
		end)

		it("reports a failed removal", function()
			local universe = Universe.new()
			local server = universe:server()
			local board = Leaderboard.allTime("Wins", { services = services(server) })
			server:inject({
				service = "orderedDataStore",
				method = "remove",
				fault = { code = 105 },
			})
			universe.clock:run(function()
				local result = board:remove(1)
				expect(result.ok).toBe(false)
			end)
		end)
	end)

	describe("scopes", function()
		local function opened(universe: Universe.Universe, kind: string): { [string]: boolean }
			local found = {}
			for id in (universe :: any)._shared[kind] do
				found[id] = true
			end
			return found
		end

		it("keep boards with the same name apart", function()
			Polish._reset()
			local universe = Universe.new()
			local server = services(universe:server())
			local live = Leaderboard.allTime("Wins", { services = server })
			local season = Leaderboard.allTime("Wins", { services = server, scope = "season2" })
			expect(live.scope).toBe("global")
			expect(season.scope).toBe("season2")
			universe.clock:run(function()
				unwrap(live:submit(1, 5))
				unwrap(season:submit(1, 9))
				expect(unwrap(live:get(1))).toBe(5)
				expect(unwrap(season:get(1))).toBe(9)
			end)
			local stores = opened(universe, "orderedDataStores")
			expect(stores["Wins\0global"]).toBe(true)
			expect(stores["Wins\0season2"]).toBe(true)
		end)

		it("put the scope and its length in windowed map names", function()
			Polish._reset()
			local universe = Universe.new()
			local server = services(universe:server())
			local live = Leaderboard.windowed("Daily", { services = server, window = "daily" })
			local season = Leaderboard.windowed(
				"Daily",
				{ services = server, window = "daily", scope = "s_2" }
			)
			-- the same letters split the other way round, which a plain join would collide with
			local other = Leaderboard.windowed(
				"2_Daily",
				{ services = server, window = "daily", scope = "s" }
			)
			universe.clock:run(function()
				unwrap(live:submit(1, 5))
				unwrap(season:submit(1, 9))
				unwrap(other:submit(1, 3))
				expect(unwrap(live:get(1))).toBe(5)
				expect(unwrap(season:get(1))).toBe(9)
				expect(unwrap(other:get(1))).toBe(3)
			end)
			local index = live:windowIndex()
			local maps = opened(universe, "sortedMaps")
			expect(maps[`geode_rank_Daily_{index}`]).toBe(true)
			expect(maps[`geode_rank3_s_2_Daily_{index}`]).toBe(true)
			expect(maps[`geode_rank1_s_2_Daily_{index}`]).toBe(true)
		end)

		it("follow Geode.setup's scope unless given their own", function()
			Polish._reset()
			Polish.setup({ scope = "test" })
			local universe = Universe.new()
			local server = services(universe:server())
			expect(Leaderboard.allTime("Wins", { services = server }).scope).toBe("test")
			expect(Leaderboard.allTime("Wins", { services = server, scope = "x" }).scope).toBe("x")
			Polish._reset()
		end)

		it("refuse an empty scope", function()
			local server = services(Universe.new():server())
			expect(function()
				Leaderboard.allTime("Wins", { services = server, scope = "" })
			end).toThrow("scope must be")
		end)
	end)
end
