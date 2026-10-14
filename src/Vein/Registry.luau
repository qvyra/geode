--!strict

-- What's running right now. Stores and premades register on create and unregister on
-- destroy, so tooling shows only what a game actually uses and reports idle when empty

export type Describe = () -> { [string]: unknown }

-- what tooling can read from a store beyond its details: open keys and the data under one
export type Tooling = {
	keys: () -> { string },
	inspect: (key: string) -> unknown,
}

export type Entry = {
	kind: string,
	name: string,
	describe: Describe?,
	tooling: Tooling?,
}

export type Handle = {
	unregister: (self: Handle) -> (),
}

local Bus = require("./Bus")

local Registry = {}

local entries: { Entry } = {}

-- `describe` runs whenever tooling asks for details, so it can report live numbers like an
-- estimated quota cost
function Registry.register(
	kind: string,
	name: string,
	describe: Describe?,
	tooling: Tooling?
): Handle
	local entry: Entry = { kind = kind, name = name, describe = describe, tooling = tooling }
	table.insert(entries, entry)
	Bus.publish("registered", { kind = kind, name = name })
	return {
		unregister = function(_self: Handle)
			local index = table.find(entries, entry)
			if index then
				table.remove(entries, index)
				Bus.publish("unregistered", { kind = kind, name = name })
			end
		end,
	}
end

function Registry.list(): { Entry }
	return table.clone(entries)
end

function Registry._reset()
	table.clear(entries)
end

return Registry
