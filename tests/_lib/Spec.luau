--!strict

-- Minimal spec harness for Lune. Spec files return a function that receives the api,
-- which keeps them free of globals and lets the runner own discovery and reporting

export type Expectation = {
	never: Expectation,
	toBe: (expected: unknown) -> (),
	toEqual: (expected: unknown) -> (),
	toBeNil: () -> (),
	toBeTruthy: () -> (),
	toThrow: (pattern: string?) -> (),
}

export type Api = {
	describe: (name: string, body: () -> ()) -> (),
	it: (name: string, body: () -> ()) -> (),
	expect: (actual: unknown) -> Expectation,
}

export type Define = (api: Api) -> ()

export type Result = {
	name: string,
	ok: boolean,
	message: string?,
}

type Case = {
	name: string,
	body: () -> (),
}

local Spec = {}

--// helpers

local function show(value: unknown, depth: number?): string
	if type(value) == "string" then
		return string.format("%q", value)
	end
	if type(value) ~= "table" then
		return tostring(value)
	end
	local level = depth or 0
	if level >= 3 then
		return "{...}"
	end
	local source = value :: { [unknown]: unknown }
	local parts = {}
	for _, item in ipairs(source :: { unknown }) do
		table.insert(parts, show(item, level + 1))
		if #parts >= 20 then
			break
		end
	end
	local named = {}
	for key, item in source do
		if type(key) ~= "number" or key > #source or key % 1 ~= 0 then
			table.insert(named, `{tostring(key)} = {show(item, level + 1)}`)
		end
	end
	table.sort(named)
	table.move(named, 1, #named, #parts + 1, parts)
	return `\{ {table.concat(parts, ", ")} \}`
end

local function deepEqual(a: unknown, b: unknown): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	local left = a :: { [unknown]: unknown }
	local right = b :: { [unknown]: unknown }
	for key, value in left do
		if not deepEqual(value, right[key]) then
			return false
		end
	end
	for key in right do
		if left[key] == nil then
			return false
		end
	end
	return true
end

local function makeExpectation(actual: unknown, negated: boolean): Expectation
	-- Level 3 points the failure at the spec line that called the matcher
	local function check(passed: boolean, message: string)
		if passed == negated then
			error((if negated then "expected not: " else "expected: ") .. message, 3)
		end
	end

	local expectation = {} :: Expectation

	function expectation.toBe(expected: unknown)
		check(actual == expected, `{show(actual)} to be {show(expected)}`)
	end

	function expectation.toEqual(expected: unknown)
		check(deepEqual(actual, expected), `{show(actual)} to deeply equal {show(expected)}`)
	end

	function expectation.toBeNil()
		check(actual == nil, `{show(actual)} to be nil`)
	end

	function expectation.toBeTruthy()
		check(not not actual, `{show(actual)} to be truthy`)
	end

	function expectation.toThrow(pattern: string?)
		if type(actual) ~= "function" then
			error(`toThrow needs a function, got {typeof(actual)}`, 2)
		end
		local ok, err = pcall(actual :: () -> ...unknown)
		local matched = not ok and (pattern == nil or string.find(tostring(err), pattern) ~= nil)
		check(matched, `function to throw{if pattern then ` matching {show(pattern)}` else ""}`)
	end

	if not negated then
		expectation.never = makeExpectation(actual, true)
	end

	return expectation
end

--[=[
	Collects the cases a spec file declares, runs them in order and reports each one
]=]
function Spec.run(define: Define): { Result }
	local cases: { Case } = {}
	local scope: { string } = {}

	local api: Api = {
		describe = function(name: string, body: () -> ())
			table.insert(scope, name)
			body()
			table.remove(scope)
		end,
		it = function(name: string, body: () -> ())
			local path = table.clone(scope)
			table.insert(path, name)
			table.insert(cases, { name = table.concat(path, " > "), body = body })
		end,
		expect = function(actual: unknown): Expectation
			return makeExpectation(actual, false)
		end,
	}

	define(api)

	local results: { Result } = {}
	for _, case in cases do
		local ok, err = pcall(case.body :: () -> ...unknown)
		table.insert(results, {
			name = case.name,
			ok = ok,
			message = if ok then nil else tostring(err),
		})
	end
	return results
end

return Spec
