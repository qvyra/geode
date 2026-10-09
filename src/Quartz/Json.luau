--!strict

-- Plain Luau JSON encoder for where HttpService isn't around. Output is for size estimates:
-- same shape as HttpService, no byte-for-byte promise. HttpService lets inf and NaN through,
-- so validation rejects them before they get here.
-- Checked against HttpService: floats print the same and non-ASCII is left alone. Only
-- control chars below 32 get escaped. DEL goes out raw, which surprised me

local Types = require("./Types")

local Json = {}

local ESCAPES: { [string]: string } = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function encodeString(text: string): string
	local escaped = string.gsub(text, '[\0-\31"\\]', function(char: string): string
		return ESCAPES[char] or string.format("\\u%04x", string.byte(char))
	end)
	return `"{escaped}"`
end

local function isArray(source: { [unknown]: unknown }): boolean
	local count = 0
	for key in source do
		if type(key) ~= "number" then
			return false
		end
		count += 1
	end
	return count == #source
end

local function encodeValue(value: unknown, parts: { string })
	local kind = type(value)
	if value == nil then
		table.insert(parts, "null")
	elseif kind == "boolean" then
		table.insert(parts, if value then "true" else "false")
	elseif kind == "number" then
		table.insert(parts, tostring(value))
	elseif kind == "string" then
		table.insert(parts, encodeString(value :: string))
	elseif kind == "table" then
		local source = value :: { [unknown]: unknown }
		if next(source) ~= nil and isArray(source) then
			table.insert(parts, "[")
			for index, item in ipairs(source :: { unknown }) do
				if index > 1 then
					table.insert(parts, ",")
				end
				encodeValue(item, parts)
			end
			table.insert(parts, "]")
		else
			table.insert(parts, "{")
			local first = true
			for key, item in source do
				if not first then
					table.insert(parts, ",")
				end
				first = false
				table.insert(parts, encodeString(tostring(key)))
				table.insert(parts, ":")
				encodeValue(item, parts)
			end
			table.insert(parts, "}")
		end
	else
		error(`can't encode a {typeof(value)} as JSON`, 0)
	end
end

function Json.encode(value: unknown): string
	local parts = {}
	encodeValue(value, parts)
	return table.concat(parts)
end

function Json.adapter(): Types.Json
	return {
		encode = function(_self: Types.Json, value: unknown): string
			return Json.encode(value)
		end,
	}
end

return Json
