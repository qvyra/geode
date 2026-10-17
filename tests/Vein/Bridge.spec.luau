--!strict

local Helpers = require("../Sapphire/Helpers")
local Lune = require("../Obsidian/LuneDatatypes")
local MockBridge = require("../../src/Quartz/Mock/Bridge")
local Polish = require("../../src/Polish")
local Spec = require("../_lib/Spec")
local Universe = require("../../src/Quartz/Mock/Universe")
local Validate = require("../../src/Obsidian/Validate")
local Vein = require("../../src/Vein")
local VeinBridge = require("../../src/Vein/Bridge")
local VeinRegistry = require("../../src/Vein/Registry")
local t = require("../../src/Obsidian/Schema")

local codec = Lune.codec
local roblox = Lune.roblox

type Any = any

local function fresh()
	VeinRegistry._reset()
	Vein.setBridgeEnabled(true)
end

local function loaded(
	server: Universe.MockServer,
	universe: Universe.Universe,
	extra: { [string]: any }?
)
	local store = Helpers.store(server, extra)
	local result = universe.clock:run(function()
		return store:load("p1")
	end)
	assert(result.ok, "load failed")
	return store, result.profile
end

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Studio bridge", function()
		it(
			"opens in a Studio playtest once a store exists, and says which versions it speaks",
			function()
				fresh()
				local universe = Universe.new()
				local server = universe:server({ studio = true })
				expect(server.tooling:attributes()).toBeNil()
				Helpers.store(server, { studio = "real" })
				local attributes = server.tooling:attributes() :: Any
				expect(attributes.BridgeVersion).toBe(VeinBridge.VERSION)
				expect(type(attributes.GeodeVersion)).toBe("string")

				local hello = server.tooling:request({ kind = "hello" }) :: Any
				expect(hello.bridge).toBe(VeinBridge.VERSION)
			end
		)

		it("lists what it can do and the protocols it speaks", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			Helpers.store(server, { studio = "real" })
			local attributes = server.tooling:attributes() :: Any
			expect(attributes.BridgeMinVersion).toBe(VeinBridge.MIN_VERSION)
			local hello = server.tooling:request({ kind = "hello" }) :: Any
			expect(hello.minBridge).toBe(VeinBridge.MIN_VERSION)
			expect(table.find(hello.features, "read")).never.toBeNil()
			expect(table.find(hello.features, "guards")).never.toBeNil()
		end)

		it("refuses tools that speak a protocol outside its range", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			Helpers.store(server, { studio = "real" })
			local ok =
				server.tooling:request({ kind = "hello", protocol = VeinBridge.VERSION }) :: Any
			expect(ok.error).toBeNil()
			local tooNew =
				server.tooling:request({ kind = "hello", protocol = VeinBridge.VERSION + 1 }) :: Any
			expect(string.find(tooNew.error, "update Geode", 1, true) ~= nil).toBe(true)
			local tooOld = server.tooling:request({
				kind = "hello",
				protocol = VeinBridge.MIN_VERSION - 1,
			}) :: Any
			expect(tooOld.error).never.toBeNil()
			expect(tooOld.features).toBeNil()
		end)

		it("never opens outside Studio", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server()
			Helpers.store(server)
			expect(server.tooling:attributes()).toBeNil()
		end)

		it("answers snapshots, open profiles and profile data", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			local _, profile = loaded(server, universe, { studio = "real" })
			profile:increment("coins", 7)

			local snapshot = server.tooling:request({ kind = "snapshot" }) :: Any
			expect(snapshot.idle).toBe(false)

			local profiles = server.tooling:request({ kind = "profiles" }) :: Any
			expect(profiles.stores[1].name).toBe(Helpers.STORE)
			expect(profiles.stores[1].keys).toEqual({ "p1" })
			expect(profiles.stores[1].studio).toBe("real")

			local answer = server.tooling:request({
				kind = "profile",
				store = Helpers.STORE,
				key = "p1",
			}) :: Any
			expect(answer.data.coins).toBe(7)
			expect(answer.state).toBe("active")
			expect(answer.revision).toBe(profile:revision())

			local missing = server.tooling:request({
				kind = "profile",
				store = Helpers.STORE,
				key = "nope",
			}) :: Any
			expect(missing.missing).toBe(true)
			local unknown = server.tooling:request({ kind = "edit" }) :: Any
			expect(unknown.error).never.toBeNil()
		end)

		it("says where each store keeps its Studio data", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			loaded(server, universe)
			local profiles = server.tooling:request({ kind = "profiles" }) :: Any
			expect(profiles.stores[1].studio).toBe("mock")
		end)

		it("forwards telemetry", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			loaded(server, universe, { studio = "real" })
			local kinds = {}
			for _, message in server.tooling:messages() do
				table.insert(kinds, (message :: Any).type)
			end
			expect(table.find(kinds, "profileLoaded")).never.toBeNil()
		end)

		it("stays shut when Geode.setup turns it off, and closes one already open", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			Helpers.store(server, { studio = "real" })
			expect(server.tooling:attributes()).never.toBeNil()
			Polish.setup({ services = server, studioBridge = false })
			expect(server.tooling:attributes()).toBeNil()

			local other = universe:server({ studio = true })
			Helpers.store(other, { studio = "real" })
			expect(other.tooling:attributes()).toBeNil()
			Polish._reset()
		end)

		it("round trips every codec through the bridge format", function()
			fresh()
			local universe = Universe.new()
			local server = universe:server({ studio = true })
			local schema = t.struct({
				position = codec.Vector3,
				offset = codec.Vector2,
				pivot = codec.CFrame,
				tint = codec.Color3,
				size = codec.UDim2,
				seen = codec.DateTime,
				brick = codec.BrickColor,
				material = codec.EnumItem(roblox.Enum.Material :: any),
				trail = t.array(codec.Vector3),
			})
			local template = {
				position = roblox.Vector3.new(1.5, -2, 3),
				offset = roblox.Vector2.new(4, 5),
				pivot = roblox.CFrame.new(1, 2, 3),
				tint = roblox.Color3.new(0.5, 0.25, 1),
				size = roblox.UDim2.new(0.5, 10, 1, -5),
				seen = Lune.DateTime.fromUnixTimestamp(1700000000),
				brick = roblox.BrickColor.new(21),
				material = roblox.Enum.Material.Plastic,
				trail = { roblox.Vector3.new(0, 1, 0), roblox.Vector3.new(0, 2, 0) },
			}
			loaded(server, universe, { studio = "real", schema = schema, template = template })

			-- The request goes through MockBridge.copy, which refuses anything a Bindable mangles
			local answer = server.tooling:request({
				kind = "profile",
				store = Helpers.STORE,
				key = "p1",
			}) :: Any
			expect(answer.codecs.position).toBe("Vector3")
			expect(answer.codecs.material).toBe("EnumItem(Enum.Material)")
			expect(answer.codecs["trail[2]"]).toBe("Vector3")

			local ok, decoded = Validate.decode(schema, answer.data)
			expect(ok).toBe(true)
			local value = decoded :: Any
			expect(value.position).toBe(template.position)
			expect(value.offset).toBe(template.offset)
			expect(value.pivot.Position).toBe(template.pivot.Position)
			expect(value.tint).toBe(template.tint)
			expect(value.size).toBe(template.size)
			expect(value.seen.unixTimestampMillis).toBe(1700000000000)
			expect(value.brick.Number).toBe(21)
			expect(value.material).toBe(roblox.Enum.Material.Plastic)
			expect(value.trail[2]).toBe(template.trail[2])
		end)

		it("refuses payloads a Bindable would mangle", function()
			expect(function()
				local mixed: { [unknown]: unknown } = { 1, 2 }
				mixed.x = 3
				MockBridge.copy(mixed)
			end).toThrow("mixes key types")
			expect(function()
				MockBridge.copy({ [1] = "a", [3] = "c" })
			end).toThrow("holes")
			expect(MockBridge.copy({ a = { 1, 2 } })).toEqual({ a = { 1, 2 } })
		end)
	end)
end
