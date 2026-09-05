--!strict

local Leaderboard = require("@self/Leaderboard")

return table.freeze({
	allTime = Leaderboard.allTime,
	windowed = Leaderboard.windowed,
})
