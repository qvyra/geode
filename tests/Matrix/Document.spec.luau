--!strict

local Document = require("../../src/Matrix/Document")
local Geode = require("../../src")
local MockClock = require("../../src/Quartz/Mock/Clock")
local Spec = require("../_lib/Spec")
local Transaction = require("../../src/Matrix/Transaction")

type Any = any

local function newDoc(data: unknown?, options: Document.Options?): Document.Document
	local merged: Document.Options = options or {}
	merged.data = data
	merged.reportError = merged.reportError or function() end
	return Document.new(merged)
end

local function errorKind(result: Document.TxResult): string?
	if result.ok then
		return nil
	end
	return result.error.kind
end

-- Op names are global, so each test registers its own
local opCount = 0
local function uniqueOp(handler: Transaction.OpHandler): string
	opCount += 1
	local name = `testOp{opCount}`
	Transaction.register(name, handler)
	return name
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Document reads", function()
		it("hands out frozen values that can't be changed", function()
			local doc = newDoc({ inventory = { { id = "sword" } } })
			local inventory = doc:get("inventory") :: Any
			expect(table.isfrozen(inventory)).toBe(true)
			expect(table.isfrozen(inventory[1])).toBe(true)
			expect(function()
				inventory[1].id = "hacked"
			end).toThrow()
			expect(table.isfrozen(doc:snapshot() :: Any)).toBe(true)
		end)

		it("keeps a frozen copy of the initial data", function()
			local data = { coins = 1 }
			local doc = newDoc(data)
			data.coins = 99
			expect(doc:get("coins")).toBe(1)
			expect(table.isfrozen(data)).toBe(false)
		end)
	end)

	describe("Document.transact", function()
		it("commits all ops together and bumps the revision", function()
			local doc = newDoc({ coins = 100, inventory = {} })
			local result = doc:transact(function(tx)
				tx:decrement("coins", 30)
				tx:append("inventory", { id = "sword" })
			end, { note = "shop" })
			expect(result.ok).toBe(true)
			expect(doc:get("coins")).toBe(70)
			expect((doc:get("inventory.1.id"))).toBe("sword")
			expect(doc:revision()).toBe(1)
		end)

		it("rolls back every write when the body throws", function()
			local doc = newDoc({ coins = 100, items = {} })
			local result = doc:transact(function(tx)
				tx:decrement("coins", 30)
				tx:append("items", "sword")
				error("payment failed")
			end)
			expect(errorKind(result)).toBe("error")
			expect(doc:get("coins")).toBe(100)
			expect(#(doc:get("items") :: Any)).toBe(0)
			expect(doc:revision()).toBe(0)
		end)

		it("rolls back when an op is misused partway through", function()
			local doc = newDoc({ coins = 100, name = "Ana" })
			local result = doc:transact(function(tx)
				tx:increment("coins", 5)
				tx:increment("name", 1)
			end)
			expect(errorKind(result)).toBe("opFailed")
			if not result.ok then
				expect((string.find(result.error.message, "holds a string", 1, true))).never.toBeNil()
			end
			expect(doc:get("coins")).toBe(100)
		end)

		it("commits nothing for a transaction that changes nothing", function()
			local doc = newDoc({ coins = 5 })
			local result = doc:transact(function(tx)
				tx:set("coins", 5)
				tx:set("list", { 1 })
				tx:remove("list")
			end)
			expect(result.ok).toBe(true)
			if result.ok then
				expect(result.record).toBeNil()
			end
			expect(doc:revision()).toBe(0)
		end)

		it("builds a frozen commit record with source, ops, diff and note", function()
			local clock = MockClock.new(1000)
			local doc = newDoc({ coins = 1, level = 1 }, { clock = clock :: any })
			local result = doc:transact(function(tx)
				tx:increment("coins", 4)
				tx:set("level", 2)
			end, { source = { kind = "player", userId = 77 }, note = "quest reward" })
			assert(result.ok and result.record, "expected a record")
			local record = result.record
			expect(table.isfrozen(record)).toBe(true)
			expect(record.revision).toBe(1)
			expect(record.source.kind).toBe("player")
			expect(record.source.userId).toBe(77)
			expect(record.note).toBe("quest reward")
			expect(record.timestamp).toBe(1000)
			expect(#record.ops).toBe(2)
			expect(record.ops[1].name).toBe("increment")
			expect(record.ops[1].args).toEqual({ "coins", 4 } :: { unknown })
			expect(record.diff.coins.old).toBe(1)
			expect(record.diff.coins.new).toBe(5)
			expect(record.diff.level.new).toBe(2)
		end)

		it("keys the diff by formatted path", function()
			local doc = newDoc({ inventory = { { id = "a" } } })
			local result = doc:set("inventory.1.id", "b")
			assert(result.ok and result.record, "expected a record")
			expect(result.record.diff["inventory[1].id"].new).toBe("b")
		end)

		it("refuses transactions while read only", function()
			local doc = newDoc({ coins = 1 })
			doc:setReadOnly("session lost")
			local result = doc:increment("coins")
			expect(errorKind(result)).toBe("readOnly")
			if not result.ok then
				expect(result.error.message).toBe("session lost")
			end
			expect(doc:isReadOnly()).toBe(true)
			expect(doc:get("coins")).toBe(1)
		end)

		it("refuses a transaction started inside another", function()
			local doc = newDoc({ coins = 1 })
			local inner: Document.TxResult? = nil
			doc:transact(function(tx)
				tx:increment("coins")
				inner = doc:increment("coins")
			end)
			expect(errorKind(inner :: Document.TxResult)).toBe("busy")
			expect(doc:get("coins")).toBe(2)
		end)

		it("ignores ops on a transaction after it ended", function()
			local doc = newDoc({ coins = 1 })
			local saved: Transaction.Transaction? = nil
			doc:transact(function(tx)
				saved = tx
			end)
			expect(function()
				(saved :: Transaction.Transaction):increment("coins")
			end).toThrow()
			expect(doc:get("coins")).toBe(1)
		end)

		it("runs stages after the body, and a throwing stage rejects everything", function()
			local doc = newDoc({ coins = 1, log = {} })
			doc:addStage(function(tx)
				tx:append("log", "staged")
			end)
			doc:addStage(function(tx)
				if (tx:get("coins") :: number) < 0 then
					Transaction.fail("rejected", "coins can't go negative")
				end
			end)
			expect(doc:increment("coins").ok).toBe(true)
			expect(#(doc:get("log") :: Any)).toBe(1)

			local rejected = doc:decrement("coins", 10)
			expect(errorKind(rejected)).toBe("rejected")
			expect(doc:get("coins")).toBe(2)
			expect(#(doc:get("log") :: Any)).toBe(1)
		end)

		it("refuses unknown sources", function()
			local doc = newDoc({})
			expect(function()
				doc:transact(function() end, { source = "hacker" :: any })
			end).toThrow("unknown source")
			expect(function()
				doc:transact(function() end, { source = "player" })
			end).toThrow("needs a userId")
		end)
	end)

	describe("custom ops", function()
		it("run on documents that enable them and are recorded by name", function()
			local grant = uniqueOp(function(tx, itemId: string, amount: number)
				tx:update({ "items", itemId }, function(current)
					return ((current :: number?) or 0) + amount
				end)
			end)
			local doc = newDoc({ items = {} }, { ops = { grant } })
			local result = doc:op(grant, "gem", 3)
			assert(result.ok and result.record, "expected a record")
			expect(doc:get({ "items", "gem" })).toBe(3)
			expect(#result.record.ops).toBe(1)
			expect(result.record.ops[1].name).toBe(grant)
			expect(result.record.ops[1].args).toEqual({ "gem", 3 } :: { unknown })
		end)

		it("are refused where they aren't enabled", function()
			local name = uniqueOp(function(tx)
				tx:set("x", 1)
			end)
			local doc = newDoc({})
			expect(errorKind(doc:op(name))).toBe("unknownOp")
			expect(errorKind(doc:op("neverRegistered"))).toBe("unknownOp")
		end)

		it("roll back with the rest of the transaction", function()
			local name = uniqueOp(function(tx)
				tx:set("partial", true)
				error("op broke")
			end)
			local doc = newDoc({}, { ops = { name } })
			local result = doc:transact(function(tx)
				tx:set("before", true)
				tx:op(name)
			end)
			expect(result.ok).toBe(false)
			expect(doc:get("before")).toBeNil()
			expect(doc:get("partial")).toBeNil()
		end)

		it("can't take a built-in name or be registered twice", function()
			expect(function()
				Transaction.register("set", function() end)
			end).toThrow("is a built")
			local name = uniqueOp(function() end)
			expect(function()
				Transaction.register(name, function() end)
			end).toThrow("already registered")
		end)

		it("are reachable as Geode.op", function()
			opCount += 1
			local name = `geodeOp{opCount}`
			Geode.op(name, function(tx)
				tx:set("via", "geode")
			end)
			local doc = Geode.Raw.document({ ops = { name } })
			expect(doc:op(name).ok).toBe(true)
			expect(doc:get("via")).toBe("geode")
		end)
	end)

	describe("listeners", function()
		it("observe a path with new and old values after commit", function()
			local doc = newDoc({ coins = 1, other = 0 })
			local calls = {}
			doc:observe("coins", function(new, old, record)
				table.insert(calls, { new = new, old = old, revision = record.revision })
			end)
			doc:increment("other")
			doc:increment("coins", 2)
			expect(calls).toEqual({ { new = 3, old = 1, revision = 2 } })
		end)

		it("fire for changes inside the path and for parent replacements", function()
			local doc = newDoc({ inventory = { { id = "a" } } })
			local count = 0
			doc:observe("inventory", function()
				count += 1
			end)
			local child = 0
			doc:observe("inventory.1.id", function()
				child += 1
			end)
			doc:set("inventory.1.id", "b")
			doc:set("inventory", { { id = "c" } })
			expect(count).toBe(2)
			expect(child).toBe(2)
		end)

		it("don't fire when a parent is replaced by an equal copy", function()
			local doc = newDoc({ inventory = { { id = "a" } } })
			local count = 0
			doc:observe("inventory.1", function()
				count += 1
			end)
			doc:set("inventory", { { id = "a" } })
			expect(count).toBe(0)
		end)

		it("see the committed state, not the draft", function()
			local doc = newDoc({ coins = 1 })
			local seen: unknown = nil
			doc:observe("coins", function()
				seen = doc:get("coins")
			end)
			doc:increment("coins")
			expect(seen).toBe(2)
		end)

		it("never fire for rolled back transactions", function()
			local doc = newDoc({ coins = 1 })
			local count = 0
			doc:observe("coins", function()
				count += 1
			end)
			doc:onCommit(function()
				count += 1
			end)
			doc:transact(function(tx)
				tx:increment("coins")
				error("nope")
			end)
			expect(count).toBe(0)
		end)

		it("run observers before commit listeners, in connection order", function()
			local doc = newDoc({ coins = 1 })
			local order = {}
			doc:onCommit(function()
				table.insert(order, "commit")
			end)
			doc:observe("coins", function()
				table.insert(order, "observer 1")
			end)
			doc:observe("coins", function()
				table.insert(order, "observer 2")
			end)
			doc:increment("coins")
			expect(order).toEqual({ "observer 1", "observer 2", "commit" })
		end)

		it("report errors without undoing the commit or skipping others", function()
			local reported = {}
			local doc = newDoc({ coins = 1 }, {
				reportError = function(message)
					table.insert(reported, message)
				end,
			})
			local reached = false
			doc:observe("coins", function()
				error("listener broke")
			end)
			doc:observe("coins", function()
				reached = true
			end)
			local result = doc:increment("coins")
			expect(result.ok).toBe(true)
			expect(doc:get("coins")).toBe(2)
			expect(reached).toBe(true)
			expect(#reported).toBe(1)
			expect((string.find(reported[1], "listener broke", 1, true))).never.toBeNil()
		end)

		it("stop after disconnect", function()
			local doc = newDoc({ coins = 1 })
			local count = 0
			local connection = doc:observe("coins", function()
				count += 1
			end)
			doc:increment("coins")
			connection:disconnect()
			doc:increment("coins")
			expect(count).toBe(1)
		end)

		it("may write to the document after commit", function()
			local doc = newDoc({ coins = 1, total = 0 })
			doc:observe("coins", function(new)
				doc:set("total", new)
			end)
			doc:increment("coins", 4)
			expect(doc:get("total")).toBe(5)
			expect(doc:revision()).toBe(2)
		end)
	end)
end
