--!strict

local Spec = require("../_lib/Spec")
local Tree = require("../../src/Matrix/Tree")

type Any = any

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Tree", function()
		it("adopts values as deep frozen copies", function()
			local original = { a = { b = 1 } }
			local adopted = Tree.adopt(original) :: Any
			expect(adopted == original).toBe(false)
			expect(table.isfrozen(adopted)).toBe(true)
			expect(table.isfrozen(adopted.a)).toBe(true)
			expect(table.isfrozen(original)).toBe(false)
		end)

		it("shares subtrees it already owns", function()
			local root = Tree.adopt({ a = { b = 1 }, c = { d = 2 } }) :: Any
			local again = Tree.adopt({ reused = root.a }) :: Any
			expect(again.reused == root.a).toBe(true)
		end)

		it("copies tables frozen by someone else", function()
			local outside = table.freeze({ inner = { 1 } })
			local adopted = Tree.adopt(outside) :: Any
			expect(adopted == outside).toBe(false)
			expect(table.isfrozen(adopted.inner)).toBe(true)
		end)

		it("refuses cycles", function()
			local loop: { [string]: unknown } = {}
			loop.self = loop
			expect(function()
				Tree.adopt(loop)
			end).toThrow("contains itself")
		end)

		it("sets with structural sharing and leaves the old root intact", function()
			local root = Tree.adopt({ a = { b = 1 }, c = { d = 2 } }) :: Any
			local next = Tree.set(root, { "a", "b" }, 5) :: Any
			expect(next.a.b).toBe(5)
			expect(root.a.b).toBe(1)
			expect(next.c == root.c).toBe(true)
			expect(next.a == root.a).toBe(false)
		end)

		it("creates missing tables and removes keys set to nil", function()
			local root = Tree.adopt({}) :: Any
			local next = Tree.set(root, { "x", "y" }, true) :: Any
			expect(next.x.y).toBe(true)
			local cleared = Tree.set(next, { "x", "y" }, nil) :: Any
			expect(cleared.x.y).toBeNil()
		end)

		it("refuses to write below a value that isn't a table", function()
			local root = Tree.adopt({ coins = 5 })
			expect(function()
				Tree.set(root, { "coins", "x" }, 1)
			end).toThrow("can't write below coins")
		end)

		it("gets values and stops at non-tables", function()
			local root = Tree.adopt({ a = { b = { 1, 2 } } })
			expect(Tree.get(root, { "a", "b", 2 })).toBe(2)
			expect(Tree.get(root, { "a", "b", 2, "x" })).toBeNil()
			expect(Tree.get(root, {})).toBe(root)
		end)

		it("diffs leaves only where references differ", function()
			local root = Tree.adopt({ a = { b = 1, c = 2 }, untouched = { big = { 1, 2, 3 } } })
			local next = Tree.set(Tree.set(root, { "a", "b" }, 10), { "added" }, "new")
			local diff = Tree.diff(root, next)
			table.sort(diff, function(x, y)
				return tostring(x.path[1]) < tostring(y.path[1])
			end)
			expect(#diff).toBe(2)
			expect(diff[1].path).toEqual({ "a", "b" })
			expect(diff[1].old).toBe(1)
			expect(diff[1].new).toBe(10)
			expect(diff[2].path).toEqual({ "added" })
			expect(diff[2].old).toBeNil()
		end)

		it("finds no diff between equal copies", function()
			local root = Tree.adopt({ a = { 1, 2 } })
			local copy = Tree.set(root, { "a" }, { 1, 2 })
			expect(#Tree.diff(root, copy)).toBe(0)
		end)

		it("diffs a whole subtree turning into a scalar at its path", function()
			local root = Tree.adopt({ a = 1 })
			local next = Tree.set(root, { "a" }, { b = 2 })
			local diff = Tree.diff(root, next)
			expect(#diff).toBe(1)
			expect(diff[1].path).toEqual({ "a" })
			expect(diff[1].old).toBe(1)
		end)
	end)
end
