--!strict

local Record = require("../../src/Sapphire/Record")
local Spec = require("../_lib/Spec")

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	local owner: Record.Owner = { jobId = "A", session = "A:1" }

	local function withLease(jobId: string, session: string, renewedAt: number): Record.Record
		local record = Record.new({ coins = 1 }, 0, 1)
		record.meta.lease =
			{ jobId = jobId, placeId = 1, session = session, acquiredAt = 0, renewedAt = renewedAt }
		return record
	end

	describe("Record", function()
		it("builds new records with copied data and empty metadata", function()
			local data = { coins = 1 }
			local record = Record.new(data, 50, 3)
			data.coins = 9
			expect((record.data :: { coins: number }).coins).toBe(1)
			expect(record.meta.schemaVersion).toBe(3)
			expect(record.meta.revision).toBe(0)
			expect(record.meta.createdAt).toBe(50)
			expect(record.meta.receipts).toEqual({})
			expect(record.meta.lease).toBeNil()
		end)

		it("recognizes the record shape", function()
			expect(Record.isRecord(Record.new({}, 0, 1))).toBe(true)
			expect(Record.isRecord({ data = {} })).toBe(false)
			expect(Record.isRecord("text")).toBe(false)
			expect(Record.isRecord({ meta = { revision = "1", schemaVersion = 1 } })).toBe(false)
		end)

		it("tells free, own, stale and held leases apart", function()
			expect(Record.leaseState(Record.new({}, 0, 1), 100, 60, owner)).toBe("free")
			expect(Record.leaseState(withLease("A", "A:1", 0), 1000, 60, owner)).toBe("mine")
			expect(Record.leaseState(withLease("B", "B:1", 10), 100, 60, owner)).toBe("stale")
			expect(Record.leaseState(withLease("B", "B:1", 50), 100, 60, owner)).toBe("held")
		end)

		it("treats another session on the same server as someone else", function()
			expect(Record.leaseState(withLease("A", "A:2", 90), 100, 60, owner)).toBe("held")
		end)

		it("copies deeply", function()
			local record = withLease("A", "A:1", 0)
			local copied = Record.copy(record);
			(copied.meta.lease :: Record.Lease).renewedAt = 99
			expect((record.meta.lease :: Record.Lease).renewedAt).toBe(0)
		end)
	end)
end
