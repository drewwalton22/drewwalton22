--!strict
--[[
	TradeUpView.luau  (ReplicatedStorage.GolfRivals.Shared)

	The Trade-Up Contract screen (mockup panel 7): pick 5 items of one rarity (and,
	per Config, one category) and preview the next rarity up. These functions mirror
	the server's Economy.tradeUp rules so the UI can refuse bad picks immediately;
	the server still re-validates everything.

	A selection is an array of item ids; the same id may appear several times, up to
	the number of SPARE copies owned (starter and equipped copies are protected).
]]

local Types = require(script.Parent.Types)
local Config = require(script.Parent.Config)
local ItemDatabase = require(script.Parent.ItemDatabase)
local ProfileOps = require(script.Parent.ProfileOps)
local ProfileTemplate = require(script.Parent.ProfileTemplate)
local Rarity = require(script.Parent.Rarity)
local ShopView = require(script.Parent.ShopView)

export type Entry = {
	ItemId: string,
	Name: string,
	Rarity: Types.RarityId,
	Category: Types.ItemCategory,
	SlotLabel: string,
	Color: Types.RGB,
	Spare: number, -- copies available to trade
	Selected: number, -- copies already in the selection
	Primary: Types.RGB?,
	Secondary: Types.RGB?,
}

export type State = {
	Count: number,
	Needed: number,
	Rarity: Types.RarityId?,
	Category: Types.ItemCategory?,
	NextRarity: Types.RarityId?,
	Valid: boolean, -- ready to submit
	Message: string,
}

local TradeUpView = {}

local function countIn(selection: { string }, id: string): number
	local n = 0
	for _, s in selection do
		if s == id then
			n += 1
		end
	end
	return n
end

-- Every tradable item (spare copies, not Mythical), highest rarity first.
function TradeUpView.inventory(profile: ProfileTemplate.ProfileData, selection: { string }): { Entry }
	local list: { Entry } = {}
	for _, item in ItemDatabase.Ordered do
		local spare = ProfileOps.spareCount(profile, item.Id)
		if spare > 0 and Rarity.nextTier(item.Rarity) ~= nil then
			table.insert(list, {
				ItemId = item.Id, Name = item.Name, Rarity = item.Rarity, Category = item.Category,
				SlotLabel = ShopView.slotLabel(item), Color = Rarity.Info[item.Rarity].Color, Spare = spare,
				Selected = countIn(selection, item.Id), Primary = item.Visual.Primary, Secondary = item.Visual.Secondary,
			})
		end
	end
	table.sort(list, function(a: Entry, b: Entry)
		local ta, tb = Rarity.Info[a.Rarity].Tier, Rarity.Info[b.Rarity].Tier
		if ta ~= tb then
			return ta > tb
		end
		return a.Name < b.Name
	end)
	return list
end

function TradeUpView.canAdd(profile: ProfileTemplate.ProfileData, selection: { string }, itemId: string): (boolean, string?)
	local item = ItemDatabase.get(itemId)
	if item == nil then
		return false, "Unknown item"
	end
	if #selection >= Config.TradeUp.InputCount then
		return false, "The contract is full"
	end
	if Rarity.nextTier(item.Rarity) == nil then
		return false, "Mythical items can't be traded up"
	end
	if countIn(selection, itemId) >= ProfileOps.spareCount(profile, itemId) then
		return false, "No spare copies left"
	end
	local first = if selection[1] then ItemDatabase.get(selection[1]) else nil
	if first then
		if item.Rarity ~= first.Rarity then
			return false, `Add {first.Rarity} items only`
		end
		if Config.TradeUp.RequireSameCategory and item.Category ~= first.Category then
			return false, "Keep to one item type (skins, animations or ball items)"
		end
	end
	return true, nil
end

-- New selection with `itemId` appended, or the same selection if it can't be added.
function TradeUpView.add(profile: ProfileTemplate.ProfileData, selection: { string }, itemId: string): { string }
	local result = table.clone(selection)
	if TradeUpView.canAdd(profile, selection, itemId) then
		table.insert(result, itemId)
	end
	return result
end

function TradeUpView.remove(selection: { string }, index: number): { string }
	local result = table.clone(selection)
	if index >= 1 and index <= #result then
		table.remove(result, index)
	end
	return result
end

function TradeUpView.state(selection: { string }): State
	local needed = Config.TradeUp.InputCount
	local first = if selection[1] then ItemDatabase.get(selection[1]) else nil
	local nextRarity: Types.RarityId? = if first then Rarity.nextTier(first.Rarity) else nil
	local valid = #selection == needed and first ~= nil and nextRarity ~= nil
	local message: string
	if first == nil then
		message = `Pick {needed} items of the same rarity`
	elseif #selection < needed then
		message = `{#selection} / {needed} - add {needed - #selection} more {first.Rarity} item{if needed - #selection == 1 then "" else "s"}`
	else
		message = `Trade {needed} {first.Rarity} items for 1 {nextRarity or "?"} item`
	end
	return {
		Count = #selection, Needed = needed,
		Rarity = if first then first.Rarity else nil,
		Category = if first then first.Category else nil,
		NextRarity = nextRarity, Valid = valid, Message = message,
	}
end

return TradeUpView
