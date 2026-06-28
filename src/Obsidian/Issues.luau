--!strict

-- Collects validation problems with the path where each one happened, up to a limit

export type Code =
	"type"
	| "nan"
	| "infinite"
	| "range"
	| "integer"
	| "length"
	| "pattern"
	| "literal"
	| "enum"
	| "sparse"
	| "mixed"
	| "key"
	| "extra"
	| "entries"
	| "union"
	| "codec"
	| "cycle"
	| "utf8"
	| "datatype"
	| "instance"
	| "function"
	| "thread"

export type Issue = {
	path: string,
	code: Code,
	message: string,
}

export type Result = {
	ok: boolean,
	issues: { Issue },
	truncated: boolean,
}

type Fields = {
	issues: { Issue },
	limit: number,
	truncated: boolean,
}

local Issues = {}
Issues.__index = Issues

export type Issues = typeof(setmetatable({} :: Fields, Issues))

local DEFAULT_LIMIT = 50

function Issues.new(limit: number?): Issues
	return setmetatable(
		{
			issues = {},
			limit = limit or DEFAULT_LIMIT,
			truncated = false,
		} :: Fields,
		Issues
	)
end

function Issues.add(self: Issues, path: string, code: Code, message: string)
	if #self.issues >= self.limit then
		self.truncated = true
		return
	end
	table.insert(self.issues, { path = path, code = code, message = message })
end

-- True once an issue past the limit was found. Checking continues until then, so `truncated`
-- only claims more issues when one really exists
function Issues.full(self: Issues): boolean
	return self.truncated
end

function Issues.count(self: Issues): number
	return #self.issues
end

function Issues.result(self: Issues): Result
	return {
		ok = #self.issues == 0,
		issues = self.issues,
		truncated = self.truncated,
	}
end

--[=[
	Appends a table key to a path: `.name` for plain identifiers, `[3]` for array indices and
	`["odd key"]` for everything else
]=]
function Issues.child(path: string, key: unknown): string
	if type(key) == "number" then
		return `{path}[{key}]`
	end
	local text = tostring(key)
	if string.match(text, "^[%a_][%w_]*$") then
		return `{path}.{text}`
	end
	return `{path}[{string.format("%q", text)}]`
end

return Issues
