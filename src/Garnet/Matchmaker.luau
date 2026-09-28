--!strict

-- Cross-server matchmaking. Tickets sit in a MemoryStore sorted map ordered by rating, and any
-- server can add or cancel them. One server per mode and region, elected with a lock, groups
-- them into matches each tick. Claims are atomic updates that only succeed on an unclaimed
-- ticket, so two matchers can never put the same player in two matches

local Premades = require("../Moonstone/Premades")
local RealServices = require("../Quartz/Real/Services")
local Registry = require("../Vein/Registry")
local Scheduler = require("../Quartz/Scheduler")
local Types = require("../Quartz/Types")

export type Band = {
	-- Rating gap allowed right away. Defaults to 100
	start: number?,
	-- How much the band grows each second a ticket waits. Defaults to 10
	widenPerSecond: number?,
	-- The widest it gets. Defaults to 1000
	max: number?,
}

export type Options = {
	name: string,
	placeId: number,
	-- Players per match. Parties count with all their members and are never split
	matchSize: number,
	mode: string?,
	region: string?,
	band: Band?,
	-- Seconds a ticket waits before it expires. Defaults to 300
	ticketTtl: number?,
	-- Seconds between matching passes, default 2
	tick: number?,
	-- Seconds the elected matcher's lock lasts without renewal. Defaults to 10
	lease: number?,
	-- One matcher per mode and region, on by default. Off lets every server match, which
	-- is still safe, just costs more
	elect: boolean?,
	onMatch: ((match: Match) -> ())?,
	services: Types.Services?,
	scheduler: Scheduler.Scheduler?,
	reportError: ((message: string) -> ())?,
}

export type Ticket = {
	id: string,
	players: { number },
	rating: number,
	createdAt: number,
	matchId: string?,
	reservedCode: string?,
	-- set by cancel. The ticket lingers for a second and must not be matched in that time
	cancelled: boolean?,
}

export type Match = {
	id: string,
	placeId: number,
	reservedCode: string,
	players: { number },
	tickets: { string },
}

export type Status = {
	state: "waiting" | "matched" | "gone",
	ticket: Ticket?,
}

type Fields = {
	name: string,
	mode: string,
	region: string,
	_services: Types.Services,
	_scheduler: Scheduler.Scheduler,
	_map: Types.SortedMap,
	_placeId: number,
	_matchSize: number,
	_band: { start: number, widenPerSecond: number, max: number },
	_ticketTtl: number,
	_tick: number,
	_elect: boolean,
	_mutex: Premades.Mutex,
	_lock: Premades.Lock?,
	_running: boolean,
	-- bumped on every start so a loop left over from a quick stop/start exits by itself
	_loop: number,
	_onMatch: ((match: Match) -> ())?,
	_report: (message: string) -> (),
	_handle: Registry.Handle,
}

local Matchmaker = {}
Matchmaker.__index = Matchmaker

export type Matchmaker = typeof(setmetatable({} :: Fields, Matchmaker))

-- GetRangeAsync max
local PAGE = 200
local MAX_PAGES = 5

--[=[
	Creates a matchmaker for one mode and region. Call `start` on every server that should take
	part in electing the matcher

	@within Matchmaker
	@param options MatchmakerOptions
	@return Matchmaker
]=]
function Matchmaker.new(options: Options): Matchmaker
	assert(type(options.name) == "string" and options.name ~= "", "a matchmaker needs a name")
	assert(
		options.matchSize >= 2 and options.matchSize % 1 == 0,
		"matchSize must be a whole number of at least 2"
	)
	local services = options.services or RealServices.live()
	local scheduler = options.scheduler
		or Scheduler.new({ clock = services.clock, budget = services.budget })
	local mode = options.mode or "default"
	local region = options.region or "global"
	local band: Band = options.band or {}
	local self = setmetatable(
		{
			name = options.name,
			mode = mode,
			region = region,
			_services = services,
			_scheduler = scheduler,
			_map = services.sortedMap(`geode_mm_{options.name}_{mode}_{region}`),
			_placeId = options.placeId,
			_matchSize = options.matchSize,
			_band = {
				start = band.start or 100,
				widenPerSecond = band.widenPerSecond or 10,
				max = band.max or 1000,
			},
			_ticketTtl = options.ticketTtl or 300,
			_tick = options.tick or 2,
			_elect = options.elect ~= false,
			_mutex = Premades.mutex(`matchmaker_{options.name}`, {
				services = services,
				scheduler = scheduler,
				lease = options.lease or 10,
			}),
			_lock = nil,
			_running = false,
			_loop = 0,
			_onMatch = options.onMatch,
			_report = options.reportError or function(message: string)
				warn(message)
			end,
			_handle = nil :: any,
		} :: Fields,
		Matchmaker
	)
	self._handle = Registry.register("matchmaker", `{options.name}/{mode}/{region}`, function()
		return { matcher = self:isMatcher() }
	end)
	return self
