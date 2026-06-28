--!strict

local Spec = require("../_lib/Spec")
local Storable = require("../../src/Obsidian/Storable")
local roblox = require("@lune/roblox") :: any

local function only(value: unknown): (string?, string?)
	local result = Storable.check(value)
	if #result.issues ~= 1 then
		return nil, `expected one issue, got {#result.issues}`
	end
	return result.issues[1].path, result.issues[1].code
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Storable.check", function()
		it("passes plain nested data", function()
			local result = Storable.check({
				coins = 10,
				name = "Ana",
				flags = { true, false },
				inventory = { { id = "sword", amount = 1 } },
				empty = {},
			})
			expect(result.ok).toBe(true)
			expect(#result.issues).toBe(0)
		end)

		it("catches undeclared Roblox datatypes with the full path", function()
			local path, code =
				only({ inventory = { {}, {}, { pos = roblox.Vector3.new(1, 2, 3) } } })
			expect(path).toBe("data.inventory[3].pos")
			expect(code).toBe("datatype")
		end)

		it("catches Instances", function()
			local path, code = only({ target = roblox.Instance.new("Part") })
			expect(path).toBe("data.target")
			expect(code).toBe("instance")
		end)

		it("catches functions and threads", function()
			local path, code = only({ callback = print })
			expect(path).toBe("data.callback")
			expect(code).toBe("function")
			path, code = only({ job = coroutine.create(print) })
			expect(path).toBe("data.job")
			expect(code).toBe("thread")
		end)

		it("catches NaN and both infinities", function()
			local result = Storable.check({ a = 0 / 0, b = math.huge, c = -math.huge })
			local codes = {}
			for _, issue in result.issues do
				codes[issue.path] = issue.code
			end
			expect(codes["data.a"]).toBe("nan")
			expect(codes["data.b"]).toBe("infinite")
			expect(codes["data.c"]).toBe("infinite")
		end)

		it("catches arrays mixed with named keys", function()
			local mixed: { [unknown]: unknown } = { 1, 2 }
			mixed.extra = true
			local path, code = only({ list = mixed })
			expect(path).toBe("data.list")
			expect(code).toBe("mixed")
		end)

		it("catches sparse arrays", function()
			local sparse: { [number]: number } = {}
			sparse[1] = 1
			sparse[3] = 3
			local path, code = only({ list = sparse })
			expect(path).toBe("data.list")
			expect(code).toBe("sparse")
		end)

		it("catches keys that aren't strings or array indices", function()
			local cases: { { [unknown]: unknown } } = {
				{ [true] = 1 },
				{ [{}] = 1 },
				{ [1.5] = 1 },
				{ [0] = 1 },
				{ [-2] = 1 },
			}
			for _, case in cases do
				local path, code = only({ bad = case })
				expect(path).toBe("data.bad")
				expect(code).toBe("key")
			end
		end)

		it("catches cycles", function()
			local loop: { [string]: unknown } = {}
			loop.self = loop
			local path, code = only({ node = loop })
			expect(path).toBe("data.node.self")
			expect(code).toBe("cycle")
		end)

		it("allows the same table twice when it isn't a cycle", function()
			local shared = { 1 }
			expect(Storable.check({ a = shared, b = shared }).ok).toBe(true)
		end)

		it("catches invalid UTF-8 in values and keys", function()
			local path, code = only({ name = string.char(255, 254) })
			expect(path).toBe("data.name")
			expect(code).toBe("utf8")
			path, code = only({ [string.char(255)] = 1 })
			expect(path).toBe("data")
			expect(code).toBe("utf8")
		end)

		it("quotes keys that aren't identifiers", function()
			local path = only({ ["odd key"] = print })
			expect(path).toBe('data["odd key"]')
		end)

		it("uses the given root name", function()
			local result = Storable.check({ x = print }, "profile")
			expect(result.issues[1].path).toBe("profile.x")
		end)

		it("stops at the limit and says so", function()
			local many = {}
			for index = 1, 80 do
				many[`f{index}`] = print
			end
			local result = Storable.check(many)
			expect(#result.issues).toBe(50)
			expect(result.truncated).toBe(true)
			local small = Storable.check(many, nil, 5)
			expect(#small.issues).toBe(5)
		end)
	end)
end
