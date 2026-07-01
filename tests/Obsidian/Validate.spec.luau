--!strict

local Lune = require("./LuneDatatypes")
local Spec = require("../_lib/Spec")
local Validate = require("../../src/Obsidian/Validate")
local t = require("../../src/Obsidian/Schema")

local codec = Lune.codec
local roblox = Lune.roblox

local function issuesOf(schema: t.Schema, value: unknown): { string }
	local found = {}
	for _, issue in Validate.validate(schema, value).issues do
		table.insert(found, `{issue.path} {issue.code}`)
	end
	return found
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	local Player = t.struct({
		name = t.string({ minLength = 3, maxLength = 12 }),
		coins = t.integer({ min = 0 }),
		level = t.number({ min = 1, max = 100 }),
		admin = t.optional(t.boolean()),
		inventory = t.array(t.struct({
			id = t.string(),
			amount = t.integer({ min = 1 }),
			pos = t.optional(codec.Vector3),
		})),
		stats = t.map(t.number()),
	})

	local valid = {
		name = "Ana",
		coins = 10,
		level = 3.5,
		inventory = {
			{ id = "sword", amount = 1 },
			{ id = "torch", amount = 4, pos = roblox.Vector3.new(1, 2, 3) },
		},
		stats = { kills = 3 },
	}

	describe("Validate.validate", function()
		it("passes data that matches", function()
			local result = Validate.validate(Player, valid)
			expect(result.ok).toBe(true)
		end)

		it("reports every problem with its path", function()
			local bad = table.clone(valid)
			bad.name = "Al"
			bad.coins = -1.5
			bad.inventory = { { id = "sword", amount = 0, pos = "here" } }
			-- Struct fields are checked in name order, so the issue order is stable
			expect(issuesOf(Player, bad)).toEqual({
				"data.coins integer",
				"data.coins range",
				"data.inventory[1].amount range",
				"data.inventory[1].pos codec",
				"data.name length",
			})
		end)

		it("reports missing fields and the wrong types", function()
			expect(issuesOf(t.struct({ a = t.number(), b = t.string() }), { b = 5 })).toEqual({
				"data.a type",
				"data.b type",
			})
		end)

		it("rejects undeclared fields unless extra is allowed", function()
			expect(issuesOf(t.struct({ a = t.number() }), { a = 1, typo = 2 })).toEqual({
				"data.typo extra",
			})
			expect(
				Validate.validate(t.struct({ a = t.number() }, { extra = true }), { a = 1, b = 2 }).ok
			).toBe(true)
		end)

		it("checks strings for length in characters and patterns", function()
			local code = t.string({ pattern = "%u%u%d%d" })
			expect(Validate.validate(code, "AB12").ok).toBe(true)
			expect(issuesOf(code, "AB123")).toEqual({ "data pattern" })
			expect(Validate.validate(t.string({ maxLength = 2 }), "éé").ok).toBe(true)
			expect(issuesOf(t.string(), string.char(255))).toEqual({ "data utf8" })
		end)

		it("rejects NaN and infinity even without bounds", function()
			expect(issuesOf(t.number(), 0 / 0)).toEqual({ "data nan" })
			expect(issuesOf(t.number(), math.huge)).toEqual({ "data infinite" })
		end)

		it("checks literals and enums", function()
			expect(Validate.validate(t.literal("v1"), "v1").ok).toBe(true)
			expect(issuesOf(t.literal("v1"), "v2")).toEqual({ "data literal" })
			local rarity = t.enum({ "common", "rare" })
			expect(Validate.validate(rarity, "rare").ok).toBe(true)
			expect(issuesOf(rarity, "epic")).toEqual({ "data enum" })
		end)

		it("checks array shape and length", function()
			local list = t.array(t.number(), { minLength = 1, maxLength = 2 })
			expect(issuesOf(list, {})).toEqual({ "data length" })
			expect(issuesOf(list, { 1, 2, 3 })).toEqual({ "data length" })
			expect(issuesOf(list, { a = 1 })).toEqual({ "data type" })
			local sparse: { [number]: number } = {}
			sparse[1] = 1
			sparse[3] = 3
			expect(issuesOf(list, sparse)).toEqual({ "data sparse" })
		end)

		it("checks map keys and entry counts", function()
			local scores = t.map(t.number(), { key = t.string({ maxLength = 3 }), maxEntries = 2 })
			expect(issuesOf(scores, { abcd = 1 })).toEqual({ "data.abcd length" })
			expect(issuesOf(scores, { a = 1, b = 2, c = 3 })).toEqual({ "data entries" })
			expect(issuesOf(t.map(t.number()), { [1] = 1 })).toEqual({ "data[1] key" })
		end)

		it("accepts any option of a union", function()
			local id = t.union({ t.string(), t.integer() })
			expect(Validate.validate(id, "x").ok).toBe(true)
			expect(Validate.validate(id, 3).ok).toBe(true)
			expect(issuesOf(id, true)).toEqual({ "data union" })
		end)

		it("runs the storable checks for json fields", function()
			local loose = t.struct({ extra = t.json() })
			expect(Validate.validate(loose, { extra = { deep = { 1, 2 } } }).ok).toBe(true)
			expect(issuesOf(loose, { extra = { deep = { fn = print } } })).toEqual({
				"data.extra.deep.fn function",
			})
		end)

		it("catches cycles in typed data", function()
			local Node = t.struct({ next = t.optional(t.json()) })
			local loop: { [string]: unknown } = {}
			loop.next = loop
			expect(issuesOf(Node, loop)).toEqual({ "data.next cycle" })
		end)

		it("uses the given root and limit", function()
			local result = Validate.validate(t.number(), "x", { root = "coins" })
			expect(result.issues[1].path).toBe("coins")
			local wide = t.array(t.number())
			local strings = table.create(10, "x")
			local limited = Validate.validate(wide, strings, { limit = 3 })
			expect(#limited.issues).toBe(3)
			expect(limited.truncated).toBe(true)
		end)
	end)

	describe("Validate.encode and decode", function()
		it("round trips live values through their stored form", function()
			local stored = Validate.encode(Player, valid)
			local item = (stored :: any).inventory[2]
			expect(item.pos).toEqual({ 1, 2, 3 })

			local ok, decoded = Validate.decode(Player, stored)
			expect(ok).toBe(true)
			local pos = (decoded :: any).inventory[2].pos
			expect(typeof(pos)).toBe("Vector3")
			expect(pos.Y).toBe(2)
		end)

		it("never shares tables with the input", function()
			local stored = Validate.encode(Player, valid) :: any
			expect(stored.inventory == valid.inventory).toBe(false)
			expect(stored.stats == valid.stats).toBe(false)
		end)

		it("reports stored values a codec can't read", function()
			local ok, result = Validate.decode(Player, {
				name = "Ana",
				coins = 1,
				level = 1,
				inventory = { { id = "x", amount = 1, pos = { 1, 2 } } },
				stats = {},
			})
			expect(ok).toBe(false)
			local issue = (result :: any).issues[1]
			expect(issue.path).toBe("data.inventory[1].pos")
			expect(issue.code).toBe("codec")
		end)

		it("decodes unions to the first option that fits", function()
			local spot = t.union({ codec.Vector3, t.string() })
			local ok, value = Validate.decode(spot, { 4, 5, 6 })
			expect(ok).toBe(true)
			expect(typeof(value)).toBe("Vector3")
			local _, text = Validate.decode(spot, "home")
			expect(text).toBe("home")
		end)
	end)
end
