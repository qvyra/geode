--!strict

-- Runs the live checks when a playtest starts in Studio. Prints one line of JSON with every
-- result and keeps the same JSON in an attribute, so tools can tell pass, fail and observed
-- apart without reading the whole output

local HttpService = game:GetService("HttpService")

local Checks = require("./Checks")

local report = Checks.run()
local encoded = HttpService:JSONEncode(report)
script:SetAttribute("Results", encoded)
print(`GEODE_CHECK_RESULTS {encoded}`)
