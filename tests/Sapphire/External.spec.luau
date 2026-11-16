--!strict

-- Records edited straight in the DataStore by a tool, outside a running Geode. The external write
-- rule has to keep servers from writing over the edit and caches from missing it

local Geode = require("../../src")
local Helpers = require("./Helpers")
local Profile = require("../../src/Sapphire/Profile")
local ProfileStore = require("../../src/Sapphire/ProfileStore")
local Record = require("../../src/Sapphire/Record")
local SharedStore = require("../../src/Opal/SharedStore")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")

type Any = any

local function load(
	universe: Universe.Universe,
	store: ProfileStore.ProfileStore,
	key: string
): Profile.Profile
	local result = universe.clock:run(function()
		return store:load(key)
	end)
	if not result.ok then
		error(`load failed: {result.error.kind} {result.error.message}`, 2)
	end
	return result.profile
end

-- What a tool does: read the key, apply the rule, write it back in one UpdateAsync
local function editOutside(
	universe: Universe.Universe,
	storeName: string,
	key: string,
	edit: (data: Any) -> Any
)
	local tool = universe:server({ jobId = "tool" })
	local result = universe.clock:run(function()
		return tool.dataStore(storeName):update(key, function(current: unknown, info: Any)
			local record = current :: Record.Record
			local written = Record.externalWrite(record, edit(record.data), {
				now = tool.clock:now(),
				id = tool.guid(),
			})
			return written, { userIds = if info then info.userIds else nil }
		end)
	end)
	assert(result.ok, "the external write failed")
end

