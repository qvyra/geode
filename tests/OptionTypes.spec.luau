--!strict

-- Strict mode code passes options as table literals. These calls never run, they only have to
-- type check, so a change that breaks literal options fails the check suite

local Geode = require("../src")
local Spec = require("./_lib/Spec")

return function(spec: Spec.Api)
	spec.describe("public options", function()
		spec.it("accept plain literals in strict mode", function()
			local _ = function()
				Geode.players({
					name = "PlayerData",
					template = { coins = 0 },
					replicate = { coins = "owner", level = "public" },
					studio = "scope",
				})
				Geode.Profile.store({
					name = "Profiles",
					template = {},
					studio = "real",
					stealPolicy = "fail",
				})
				Geode.Shared.store({ name = "Guilds", template = {} })
				Geode.Ranked.windowed("Daily", { window = "daily", mode = "sum" })
				Geode.Matchmaker.new({ name = "Arena", placeId = 1, matchSize = 2 })
			end
		end)
	end)
end
