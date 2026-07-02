--!strict

-- L1. Schemas, codecs and validation

local Codecs = require("@self/Codecs")
local Schema = require("@self/Schema")
local Size = require("@self/Size")
local Storable = require("@self/Storable")
local Validate = require("@self/Validate")

--[=[
	@class Schema

	Checks and converts values against schemas built with `Geode.t`
]=]
local schema = {
	--[=[
		@function validate
		@within Schema
		@param schema Schema
		@param value unknown
		@param options ValidateOptions?
		@return ValidationResult
	]=]
	validate = Validate.validate,
	--[=[
		@function encode
		@within Schema
		@param schema Schema
		@param value unknown -- a live value that passed validation
		@return unknown -- the stored form
	]=]
	encode = Validate.encode,
	--[=[
		@function decode
		@within Schema
		@param schema Schema
		@param encoded unknown -- a stored value
		@return (boolean, unknown)
	]=]
	decode = Validate.decode,
	--[=[
		@function checkStorable
		@within Schema
		@param value unknown
		@param root string?
		@return ValidationResult -- every part of the value a DataStore couldn't store faithfully
	]=]
	checkStorable = Storable.check,
	--[=[
		@function measure
		@within Schema
		@param json Json
		@param value unknown
		@return number
	]=]
	measure = Size.measure,
	--[=[
		@function checkSize
		@within Schema
		@param json Json
		@param value unknown
		@param budget SizeBudget
		@return SizeReport
	]=]
	checkSize = Size.check,
}

-- Codecs read the datatype globals only when a value is decoded, so this loads fine outside Roblox
local codec = Codecs.build(Codecs.liveDatatypes)

return {
	t = table.freeze(Schema),
	codec = codec,
	schema = table.freeze(schema),
}
