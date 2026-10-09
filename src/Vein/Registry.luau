--!strict

-- What's running right now. Stores and premades register on create and unregister on
-- destroy, so tooling shows only what a game actually uses and reports idle when empty

export type Describe = () -> { [string]: unknown }

export type Entry = {
	kind: string,
	name: string,
	describe: Describe?,
}

export type Handle = {
	unregister: (self: Handle) -> (),
}

local Bus = require("./Bus")

local Registry = {}

local entries: { Entry } = {}

-- `describe` runs whenever tooling asks for details, so it can report live numbers like an
-- estimated quota cost
function Registry.register(kind: string, name: string, describe: Describe?): Handle
	local entry: Entry = { kind = kind, name = name, describe = describe }
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