end

-- Tickets

--[=[
	Queues players as a single ticket and returns its id. A party is one ticket, so it always
	lands in the same match
]=]
function Matchmaker.enqueue(
	self: Matchmaker,
	players: { number },
	rating: number
): Types.Result<string>
	assert(
		#players >= 1 and #players <= self._matchSize,
		"a ticket holds between 1 and matchSize players"
	)
	local id = self._services.guid()
	local ticket: Ticket = {
		id = id,
		players = table.clone(players),
		rating = rating,
		createdAt = self._services.clock:now(),
		matchId = nil,
		reservedCode = nil,
	}
	local result = self._scheduler:submit({
		priority = "save",
		run = function()
			return self._map:set(id, ticket, self._ticketTtl, rating)
		end,
	})
	if not result.ok then
		return { ok = false, error = result.error }
	end
	return { ok = true, value = id }
end

--[=[
	Takes a ticket out of the queue. Returns false when it was already matched or gone
]=]
function Matchmaker.cancel(self: Matchmaker, ticketId: string): Types.Result<boolean>
	local cancelled = false
	local result = self._scheduler:submit({
		priority = "save",
		run = function()
			return self._map:update(ticketId, function(current: unknown, sortKey: Types.SortKey?)
				cancelled = false
				if type(current) ~= "table" or (current :: Ticket).matchId ~= nil then
					return nil, nil
				end
				cancelled = true
				-- Mark it and let it expire. Removing it now could race a claim
				-- that's already reading it, and the mark makes every claim refuse it
				local ticket = table.clone(current :: Ticket)
				ticket.cancelled = true
				return ticket, sortKey
			end, 1)
		end,
	})
	if not result.ok then
		return { ok = false, error = result.error }
	end
	return { ok = true, value = cancelled }
end

--[=[
	Where a ticket stands: still waiting, matched with a reserved server, or gone because it was
	cancelled or expired
]=]
function Matchmaker.status(self: Matchmaker, ticketId: string): Types.Result<Status>
	local result = self._scheduler:submit({
		priority = "read",
		run = function()
			return self._map:get(ticketId)
		end,
	})
	if not result.ok then
		return { ok = false, error = result.error }
	end
	local entry = result.value
	if entry == nil or type(entry.value) ~= "table" or (entry.value :: Ticket).cancelled then
		return { ok = true, value = { state = "gone", ticket = nil } }
	end
	local ticket = entry.value :: Ticket
	return {
		ok = true,
		value = { state = if ticket.matchId then "matched" else "waiting", ticket = ticket },
	}
end

--[=[
	Teleports this server's players from a matched ticket to their reserved server
]=]
function Matchmaker.teleport(
	self: Matchmaker,
	ticket: Ticket,
	players: { unknown }
): Types.Result<nil>
	assert(ticket.reservedCode, "the ticket isn't matched yet")
	return self._services.teleport:teleport(self._placeId, players, {
		reservedServerCode = ticket.reservedCode,
		data = { matchId = ticket.matchId },
	})
end

-- Matching

function Matchmaker._bandFor(self: Matchmaker, waited: number): number
	local band = self._band
	return math.min(band.start + band.widenPerSecond * math.max(0, waited), band.max)
end

-- Groups waiting tickets, lowest rating first. Each group fills a match exactly
function Matchmaker._groups(self: Matchmaker, tickets: { Ticket }): { { Ticket } }
	local now = self._services.clock:now()
	local used: { [string]: boolean } = {}
	local groups = {}
	for index, anchor in tickets do
		if used[anchor.id] then
			continue
		end
		local band = self:_bandFor(now - anchor.createdAt)
		local group = { anchor }
		local size = #anchor.players
		for other = index + 1, #tickets do
			if size == self._matchSize then
				break
			end
			local candidate = tickets[other]
			if candidate.rating - anchor.rating > band then
				break
			end
			if not used[candidate.id] and size + #candidate.players <= self._matchSize then
				table.insert(group, candidate)
				size += #candidate.players
			end
		end
		if size == self._matchSize then
			for _, ticket in group do
				used[ticket.id] = true
			end
			table.insert(groups, group)
		end
	end
	return groups
end

