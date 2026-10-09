--!strict

-- Mocks store copies, never the caller's tables, just as a real service serializes the value
-- and hands back a fresh one. Anything a service can't store is refused here as well

local Values = {}

local function copyInto(value: unknown, path: string, seen: { [any]: boolean }): (boolean, unknown)
	local kind = type(value)
	if kind == "nil" or kind == "boolean" or kind == "number" or kind == "string" then
		return true, value
	end
	if kind ~= "table" then
		return false, `{path} is a {typeof(value)}, which can't be stored`
	end

	local source = value :: { [any]: unknown }
	if seen[source] then
		return false, `{path} is part of a cycle`
	end
	seen[source] = true

	local copy = {}
	for key, child in source do
		local ok, result = copyInto(child, `{path}.{tostring(key)}`, seen)
		if not ok then
			return false, result
		end
		copy[key] = result
	end

	seen[source] = nil
	return true, copy
end

-- deep copy. false + reason for functions, threads, userdata and cycles
function Values.copy(value: unknown): (boolean, unknown)
	return copyInto(value, "value", {})
end

function Values.clone(value: unknown): unknown
	local ok, result = Values.copy(value)
	assert(ok, result)
	return result
end

return Values
