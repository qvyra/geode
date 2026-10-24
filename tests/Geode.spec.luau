--!strict

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Geode = require("../src")
local Spec = require("./_lib/Spec")

return function(spec: Spec.Api)
	local describe, it, expect = spec.describe, spec.it, spec.expect

	describe("Geode", function()
		it("exposes a semantic version", function()
			expect(string.match(Geode.version, "^%d+%.%d+%.%d+$")).never.toBeNil()
		end)

		it("is frozen so callers can't patch the public surface", function()
			expect(table.isfrozen(Geode)).toBe(true)
		end)
	end)

	describe("Finding Geode in a place", function()
		-- the main module's tag and attribute come from this file, so a Rojo build, a Wally or npm
		-- install and the released model file all carry them
		local meta = serde.decode("json", fs.readFile("src/init.meta.json"))

		it("tags the main module so tools can find it wherever it's put", function()
			expect(meta.properties.Tags).toEqual({ "Geode" })
		end)

		it("keeps GeodeVersion and every package version at Geode.version", function()
			expect(meta.attributes.GeodeVersion).toBe(Geode.version)
			local wally = serde.decode("toml", fs.readFile("wally.toml"))
			expect(wally.package.version).toBe(Geode.version)
			local npm = serde.decode("json", fs.readFile("package.json"))
			expect(npm.version).toBe(Geode.version)
		end)
	end)
end
