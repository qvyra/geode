--!strict

local Document = require("../../src/Matrix/Document")
local Spec = require("../_lib/Spec")

type Any = any

local function newDoc(data: unknown): Document.Document
	return Document.new({ data = data, reportError = function() end })
end

local function failsWith(result: Document.TxResult, fragment: string): boolean
	return not result.ok and string.find(result.error.message, fragment, 1, true) ~= nil
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("built-in ops", function()
		it("set and update values at any depth", function()
			local doc = newDoc({})
			doc:set("profile.name", "Ana")
			doc:update("profile.name", function(current)
				return `{current}!`
			end)
			expect(doc:get("profile.name")).toBe("Ana!")
		end)

		it("pass frozen values to update", function()
			local doc = newDoc({ list = { 1 } })
			local frozen = false
			doc:update("list", function(current)
				frozen = table.isfrozen(current :: Any)
				return current
			end)
			expect(frozen).toBe(true)
		end)

		it("increment and decrement, starting missing numbers at zero", function()
			local doc = newDoc({})
			doc:increment("coins")
			doc:increment("coins", 9)
			doc:decrement("coins", 3)
			doc:decrement("gems")
			expect(doc:get("coins")).toBe(7)
			expect(doc:get("gems")).toBe(-1)
		end)

		it("refuse to add non finite amounts", function()
			local doc = newDoc({ coins = 1 })
			expect(failsWith(doc:increment("coins", 0 / 0), "finite number")).toBe(true)
			expect(failsWith(doc:increment("coins", math.huge), "finite number")).toBe(true)
		end)

		it("append to lists, creating them when missing", function()
			local doc = newDoc({})
			doc:append("log", "a")
			doc:append("log", "b")
			expect(doc:get("log")).toEqual({ "a", "b" })
			expect(failsWith(newDoc({ log = { x = 1 } }):append("log", "c"), "isn't a list")).toBe(
				true
			)
		end)

		it("insert at an index within range", function()
			local doc = newDoc({ list = { "a", "c" } })
			doc:insert("list", 2, "b")
			doc:insert("list", 4, "d")
			expect(doc:get("list")).toEqual({ "a", "b", "c", "d" })
			expect(failsWith(doc:insert("list", 9, "x"), "outside 1 to 5")).toBe(true)
		end)

		it("remove list items with shifting and map keys without", function()
			local doc = newDoc({ list = { "a", "b", "c" }, map = { x = 1, y = 2 } })
			doc:remove("list.2")
			doc:remove("map.x")
			expect(doc:get("list")).toEqual({ "a", "c" })
			expect(doc:get("map")).toEqual({ y = 2 })
			expect(doc:remove("list.9").ok).toBe(true)
			expect(failsWith(doc:remove(""), "can't remove the root")).toBe(true)
		end)

		it("clear a value to an empty table", function()
			local doc = newDoc({ inventory = { 1, 2, 3 } })
			doc:clear("inventory")
			expect(doc:get("inventory")).toEqual({})
		end)

		it("merge fields over a table", function()
			local doc = newDoc({ settings = { music = true, volume = 5 } })
			doc:merge("settings", { volume = 8, theme = "dark" })
			expect(doc:get("settings")).toEqual({ music = true, volume = 8, theme = "dark" })
			expect(failsWith(newDoc({ n = 1 }):merge("n", { a = 1 }), "can't merge")).toBe(true)
		end)

		it("copy written tables so later edits by the caller don't leak in", function()
			local doc = newDoc({})
			local item = { id = "sword" }
			doc:append("items", item)
			item.id = "hacked"
			expect((doc:get("items.1.id"))).toBe("sword")
			expect(table.isfrozen(item)).toBe(false)
		end)

		it("read their own writes inside a transaction", function()
			local doc = newDoc({ coins = 1 })
			local seen: unknown = nil
			doc:transact(function(tx)
				tx:increment("coins", 2)
				seen = tx:get("coins")
			end)
			expect(seen).toBe(3)
		end)

		it("expose the draft diff to stages", function()
			local doc = newDoc({ coins = 1 })
			local paths = {}
			doc:transact(function(tx)
				tx:increment("coins")
				for _, entry in tx:diff() do
					table.insert(paths, entry.path[1])
				end
			end)
			expect(paths).toEqual({ "coins" })
		end)

		it("report bad paths as op failures", function()
			local doc = newDoc({ coins = 1 })
			expect(failsWith(doc:set("a..b", 1), "empty segment")).toBe(true)
			expect(failsWith(doc:set("coins.deeper", 1), "can't write below coins")).toBe(true)
		end)
	end)
end
