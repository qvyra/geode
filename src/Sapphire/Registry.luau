--!strict

-- Every profile store created on this server, so erasure can reach all of them by user id

-- self is `any`: ProfileStore requires this module, so its type can't be named here
export type Erasable = {
	name: string,
	keyForUser: (self: any, userId: number) -> string,
	erase: (self: any, key: string) -> { ok: boolean, message: string? },
}

local Registry = {}

type Entry = {
	store: Erasable,
	-- The services the store was created with, before any Studio substitution
	services: unknown,
}

-- stores live as long as the game, plain references are fine
local entries: { Entry } = {}

function Registry.add(store: Erasable, services: unknown)
	table.insert(entries, { store = store, services = services })
end

--[=[
	Registered stores, all of them or only those created with `services`
]=]
function Registry.all(services: unknown?): { Erasable }
	local found = {}
	for _, entry in entries do
		if services == nil or entry.services == services then
			table.insert(found, entry.store)
		end
	end
	return found
end

export type EraseReport = {
	erased: number,
	failures: { { store: string, message: string } },
}

--[=[
	Erases a player's data from every profile store on this server. Yields. A server elsewhere that
	still holds one of the profiles loses its session on its next save instead of writing the data
	back

	@within Geode
	@param userId number
	@param services Services? -- only stores created with these services. All stores when nil
	@return EraseReport
]=]
function Registry.erase(userId: number, services: unknown?): EraseReport
	local report: EraseReport = { erased = 0, failures = {} }
	for _, store in Registry.all(services) do
		local result = store:erase(store:keyForUser(userId))
		if result.ok then
			report.erased += 1
		else
			table.insert(
				report.failures,
				{ store = store.name, message = result.message or "unknown error" }
			)
		end
	end
	return report
end

return Registry