local function oldProfile(): Record.Record
	local record = Record.new({ coins = 5, log = {} }, 10, 1)
	record.meta.revision = 7
	record.meta.receipts = { "r1" }
	record.meta.mailboxCursor = 3
	record.meta.lastSession = { session = "guid-old", revision = 7 }
	return record
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Record.externalWrite", function()
		it("bumps the revision and marks the session as external", function()
			local stored = oldProfile()
			local written = Record.externalWrite(stored, { coins = 50, log = {} }, {
				now = 99,
				id = "abc",
			})
			expect((written.data :: Any).coins).toBe(50)
			expect(written.meta.revision).toBe(8)
			expect(written.meta.lastSession).toEqual({ session = "external:abc", revision = 8 })
			expect(written.meta.updatedAt).toBe(99)
		end)

		it("leaves the rest of meta alone", function()
			local stored = oldProfile()
			stored.meta.lease = {
				jobId = "A",
				placeId = 1,
				session = "guid-a",
				acquiredAt = 1,
				renewedAt = 2,
			}
			stored.meta.erasedAt = 4
			local written = Record.externalWrite(stored, {}, { now = 99, id = "abc" })
			expect(written.meta.lease).toEqual(stored.meta.lease)
			expect(written.meta.format).toBe(Record.FORMAT)
			expect(written.meta.schemaVersion).toBe(1)
			expect(written.meta.receipts).toEqual({ "r1" })
			expect(written.meta.mailboxCursor).toBe(3)
			expect(written.meta.createdAt).toBe(10)
			expect(written.meta.erasedAt).toBe(4)
			local keys = {}
			for name in written.meta :: Any do
				table.insert(keys, name)
			end
			table.sort(keys)
			local before = { "lastSession", "updatedAt", "revision" }
			for name in stored.meta :: Any do
				if not table.find(before, name) then
					table.insert(before, name)
				end
			end
			table.sort(before)
			expect(keys).toEqual(before)
		end)

		it("doesn't add a format to records that had none", function()
			local stored: Any = { data = {}, meta = { schemaVersion = 1, revision = 2 } }
			local written = Record.externalWrite(stored, {}, { now = 5, id = "x" })
			expect(written.meta.format).toBeNil()
		end)

		it("never changes the record it was given", function()
			local stored = oldProfile()
			local data = { coins = 50, nested = { a = 1 } }
			local written = Record.externalWrite(stored, data, { now = 99, id = "abc" })
			expect(stored.meta.revision).toBe(7)
			expect((stored.data :: Any).coins).toBe(5);
			(written.data :: Any).nested.a = 2
			expect(data.nested.a).toBe(1)
		end)

		it("refuses values that aren't records and options without an id", function()
			expect(function()
				Record.externalWrite({ data = {} }, {}, { now = 1, id = "x" })
			end).toThrow("stored Geode record")
			expect(function()
				Record.externalWrite(oldProfile(), {}, { now = 1, id = "" })
			end).toThrow("fresh id")
			expect(function()
				Record.externalWrite(oldProfile(), {}, { id = "x" } :: Any)
			end).toThrow("now")
		end)

		it("tells external writes from Geode's own", function()
			local stored = oldProfile()
			expect(Record.writtenExternally(stored)).toBe(false)
			local written = Record.externalWrite(stored, {}, { now = 1, id = "x" })
			expect(Record.writtenExternally(written)).toBe(true)
			written.meta.revision += 1
			expect(Record.writtenExternally(written)).toBe(false)
		end)

		it("is public as Geode.Raw.externalWrite, next to the record format", function()
			expect(Geode.Raw.externalWrite).toBe(Record.externalWrite)
			expect(Geode.Raw.recordFormat).toBe(1)
		end)
	end)

	describe("external writes to profiles", function()
		it("loads the edited data", function()
			local universe = Universe.new()
			local store = Helpers.store(universe:server({ jobId = "A" }))
			local profile = load(universe, store, "1")
			profile:increment("coins", 5)
			universe.clock:run(function()
				return profile:release()
			end)
			local released = (Helpers.stored(universe, "1") :: Record.Record).meta.revision

			editOutside(universe, Helpers.STORE, "1", function(data)
				data.coins = 500
				return data
			end)

			local storeB = Helpers.store(universe:server({ jobId = "B" }))
			local again = load(universe, storeB, "1")
			expect(again:get("coins")).toBe(500)
			expect(again:revision()).toBe(released + 1)

			again:increment("coins", 1)
			universe.clock:run(function()
				return again:release()
			end)
			local record = Helpers.stored(universe, "1") :: Record.Record
			expect((record.data :: Any).coins).toBe(501)
			expect(record.meta.revision).toBe(released + 2)
		end)

		it("keeps a server whose release landed from taking the profile back", function()
			local universe = Universe.new()
			local server = universe:server({ jobId = "A" })
			local store = Helpers.store(server, { autosaveInterval = 10 })
			local profile = load(universe, store, "1")
			local lostBecause = ""
			profile.sessionLost:connect(function(reason: string)
				lostBecause = reason
			end)
			profile:increment("coins", 1)
			-- The release lands but every try reports failure, so A still thinks it's active
			server:inject({
				store = Helpers.STORE,
				method = "update",
				fault = { landed = 501 },
				times = 5,
			})
			universe.clock:run(function()
				return profile:release()
			end)
			expect(profile:isActive()).toBe(true)

			editOutside(universe, Helpers.STORE, "1", function(data)
				data.coins = 500
				return data
			end)

			-- Without the edit this autosave would take the lease back, see Landed.spec
			profile:increment("coins", 1)
			universe.clock:advance(10)
			expect(profile:state()).toBe("lost")
			local record = Helpers.stored(universe, "1") :: Record.Record
			expect((record.data :: Any).coins).toBe(500)
			expect(record.meta.lease).toBeNil()
			expect(Record.writtenExternally(record)).toBe(true)
			expect(lostBecause).toBe(
				"the profile was edited outside Geode after this server let it go"
			)
		end)

		it("keeps a retried release from writing over the edit", function()
			local universe = Universe.new()
			local server = universe:server({ jobId = "A" })
			local store = Helpers.store(server)
			local profile = load(universe, store, "1")
			server:inject({
				store = Helpers.STORE,
				method = "update",
				fault = { landed = 501 },
				times = 5,
			})
			universe.clock:run(function()
				return profile:release()
			end)

			editOutside(universe, Helpers.STORE, "1", function(data)
				data.coins = 500
				return data
			end)

			local retry = universe.clock:run(function()
				return profile:release()
			end)
			expect(retry.ok).toBe(false)
			local record = Helpers.stored(universe, "1") :: Record.Record
			expect((record.data :: Any).coins).toBe(500)
		end)

		it("is written over by a server that still holds the lease", function()
			-- The rule only protects records nobody holds. This pins down why tools must check
			local universe = Universe.new()
			local store = Helpers.store(universe:server({ jobId = "A" }))
			local profile = load(universe, store, "1")
			editOutside(universe, Helpers.STORE, "1", function(data)
				data.coins = 500
				return data
			end)
			universe.clock:run(function()
				return profile:save()
			end)
			expect(profile:isActive()).toBe(true)
			local record = Helpers.stored(universe, "1") :: Record.Record
			expect((record.data :: Any).coins).toBe(0)
		end)
	end)

	describe("external writes to shared stores", function()
		local function shared(
			server: Universe.MockServer,
			cacheTtl: number
		): SharedStore.SharedStore
			return SharedStore.new({
				name = "Guilds",
				template = { bank = 0 },
				services = server,
				cacheTtl = cacheTtl,
			})
		end

		local function bank(store: SharedStore.SharedStore): unknown
			local result = store:get("g1", "bank")
			assert(result.ok, "read failed")
			return result.value
		end

		local function setBank(data: Any): Any
			data.bank = 500
			return data
		end

		it("shows up once the cache expires", function()
			local universe = Universe.new()
			local guilds = shared(universe:server({ jobId = "A" }), 10)
			universe.clock:run(function()
				guilds:increment("g1", "bank", 5)
				expect(bank(guilds)).toBe(5)
			end)
			editOutside(universe, "Guilds", "g1", setBank)
			universe.clock:advance(10)
			universe.clock:run(function()
				expect(bank(guilds)).toBe(500)
			end)
		end)

		it("shows up sooner when the tool announces the new revision", function()
			local universe = Universe.new({ messagingLatency = 0.1 })
			local guilds = shared(universe:server({ jobId = "A" }), 1000)
			universe.clock:run(function()
				guilds:increment("g1", "bank", 5)
				expect(bank(guilds)).toBe(5)
			end)
			editOutside(universe, "Guilds", "g1", setBank)
			local tool = universe:server({ jobId = "tool" })
			universe.clock:run(function()
				tool.messaging:publish(
					"geode_invalidate_Guilds",
					{ key = "g1", from = "tool", revision = 2 }
				)
			end)
			universe.clock:advance(1)
			universe.clock:run(function()
				expect(bank(guilds)).toBe(500)
			end)
		end)

		it("ignores an announcement naming the revision it already has", function()
			local universe = Universe.new({ messagingLatency = 0.1 })
			local guilds = shared(universe:server({ jobId = "A" }), 1000)
			universe.clock:run(function()
				guilds:increment("g1", "bank", 5)
				expect(bank(guilds)).toBe(5)
			end)
			editOutside(universe, "Guilds", "g1", setBank)
			local tool = universe:server({ jobId = "tool" })
			universe.clock:run(function()
				tool.messaging:publish(
					"geode_invalidate_Guilds",
					{ key = "g1", from = "tool", revision = 1 }
				)
			end)
			universe.clock:advance(1)
			universe.clock:run(function()
				expect(bank(guilds)).toBe(5)
			end)
		end)

		it("keeps writes from servers going on top of the edit", function()
			local universe = Universe.new()
			local guilds = shared(universe:server({ jobId = "A" }), 0)
			universe.clock:run(function()
				guilds:increment("g1", "bank", 5)
			end)
			editOutside(universe, "Guilds", "g1", setBank)
			universe.clock:run(function()
				guilds:increment("g1", "bank", 1)
				expect(bank(guilds)).toBe(501)
			end)
		end)
	end)
end
