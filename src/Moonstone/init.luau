--!strict

-- MemoryStore wrappers and the premades built on them

local Ephemeral = require("@self/Ephemeral")
local Premades = require("@self/Premades")

return table.freeze({
	Ephemeral = table.freeze({
		hashMap = Ephemeral.hashMap,
		sortedMap = Ephemeral.sortedMap,
		queue = Ephemeral.queue,
	}),
	Presence = table.freeze({ new = Premades.presence }),
	Mutex = table.freeze({ new = Premades.mutex }),
	Counter = table.freeze({ new = Premades.counter }),
	RateLimiter = table.freeze({ new = Premades.rateLimiter }),
	JobQueue = table.freeze({ new = Premades.jobQueue }),
})