-- All or nothing: claims every ticket in the group for one match, or none
function Matchmaker._claim(
	self: Matchmaker,
	group: { Ticket },
	matchId: string,
	code: string
): boolean
	local claimed: { string } = {}
	local function setMatch(
		ticketId: string,
		expected: string?,
		matchValue: string?,
		codeValue: string?
	): boolean
		local changed = false
		local result = self._scheduler:submit({
			priority = "load",
			run = function()
				return self._map:update(
					ticketId,
					function(current: unknown, sortKey: Types.SortKey?)
						changed = false
						if
							type(current) ~= "table"
							or (current :: Ticket).matchId ~= expected
							or (current :: Ticket).cancelled
						then
							return nil, nil
						end
						local ticket = table.clone(current :: Ticket)
						ticket.matchId = matchValue
						ticket.reservedCode = codeValue
						changed = true
						return ticket, sortKey
					end,
					self._ticketTtl
				)
			end,
		})
		return result.ok and changed
	end

	for _, ticket in group do
		if setMatch(ticket.id, nil, matchId, code) then
			table.insert(claimed, ticket.id)
		else
			-- Lost one: someone else took it or it's gone. Give back what this pass claimed
			for _, ticketId in claimed do
				setMatch(ticketId, matchId, nil, nil)
			end
			return false
		end
	end
	return true
end

--[=[
	Runs one matching pass and returns the matches it made. The elected matcher runs this every
	tick, so call it directly only in tests or custom loops
]=]
function Matchmaker.runOnce(self: Matchmaker): { Match }
	-- Matched tickets linger until they expire, so page past them. The bound carries key and
	-- sortKey both: a key-only bound ranks as "no sort key" (found this in testing)
	local tickets: { Ticket } = {}
	local lower: Types.SortedBound? = nil
	for _ = 1, MAX_PAGES do
		local bound = lower
		local range = self._scheduler:submit({
			priority = "read",
			run = function()
				return self._map:getRange({ count = PAGE, lower = bound })
			end,
		})
		if not range.ok then
			self._report(`matchmaker {self.name} couldn't read its queue: {range.error.message}`)
			return {}
		end
		for _, entry in range.value do
			local ticket = entry.value
			if
				type(ticket) == "table"
				and (ticket :: Ticket).matchId == nil
				and not (ticket :: Ticket).cancelled
			then
				table.insert(tickets, ticket :: Ticket)
			end
		end
		local last = range.value[#range.value]
		if #range.value < PAGE or #tickets >= PAGE or last == nil then
			break
		end
		lower = { key = last.key, sortKey = last.sortKey }
	end

	local matches = {}
	for _, group in self:_groups(tickets) do
		local reserved = self._services.teleport:reserveServer(self._placeId)
		if not reserved.ok then
			self._report(
				`matchmaker {self.name} couldn't reserve a server: {reserved.error.message}`
			)
			break
		end
		local matchId = self._services.guid()
		if self:_claim(group, matchId, reserved.value.code) then
			local match: Match = {
				id = matchId,
				placeId = self._placeId,
				reservedCode = reserved.value.code,
				players = {},
				tickets = {},
			}
			for _, ticket in group do
				table.insert(match.tickets, ticket.id)
				for _, userId in ticket.players do
					table.insert(match.players, userId)
				end
			end
			table.insert(matches, match)
			local onMatch = self._onMatch
			if onMatch then
				local ok, err = pcall(function()
					onMatch(match)
				end)
				if not ok then
					self._report(`onMatch handler error: {tostring(err)}`)
				end
			end
		end
	end
	return matches
end

--// matcher loop

--[=[
	Whether this server is the elected matcher right now
]=]
function Matchmaker.isMatcher(self: Matchmaker): boolean
	if not self._elect then
		return self._running
	end
	local lock = self._lock
	return lock ~= nil and lock:isHeld()
end

-- True when this server should match this tick. Keeps the role or tries to take it
function Matchmaker._elected(self: Matchmaker): boolean
	if not self._elect then
		return true
	end
	local lock = self._lock
	if lock and lock:isHeld() and lock:renew() then
		return true
	end
	self._lock = nil
	local acquired = self._mutex:acquire(`{self.mode}:{self.region}`)
	if acquired.ok and acquired.value then
		self._lock = acquired.value
		return true
	end
	return false
end

--[=[
	Takes part in matching: tries to become the matcher every tick, and matches while it is.
	When the matcher's server dies, its lock runs out and another server takes over
]=]
function Matchmaker.start(self: Matchmaker)
	if self._running then
		return
	end
	self._running = true
	self._loop += 1
	local loop = self._loop
	local clock = self._services.clock
	clock:spawn(function()
		while self._running and self._loop == loop do
			if self:_elected() then
				self:runOnce()
			end
			clock:wait(self._tick)
		end
	end)
end

--[=[
	Stops taking part in matching and gives up the matcher lock if this server held it

	@within Matchmaker
]=]
function Matchmaker.stop(self: Matchmaker)
	self._running = false
	local lock = self._lock
	self._lock = nil
	if lock then
		self._services.clock:spawn(function()
			lock:release()
		end)
	end
end

--[=[
	Stops it and drops it from the registry that tooling reads

	@within Matchmaker
]=]
function Matchmaker.destroy(self: Matchmaker)
	self:stop()
	self._handle:unregister()
	self._mutex:destroy()
end

return Matchmaker
