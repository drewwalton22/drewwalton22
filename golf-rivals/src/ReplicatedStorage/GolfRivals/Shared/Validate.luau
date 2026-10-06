--!strict
--[[
	Validate.luau  (ReplicatedStorage.GolfRivals.Shared)

	Type/range guards for UNTRUSTED input (remote arguments). Remote arguments
	can be anything a cheater sends: nil, NaN, huge numbers, a 1M-entry table,
	a table with a metatable-free but weird shape. Every server handler runs its
	arguments through these before touching game state.

	All functions take `any` and return a plain boolean.
]]

local Validate = {}

-- A real, finite number. NaN is the only value not equal to itself; a NaN
-- slipping into physics or currency math poisons every later result.
function Validate.isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Finite number within [min, max] inclusive.
function Validate.numberInRange(value: any, min: number, max: number): boolean
	return Validate.isFiniteNumber(value) and value >= min and value <= max
end

-- Whole number within [min, max] inclusive.
function Validate.integerInRange(value: any, min: number, max: number): boolean
	return Validate.numberInRange(value, min, max) and math.floor(value) == value
end

-- Non-empty string no longer than maxLength (bounds memory and log spam).
function Validate.string(value: any, maxLength: number): boolean
	return type(value) == "string" and #value > 0 and #value <= maxLength
end

-- A proper array (keys exactly 1..n, no holes, no extra keys) of at most
-- maxLength entries, every element passing `elementCheck`.
function Validate.array(value: any, maxLength: number, elementCheck: (any) -> boolean): boolean
	if type(value) ~= "table" then
		return false
	end
	local count = 0
	for key, element in value do
		if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then
			return false -- dictionary-style or fractional key
		end
		count += 1
		if count > maxLength then
			return false
		end
		if not elementCheck(element) then
			return false
		end
	end
	-- #value == count means no holes: keys are exactly 1..count.
	return #value == count
end

-- True when `value` equals one of `allowed` (enum-style string check).
function Validate.oneOf(value: any, allowed: { string }): boolean
	return type(value) == "string" and table.find(allowed, value) ~= nil
end

return Validate
