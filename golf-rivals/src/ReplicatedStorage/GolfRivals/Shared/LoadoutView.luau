--!strict
--[[
	LoadoutView.luau  (ReplicatedStorage.GolfRivals.Shared)

	The Club Loadout / Upgrade screen (mockup panel 2): the 14-club bag, the selected
	club's stats and upgrade costs, the other clubs you own or can buy for that slot,
	and the skins for that club class. Pure functions of the profile.
]]

local Types = require(script.Parent.Types)
local Config = require(script.Parent.Config)
local ClubDatabase = require(script.Parent.ClubDatabase)
local ItemDatabase = require(script.Parent.ItemDatabase)
local ProfileOps = require(script.Parent.ProfileOps)
local ProfileTemplate = require(script.Parent.ProfileTemplate)
local Rarity = require(script.Parent.Rarity)

type ProfileData = ProfileTemplate.ProfileData

export type SlotRow = {
	Label: string,
	DisplayName: string,
	ClubId: string,
	ClubName: string,
	Ovr: number,
	Rarity: Types.RarityId,
	Selected: boolean,
}

export type StatRow = {
	Stat: Types.StatId,
	Value: number, -- with upgrades
	Base: number,
	Level: number,
	MaxLevel: number,
	MaxValue: number,
	UpgradeCost: number?, -- nil at max level
	CanUpgrade: boolean,
	Reason: string?, -- why not, e.g. "Need 700 coins"
}

export type Detail = {
	ClubId: string,
	Name: string,
	Brand: string,
	Rarity: Types.RarityId,
	LoftDeg: number,
	Ovr: number,
	Stats: { StatRow },
}

export type OwnedClub = { ClubId: string, Name: string, Ovr: number, Rarity: Types.RarityId, Equipped: boolean }
export type ShopClub = { ClubId: string, Name: string, Ovr: number, Rarity: Types.RarityId, Price: number, CanAfford: boolean }
export type Skin = { ItemId: string, Name: string, Rarity: Types.RarityId, Color: Types.RGB, Owned: boolean, Equipped: boolean, Primary: Types.RGB?, Secondary: Types.RGB? }

local LoadoutView = {}

local STATS: { Types.StatId } = { "Distance", "Accuracy", "Forgiveness" }

local function ovrOf(profile: ProfileData, clubId: string): number
	local stats = ProfileOps.clubStats(profile, clubId)
	return if stats then ClubDatabase.overall(stats) else 0
end

function LoadoutView.slots(profile: ProfileData, selectedLabel: string): { SlotRow }
	local rows: { SlotRow } = {}
	for _, slot in ClubDatabase.BagSlots do
		local clubId = profile.EquippedClubs[slot.Label]
		local club = if clubId then ClubDatabase.get(clubId) else nil
		if club then
			table.insert(rows, {
				Label = slot.Label,
				DisplayName = slot.DisplayName,
				ClubId = club.Id,
				ClubName = club.Name,
				Ovr = ovrOf(profile, club.Id),
				Rarity = club.Rarity,
				Selected = slot.Label == selectedLabel,
			})
		end
	end
	return rows
end

function LoadoutView.detail(profile: ProfileData, clubId: string): Detail?
	local club = ClubDatabase.get(clubId)
	if club == nil then
		return nil
	end
	local levels = ProfileOps.clubLevels(profile, clubId)
	local current = ProfileOps.clubStats(profile, clubId) :: ClubDatabase.Stats
	local maxLevel = Config.Clubs.MaxUpgradeLevel
	local rows: { StatRow } = {}
	for _, stat in STATS do
		local level = (levels :: any)[stat] :: number
		local value = (current :: any)[stat] :: number
		local base = (club.BaseStats :: any)[stat] :: number
		local cost = ClubDatabase.upgradeCost(level)
		local reason: string? = nil
		if cost == nil then
			reason = "Max level"
		elseif value >= Config.Clubs.StatCap then
			reason = "Stat maxed"
		elseif profile.Coins < cost then
			reason = `Need {cost - profile.Coins} more coins`
		end
		table.insert(rows, {
			Stat = stat,
			Value = value,
			Base = base,
			Level = level,
			MaxLevel = maxLevel,
			MaxValue = ClubDatabase.statAtLevel(base, maxLevel),
			UpgradeCost = cost,
			CanUpgrade = reason == nil,
			Reason = reason,
		})
	end
	return {
		ClubId = club.Id, Name = club.Name, Brand = club.Brand, Rarity = club.Rarity,
		LoftDeg = club.LoftDeg, Ovr = ClubDatabase.overall(current), Stats = rows,
	}
end

local function byRarityThenName(a: { Rarity: Types.RarityId, Name: string }, b: { Rarity: Types.RarityId, Name: string }): boolean
	local ta, tb = Rarity.Info[a.Rarity].Tier, Rarity.Info[b.Rarity].Tier
	if ta ~= tb then
		return ta < tb
	end
	return a.Name < b.Name
end

-- Clubs you own for a bag slot (equip any of them).
function LoadoutView.ownedFor(profile: ProfileData, label: string): { OwnedClub }
	local list: { OwnedClub } = {}
	for _, club in ClubDatabase.Ordered do
		if club.SlotLabel == label and profile.OwnedClubs[club.Id] then
			table.insert(list, {
				ClubId = club.Id, Name = club.Name, Ovr = ovrOf(profile, club.Id), Rarity = club.Rarity,
				Equipped = profile.EquippedClubs[label] == club.Id,
			})
		end
	end
	table.sort(list, byRarityThenName)
	return list
end

-- Clubs for sale for a bag slot (not owned, not starters), cheapest first.
function LoadoutView.shopFor(profile: ProfileData, label: string): { ShopClub }
	local list: { ShopClub } = {}
	for _, club in ClubDatabase.Ordered do
		if club.SlotLabel == label and not club.Starter and not profile.OwnedClubs[club.Id] then
			table.insert(list, {
				ClubId = club.Id, Name = club.Name,
				Ovr = ClubDatabase.overall(club.BaseStats), Rarity = club.Rarity,
				Price = club.Price, CanAfford = profile.Coins >= club.Price,
			})
		end
	end
	table.sort(list, function(a: ShopClub, b: ShopClub)
		return a.Price < b.Price
	end)
	return list
end

-- Every skin for a club class, owned ones flagged (the rest show as locked).
function LoadoutView.skinsFor(profile: ProfileData, class: Types.ClubClass): { Skin }
	local list: { Skin } = {}
	for _, item in ItemDatabase.Ordered do
		if item.Category == "ClubSkin" and item.Slot == class then
			table.insert(list, {
				ItemId = item.Id, Name = item.Name, Rarity = item.Rarity, Color = Rarity.Info[item.Rarity].Color,
				Owned = ProfileOps.ownedCount(profile, item.Id) > 0,
				Equipped = profile.EquippedItems[class] == item.Id,
				Primary = item.Visual.Primary, Secondary = item.Visual.Secondary,
			})
		end
	end
	table.sort(list, byRarityThenName)
	return list
end

function LoadoutView.playerOvr(profile: ProfileData): number
	return ProfileOps.playerOvr(profile)
end

return LoadoutView
