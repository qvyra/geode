--!strict

local Document = require("../../src/Matrix/Document")
local Spec = require("../_lib/Spec")
local Transaction = require("../../src/Matrix/Transaction")

local function newDoc(data: unknown): Document.Document
	return Document.new({ data = data, reportError = function() end })
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Transaction.defer", function()
		it("runs after a commit with the record", function()
			local doc = newDoc({ coins = 1 })
			local outcome: Transaction.Outcome? = nil
			doc:transact(function(tx)
				tx:increment("coins")
				tx:defer(function(result)
					outcome = result
				end)
			end)
			local seen = outcome :: Transaction.Outcome
			expect(seen.committed).toBe(true)
			expect((seen.record :: Document.CommitRecord).revision).toBe(1)
		end)

		it("runs after a failure with the error", function()
			local doc = newDoc({ coins = 1 })
			local outcome: Transaction.Outcome? = nil
			doc:transact(function(tx)
				tx:defer(function(result)
					outcome = result
				end)
				error("nope")
			end)
			local seen = outcome :: Transaction.Outcome
			expect(seen.committed).toBe(false)
			expect((seen.error :: Transaction.TxError).kind).toBe("error")
		end)

		it("runs when nothing changed", function()
			local doc = newDoc({})
			local ran = false
			doc:transact(function(tx)
				tx:defer(function(result)
					ran = not result.committed
				end)
			end)
			expect(ran).toBe(true)
		end)

		it("runs after listeners, so it can write to the document", function()
			local doc = newDoc({ coins = 1, audit = 0 })
			local order = {}
			doc:observe("coins", function()
				table.insert(order, "observer")
			end)
			doc:transact(function(tx)
				tx:increment("coins")
				tx:defer(function()
					table.insert(order, "deferred")
					doc:increment("audit")
				end)
			end)
			expect(order).toEqual({ "observer", "deferred" })
			expect(doc:get("audit")).toBe(1)
		end)
	end)

	describe("Transaction.getBefore", function()
		it("reads the state from before the transaction's own writes", function()
			local doc = newDoc({ coins = 1 })
			local before, after = nil, nil
			doc:transact(function(tx)
				tx:increment("coins", 9)
				before = tx:getBefore("coins")
				after = tx:get("coins")
			end)
			expect(before).toBe(1)
			expect(after).toBe(10)
		end)
	end)
end
