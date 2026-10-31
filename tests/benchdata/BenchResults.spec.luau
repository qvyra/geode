--!strict

local BenchResults = require("../../scripts/BenchResults")
local Spec = require("../_lib/Spec")

local JOB_ID = "004f45b9-f359-48fe-bb12-a5ba3539b925"

local function task(mode: string, jobId: string): { [string]: any }
	return {
		mode = mode,
		library = "Geode",
		report = {
			environment = { jobId = jobId, placeId = 123456789012345, placeVersion = 47 },
			result = {
				steps = { { key = "run-1", ok = true, seconds = 0.1837694760179147 } },
				messaging = { topic = "GeodeStudioCheck-Bench-run-Geode", sent = 10 },
			},
		},
		logTail = { `server {jobId} in place 123456789012345` },
	}
end

local INFO = {
	build = "0.6.0",
	sourceTree = string.rep("a", 40),
	benchTree = string.rep("b", 40),
	workflowRun = "https://github.com/qvyra/geode/actions/runs/1",
}

return function(api: Spec.Api)
	local describe, it, expect = api.describe, api.it, api.expect

	describe("decode and encode", function()
		it("keep every float exactly", function()
			local text = "[0.11552253100671805, 1.1828272709972225, 1792845147778, -0.5, 1e-05]"
			local list = BenchResults.decode(text)
			expect(list[1]).toBe(tonumber("0.11552253100671805"))
			expect(list[2]).toBe(tonumber("1.1828272709972225"))
			expect(BenchResults.decode(BenchResults.encode(list))).toEqual(list)
		end)

		it("write empty lists as lists and empty objects as objects", function()
			local value = BenchResults.decode('{"a": [], "b": {}}')
			expect(BenchResults.encode(value)).toBe('{\n\t"a": [],\n\t"b": {}\n}\n')
		end)

		it("read escapes and write them back", function()
			local value = BenchResults.decode('"a\\"b\\\\c\\n\\u00e9\\ud83d\\ude00"')
			expect(value).toBe('a"b\\c\né😀')
			expect(BenchResults.encode(value)).toBe('"a\\"b\\\\c\\né😀"\n')
		end)

		it("put the identifying keys first and the rest in order", function()
			local text = BenchResults.encode({ zeta = 1, alpha = 2, id = "x", kind = "run" })
			expect(text).toBe('{\n\t"kind": "run",\n\t"id": "x",\n\t"alpha": 2,\n\t"zeta": 1\n}\n')
		end)

		it("refuse what JSON can't hold", function()
			expect(function()
				BenchResults.encode(0 / 0)
			end).toThrow("NaN")
			expect(function()
				BenchResults.decode("[1, null]")
			end).toThrow("null")
			expect(function()
				BenchResults.decode("[1] 2")
			end).toThrow("more after")
		end)
	end)

	describe("sanitize", function()
		it("drops ids and keys but keeps every measurement", function()
			local run = BenchResults.sanitize({
				run = "1faf45fa",
				date = "2026-10-24T12:40:18Z",
				placeVersion = 47,
				pins = {},
				refused = {},
				tasks = {
					task("hold", JOB_ID),
					task("join", "3f7d7c49-d6e4-48b0-8163-a16accd6d78c"),
				},
			}, INFO)
			local text = BenchResults.encode(run)
			expect((string.find(text, JOB_ID, 1, true))).toBeNil()
			expect((string.find(text, "123456789012345", 1, true))).toBeNil()
			expect((string.find(text, "placeVersion", 1, true))).toBeNil()
			expect((string.find(text, '"key"', 1, true))).toBeNil()
			expect((string.find(text, "topic", 1, true))).toBeNil()

			local first = run.tasks[1]
			expect(first.report.result.steps[1].seconds).toBe(0.1837694760179147)
			expect(first.report.result.messaging.sent).toBe(10)
			expect(first.logTail[1]).toBe("server <job> in place <id>")
			expect(first.report.environment.ownServer).toBe(true)
			expect(run.build).toBe("0.6.0")
			expect(run.workflowRun).toBe(INFO.workflowRun)
		end)

		it("notices when two tasks shared a server", function()
			local run = BenchResults.sanitize({
				run = "r",
				date = "d",
				pins = {},
				refused = {},
				tasks = { task("hold", JOB_ID), task("join", JOB_ID) },
			}, INFO)
			expect(run.tasks[1].report.environment.ownServer).toBe(false)
			expect(run.tasks[2].report.environment.ownServer).toBe(false)
		end)
	end)
end
