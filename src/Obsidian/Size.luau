--!strict

-- Size of a value as a DataStore sees it. The limit is documented in characters of the JSON
-- encoding; this counts bytes, which are never fewer, so it errs on the safe side

local Types = require("../Quartz/Types")

export type Budget = {
	-- warn past this, the write still goes through
	soft: number?,
	-- refuse the write past this
	hard: number?,
}

export type Level = "ok" | "soft" | "hard"

export type Report = {
	size: number,
	level: Level,
}

local Size = {}

--[=[
	Bytes the encoded value takes

	@within Schema
	@param json Json -- from `services.json`
	@param value unknown -- a stored (encoded) value
	@return number
]=]
function Size.measure(json: Types.Json, value: unknown): number
	return #json:encode(value)
end

--[=[
	Measures a value and compares it to a budget

	@function checkSize
	@within Schema
	@return SizeReport
]=]
function Size.check(json: Types.Json, value: unknown, budget: Budget): Report
	if budget.soft and budget.hard then
		assert(budget.soft <= budget.hard, "the soft size budget must not exceed the hard one")
	end
	local size = Size.measure(json, value)
	local level: Level = "ok"
	if budget.hard and size > budget.hard then
		level = "hard"
	elseif budget.soft and size > budget.soft then
		level = "soft"
	end
	return { size = size, level = level }
end

return Size
