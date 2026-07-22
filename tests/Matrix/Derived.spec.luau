--!strict

local Document = require("../../src/Matrix/Document")
local Spec = require("../_lib/Spec")
local Tree = require("../../src/Matrix/Tree")

type Any = any

local function newDoc(data: unknown): Document.Document
	return Document.new({ data = data, reportError = function() end })
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Document.addDerived", function()
		it("reads a computed field and paths inside it", function()
			local doc = newDoc({ a = 2 })
			doc:addDerived("box", { "a" }, function(root)
				return Tree.adopt({ twice = (root :: Any).a * 2 })
			end)
			expect(doc:get("box.twice")).toBe(4)
			doc:increment("a")
			expect(doc:get("box.twice")).toBe(6)
		end)

		it("refuses writes to the derived name and keeps the rest of the state", function()
			local doc = newDoc({ a = 1 })
			doc:addDerived("view", { "a" }, function()
				return 0
			end)
			local result = doc:transact(function(tx)
				tx:increment("a")
				tx:set("view", 5)
			end)
			expect(result.ok).toBe(false)
			expect(doc:get("a")).toBe(1)
		end)

		it("refuses a name used by stored data or another derived field", function()
			local doc = newDoc({ taken = true })
			expect(function()
				doc:addDerived("taken", { "x" }, function()
					return 0
				end)
			end).toThrow("clashes")
			doc:addDerived("view", { "x" }, function()
				return 0
			end)
			expect(function()
				doc:addDerived("view", { "x" }, function()
					return 0
				end)
			end).toThrow("already exists")
		end)

		it("only notifies observers when the computed value really changes", function()
			local doc = newDoc({ a = 1, b = 0 })
			doc:addDerived("parity", { "a" }, function(root)
				return (root :: Any).a % 2
			end)
			local count = 0
			doc:observe("parity", function()
				count += 1
			end)
			doc:increment("a", 2)
			expect(count).toBe(0)
			doc:increment("a")
			expect(count).toBe(1)
			doc:increment("b")
			expect(count).toBe(1)
		end)
	end)

	describe("Tree.equal", function()
		it("compares deeply", function()
			expect(Tree.equal({ a = { 1 } }, { a = { 1 } })).toBe(true)
			expect(Tree.equal({ a = { 1 } }, { a = { 2 } })).toBe(false)
			expect(Tree.equal(1, 1)).toBe(true)
		end)
	end)
end
