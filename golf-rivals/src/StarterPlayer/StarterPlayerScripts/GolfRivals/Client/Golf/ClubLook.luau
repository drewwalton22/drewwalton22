--!strict
--[[
	ClubLook.luau  (Client/Golf)

	What the club in a golfer's hands looks like: the colour and material of the
	club skin equipped for that category (EquippedItems[Class], e.g. "LongIron").
	Falls back to a plain dark head when nothing (or something unknown) is equipped.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local ClubStats = require(Shared.ClubStats)
local ItemDatabase = require(Shared.ItemDatabase)

local ClubLook = {}

-- (colour, material, isPutter) for the club in category `label` ("DR" ... "PT").
function ClubLook.forLabel(equippedItems: { [string]: string }?, label: string): (Color3?, Enum.Material?, boolean)
	local category = ClubStats.get(label)
	if category == nil then
		return nil, nil, false
	end
	local isPutter = category.Class == "Putter"
	local itemId = if equippedItems then equippedItems[category.Class] else nil
	local item = if itemId then ItemDatabase.get(itemId) else nil
	if item == nil then
		return nil, nil, isPutter
	end
	local color: Color3? = nil
	if item.Visual.Primary then
		local c = item.Visual.Primary :: { number }
		color = Color3.fromRGB(c[1], c[2], c[3])
	end
	local material: Enum.Material? = nil
	if item.Visual.Material then
		local ok, value = pcall(function(): any
			return (Enum.Material :: any)[item.Visual.Material]
		end)
		if ok and typeof(value) == "EnumItem" then
			material = value :: Enum.Material
		end
	end
	return color, material, isPutter
end

return ClubLook
