--!strict

local BenchDocs = require("../../scripts/BenchDocs")
local Spec = require("../_lib/Spec")

local function catalog(): any
	local data: any = {
		requestMethods = {
			{ id = "UpdateAsync", label = "UpdateAsync" },
			{ id = "GetAsync:noCache", label = "GetAsync past the cache" },
		},
		subjects = {
			{ id = "a", docsLabel = "Lib `a`", config = { label = "Lib a" } },
			{ id = "b", config = { label = "Lib b" } } :: any,
			{ id = "c", config = { label = "Lib c" } } :: any,
		},
	}
	return data
end

local function timing(median: number, low: number, high: number, n: number): any
	return { kind = "timing", unit = "s", median = median, min = low, max = high, n = n, failed = 0 }
end

local function requests(byMethod: { [string]: { min: number, max: number } }): any
	return { kind = "requests", exact = true, n = 1, byMethod = byMethod }
end

local function result(
	subject: string,
	suite: string,
	scenario: string,
	metric: string,
	value: any
): any
	return {
		suite = suite,
		scenario = scenario,
		metric = metric,
		subject = subject,
		runs = { "r" },
		value = value,
	}
end

local function latest(): any
	local data: any = {
		results = {
			result("a", "load-save-release", "load-new", "time", timing(0.3, 0.18, 0.433, 20)),
			result("a", "load-save-release", "load-stored", "time", timing(0.25, 0.2, 0.3, 20)),
			result(
				"a",
				"load-save-release",
				"load-new",
				"requests",
				requests({ UpdateAsync = { min = 1, max = 1 } })
			),
			result(
				"a",
				"load-save-release",
				"load-stored",
				"requests",
				requests({
					UpdateAsync = { min = 1, max = 2 },
					["GetAsync:noCache"] = { min = 0, max = 1 },
				})
			),
			result("b", "load-save-release", "load-new", "time", timing(0.1, 0.07, 0.12, 20)),
			result(
				"b",
				"load-save-release",
				"load-new",
				"requests",
				requests({ UpdateAsync = { min = 1, max = 1 } })
			),
			result(
				"b",
				"load-save-release",
				"load-stored",
				"requests",
				requests({ UpdateAsync = { min = 1, max = 1 } })
			),
		},
	}
	return data
end

local PAGE = table.concat({
	"# Page",
	"",
	"Prose stays.",
	"",
	"<!-- bench:table perf-requests start -->",
	"",
	"| Library | Load | Save | Release | Notes |",
	"| --- | --- | --- | --- | --- |",
	"| Lib `a` | old | old | old | kept by hand |",
	"| Gone | old | old | old | dropped with its row |",
	"",
	"<!-- bench:table perf-requests end -->",
	"",
	"More prose.",
	"",
}, "\n")

return function(api: Spec.Api)
	local describe, it, expect = api.describe, api.it, api.expect

	describe("docs tables", function()
		it("write the marked table from the data and keep each row's notes", function()
			local page = BenchDocs.fill(catalog(), latest(), PAGE)
			expect((string.find(page, "# Page\n\nProse stays.\n\n", 1, true))).toBe(1)
			expect((string.find(page, "\n\nMore prose.\n", 1, true))).never.toBeNil()
			expect((string.find(page, "kept by hand", 1, true))).never.toBeNil()
			expect((string.find(page, "Gone", 1, true))).toBeNil()
			-- a row for each subject with results, in catalog order, none for c
			local first = string.find(page, "| Lib `a`", 1, true) :: number
			local second = string.find(page, "| Lib b", 1, true) :: number
			expect(first < second).toBe(true)
			expect((string.find(page, "Lib c", 1, true))).toBeNil()
			expect(
				(
					string.find(
						page,
						"1 UpdateAsync, stored profile 1 or 2 UpdateAsync and 0 or 1 GetAsync past the cache",
						1,
						true
					)
				)
			).never.toBeNil()
		end)

		it("pads every column the way Prettier does", function()
			local page = BenchDocs.fill(catalog(), latest(), PAGE)
			local widths = {}
			for line in string.gmatch(page, "[^\n]+") do
				if string.sub(line, 1, 1) == "|" then
					table.insert(widths, utf8.len(line) :: number)
				end
			end
			expect(#widths).toBe(4)
			for _, length in widths do
				expect(length).toBe(widths[1])
			end
			expect((string.find(page, "start -->\n\n| Library", 1, true))).never.toBeNil()
			expect((string.find(page, " |\n\n<!-- bench:table perf-requests end -->", 1, true))).never.toBeNil()
		end)

		it("is the same page when filled twice", function()
			local once = BenchDocs.fill(catalog(), latest(), PAGE)
			expect(BenchDocs.fill(catalog(), latest(), once)).toBe(once)
		end)

		it("fills times as median, range and count", function()
			local page = BenchDocs.fill(
				catalog(),
				latest(),
				(string.gsub(PAGE, "perf%-requests", "perf-times"))
			)
			expect((string.find(page, "0.30 (0.18 to 0.43, 20)", 1, true))).never.toBeNil()
			expect((string.find(page, "| -   ", 1, true))).never.toBeNil()
		end)

		it("refuses a table it doesn't know or one left open", function()
			expect(function()
				BenchDocs.fill(
					catalog(),
					latest(),
					"<!-- bench:table nope start -->\n<!-- bench:table nope end -->\n"
				)
			end).toThrow("doesn't have")
			expect(function()
				BenchDocs.fill(catalog(), latest(), "<!-- bench:table hops start -->\n")
			end).toThrow("isn't closed")
		end)
	end)
end
