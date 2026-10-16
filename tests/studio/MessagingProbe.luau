--!strict

-- Settles whether MessagingService messages cross between a Studio playtest and other servers
-- of the same experience. Every participant subscribes to one topic, publishes its role every
-- few seconds and counts what it hears from each role. It only ever touches that topic
local MessagingService = game:GetService("MessagingService")

local Probe = {}

export type Result = {
	role: string,
	sent: number,
	failures: number,
	subscribed: boolean,
	heard: { [string]: number },
	-- unix seconds, so two sides' windows can be checked for overlap
	startedAt: number,
	endedAt: number,
	error: string?,
}

local PUBLISH_EVERY = 3

function Probe.run(topic: string, role: string, seconds: number): Result
	local result: Result = {
		role = role,
		sent = 0,
		failures = 0,
		subscribed = false,
		heard = {},
		startedAt = os.time(),
		endedAt = os.time(),
		error = nil,
	}
	local ok, connection = pcall(function()
		return MessagingService:SubscribeAsync(topic, function(message)
			local data = message.Data
			if type(data) == "table" and type(data.from) == "string" then
				result.heard[data.from] = (result.heard[data.from] or 0) + 1
			end
		end)
	end)
	if not ok then
		result.error = `subscribe failed: {tostring(connection)}`
		return result
	end
	result.subscribed = true
	local started = os.clock()
	while os.clock() - started < seconds do
		local published = pcall(function()
			MessagingService:PublishAsync(topic, { from = role })
		end)
		if published then
			result.sent += 1
		else
			result.failures += 1
		end
		task.wait(PUBLISH_EVERY)
	end
	-- give the last messages time to arrive
	task.wait(5)
	connection:Disconnect()
	result.endedAt = os.time()
	return result
end

return Probe
