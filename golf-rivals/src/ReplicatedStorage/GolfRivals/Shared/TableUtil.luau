--!strict
--[[
	TableUtil.luau  (ReplicatedStorage.GolfRivals.Shared)

	Tiny table helpers used by the database modules.

	Why freeze? The databases are shared (required by both server and client
	and by many systems). A single accidental write such as
	`item.Rarity = "Mythical"` would silently corrupt every later lookup, so we
	freeze them after construction: writes now throw immediately.
]]

local TableUtil = {}

-- Recursively freezes a table and every table nested inside it.
function TableUtil.deepFreeze(value: any): any
	if type(value) ~= "table" or table.isfrozen(value) then
		return value
	end
	for _, child in value do
		TableUtil.deepFreeze(child)
	end
	return table.freeze(value)
end

-- Recursive copy of plain data tables (no metatables, no cycles). Used to
-- snapshot profiles for saving and to hand clients their own copy.
function TableUtil.deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy: { [any]: any } = {}
	for key, child in value do
		copy[key] = TableUtil.deepCopy(child)
	end
	return copy
end

-- Returns the keys of a dictionary sorted ascending. Dictionary iteration
-- order is NOT stable in Luau, and anything that must be identical on every
-- server (daily shop rotation, drop pools) has to iterate in a fixed order.
function TableUtil.sortedKeys(dict: { [string]: any }): { string }
	local keys: { string } = {}
	for key in dict do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

return TableUtil
