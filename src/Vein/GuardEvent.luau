--!strict

-- Builds the guardBroken telemetry message. Only runs when the bus has a listener, since
-- encoding the before and after values isn't free

local Bus = require("./Bus")
local Guards = require("../Obsidian/Guards")
local Path = require("../Matrix/Path")
local Schema = require("../Obsidian/Schema")
local Types = require("../Quartz/Types")
local Validate = require("../Obsidian/Validate")

local GuardEvent = {}

-- Encoded size past which a before or after value is left out of the message
GuardEvent.MAX_VALUE_SIZE = 1024

-- The value in stored form, or nil and its encoded size when it's too big to send
local function stored(
	value: unknown,
	path: Path.Path?,
	schema: Schema.Schema?,
	json: Types.Json
): (unknown, number?)
	if value == nil then
		return nil, nil
	end
	local form = value
	if schema and path then
		local node, depth = Validate.at(schema, path)
		-- A value that breaks the schema goes out as it is, encoding it could produce garbage
		if node and depth == #path and Validate.validate(node, value).ok then
			local ok, encoded = pcall(Validate.encode, node, value)
			form = if ok then encoded else nil
		end
	end
	local ok, text = pcall(json.encode, json, form)
	if not ok then
		return nil, nil
	end
	if #text > GuardEvent.MAX_VALUE_SIZE then
		return nil, #text
	end
	return form, nil
end

-- `violation` as plain data a Bindable can carry, values in stored form
function GuardEvent.describe(
	violation: Guards.Violation,
	schema: Schema.Schema?,
	json: Types.Json
): { [string]: unknown }
	local path = if violation.path then Path.parseFormatted(violation.path) else nil
	if path and violation.kind == "schema" and path[1] == "data" then
		table.remove(path, 1)
	end
	local before, beforeSize = stored(violation.before, path, schema, json)
	local after, afterSize = stored(violation.after, path, schema, json)
	return {
		guard = violation.guard,
		kind = violation.kind,
		action = violation.action,
		reason = violation.reason,
		path = violation.path,
		source = violation.source.kind,
		player = violation.userId,
		ops = table.clone(violation.ops),
		before = before,
		after = after,
		-- encoded sizes of values left out for being too big
		beforeSize = beforeSize,
		afterSize = afterSize,
	}
end

-- Publishes a guardBroken message for `violation` on `store`/`key`. Does nothing when no one is
-- listening
function GuardEvent.publish(
	store: string,
	storeKind: "profile" | "shared",
	key: string?,
	violation: Guards.Violation,
	schema: Schema.Schema?,
	json: Types.Json,
	at: number
)
	if not Bus.listening() then
		return
	end
	local fields = GuardEvent.describe(violation, schema, json)
	fields.store = store
	fields.storeKind = storeKind
	fields.key = key
	Bus.publish("guardBroken", fields, at)
end

return GuardEvent
