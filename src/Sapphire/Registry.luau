--!strict

-- Every store created on this server that holds data by user id, so erasure can reach all of
-- them: profile stores, boards, and shared stores that said how to find a player's key

-- self is `any`: the stores require this module, so their types can't be named here
export type Erasable = {
	name: string,
	-- `skipped` when the store holds nothing for this player
	_eraseUser: (self: any, userId: number) -> { ok: boolean, message: string?, skipped: boolean? },
}

export type Kind = "profile" | "shared" | "board"

local Registry = {}

type Entry = {
	store: Erasable,
	kind: Kind,
	-- The services the store was created with, before any Studio substitution
	services: unknown,
}

-- stores live as long as the game, plain references are fine. A destroyed store stays, since
-- its data is still saved
local entries: { Entry } = {}

function Registry.add(store: Erasable, services: unknown, kind: Kind?)
	table.insert(entries, { store = store, kind = kind or "profile", services = services })
end

function Registry.all(services: unknown?): { Erasable }
	local found = {}
	for _, entry in entries do
		if services == nil or entry.services == services then
			table.insert(found, entry.store)
		end
	end
	return found
end

export type StoreReport = {
	store: string,
	kind: Kind,
	ok: boolean,
	message: string?,
}

export type EraseReport = {
	-- how many stores erased something
	erased: number,
	failures: { { store: string, kind: Kind, message: string } },
	-- one entry per store that held something for the player, in the order they were made
	stores: { StoreReport },
}

-- Erases a player's data from every store on this server that keeps data by user id. Yields.
-- A server elsewhere that still holds one of the profiles loses its session on its next save
-- instead of writing the data back
--
-- Live reads see the erasure at once. Roblox's docs say versioned backups "expire 30 days after
-- a new write overwrites them", and mark RemoveVersionAsync deprecated without naming anything
-- in its place, so older versions can't be dropped sooner. A player who joins again starts over
-- from the template
function Registry.erase(userId: number, services: unknown?): EraseReport
	local report: EraseReport = { erased = 0, failures = {}, stores = {} }
	for _, entry in entries do
		if services ~= nil and entry.services ~= services then
			continue
		end
		local store = entry.store
		local result = store:_eraseUser(userId)
		if result.skipped then
			continue
		end
		table.insert(report.stores, {
			store = store.name,
			kind = entry.kind,
			ok = result.ok,
			message = result.message,
		})
		if result.ok then
			report.erased += 1
		else
			table.insert(report.failures, {
				store = store.name,
				kind = entry.kind,
				message = result.message or "unknown error",
			})
		end
	end
	return report
end

return Registry
