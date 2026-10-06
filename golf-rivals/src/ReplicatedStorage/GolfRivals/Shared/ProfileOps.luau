--!strict
--[[
	ProfileOps.luau  (ReplicatedStorage.GolfRivals.Shared)

	Every legal change to a profile goes through here: spending/earning
	currency, granting/removing items, equipping, buying and upgrading clubs.
	Each function VALIDATES FIRST and only then mutates, returning
	(ok, reason?) so server handlers can report why something failed.

	Server handlers call these; clients may call the read-only ones
	(canAfford, playerOvr, clubStats...) to grey out buttons, but the server
	is the only authority that mutates a profile.

	ATOMICITY: all functions are synchronous and never yield. A handler that
	does "spend, then grant" with no yield between the two cannot be
	interleaved with another request or a save snapshot (Luau is single-threaded
	between yields), so a player can't end up charged-but-not-granted.
	Callers must NOT yield (task.wait, remote invokes, DataStore) between a
	validation and the mutation it protects.

	RESERVED COPIES: an item stack has `OwnedItems[id]` copies. One copy is
	reserved (can't be sold or consumed by trade-up) if the item is a starter
	item or is currently equipped, so a player can never sell their way out of
	having a default or equipped cosmetic. `spareCount` is what's left over.
]]

local Types = require(script.Parent.Types)
local Config = require(script.Parent.Config)
local ItemDatabase = require(script.Parent.ItemDatabase)
local ClubDatabase = require(script.Parent.ClubDatabase)
local ProfileTemplate = require(script.Parent.ProfileTemplate)
local Validate = require(script.Parent.Validate)

type ProfileData = ProfileTemplate.ProfileData

local ProfileOps = {}

local STAT_IDS: { string } = { "Distance", "Accuracy", "Forgiveness" }
local MAX_ITEM_COPIES = 1e6

-- ---------------------------------------------------------------------------
-- Currency
-- ---------------------------------------------------------------------------

local function isPositiveInteger(value: any): boolean
	return Validate.isFiniteNumber(value) and value >= 1 and math.floor(value) == value
end

function ProfileOps.balance(data: ProfileData, currency: Types.CurrencyId): number
	return if currency == "Coins" then data.Coins else data.Gems
end

local function setBalance(data: ProfileData, currency: Types.CurrencyId, amount: number)
	if currency == "Coins" then
		data.Coins = amount
	else
		data.Gems = amount
	end
end

function ProfileOps.canAfford(data: ProfileData, price: Types.Price): boolean
	return isPositiveInteger(price.Amount) and ProfileOps.balance(data, price.Currency) >= price.Amount
end

-- Earn currency. Balances clamp at the configured cap (bounds duplication bugs).
function ProfileOps.add(data: ProfileData, currency: Types.CurrencyId, amount: number): (boolean, string?)
	if not isPositiveInteger(amount) then
		return false, "bad_amount"
	end
	local cap = if currency == "Coins" then Config.Economy.MaxCoins else Config.Economy.MaxGems
	setBalance(data, currency, math.min(cap, ProfileOps.balance(data, currency) + amount))
	if currency == "Coins" then
		data.Stats.TotalCoinsEarned += amount
	end
	return true, nil
end

function ProfileOps.spend(data: ProfileData, price: Types.Price): (boolean, string?)
	if not isPositiveInteger(price.Amount) then
		return false, "bad_amount"
	end
	local balance = ProfileOps.balance(data, price.Currency)
	if balance < price.Amount then
		return false, "insufficient_funds"
	end
	setBalance(data, price.Currency, balance - price.Amount)
	return true, nil
end

-- ---------------------------------------------------------------------------
-- Items
-- ---------------------------------------------------------------------------

function ProfileOps.ownedCount(data: ProfileData, itemId: string): number
	return data.OwnedItems[itemId] or 0
end

-- 1 if a copy is locked in (starter item or currently equipped), else 0.
function ProfileOps.reservedCount(data: ProfileData, itemId: string): number
	local item = ItemDatabase.get(itemId)
	if item == nil or ProfileOps.ownedCount(data, itemId) < 1 then
		return 0
	end
	if item.Default or data.EquippedItems[item.Slot] == itemId then
		return 1
	end
	return 0
end

-- Copies that may be sold or consumed.
function ProfileOps.spareCount(data: ProfileData, itemId: string): number
	return math.max(0, ProfileOps.ownedCount(data, itemId) - ProfileOps.reservedCount(data, itemId))
end

function ProfileOps.grantItem(data: ProfileData, itemId: string, count: number?): (boolean, string?)
	local n = count or 1
	if ItemDatabase.get(itemId) == nil then
		return false, "unknown_item"
	end
	if not isPositiveInteger(n) then
		return false, "bad_count"
	end
	data.OwnedItems[itemId] = math.min(MAX_ITEM_COPIES, ProfileOps.ownedCount(data, itemId) + n)
	return true, nil
end

-- Remove (sell / trade-up cost). Only spare copies can go.
function ProfileOps.removeItem(data: ProfileData, itemId: string, count: number?): (boolean, string?)
	local n = count or 1
	if ItemDatabase.get(itemId) == nil then
		return false, "unknown_item"
	end
	if not isPositiveInteger(n) then
		return false, "bad_count"
	end
	if ProfileOps.ownedCount(data, itemId) < 1 then
		return false, "not_owned"
	end
	if ProfileOps.spareCount(data, itemId) < n then
		return false, "insufficient_spare" -- would dip into the equipped/starter copy
	end
	local remaining = ProfileOps.ownedCount(data, itemId) - n
	data.OwnedItems[itemId] = if remaining > 0 then remaining else nil
	return true, nil
end

function ProfileOps.equipItem(data: ProfileData, itemId: any): (boolean, string?)
	local item = ItemDatabase.get(itemId)
	if item == nil then
		return false, "unknown_item"
	end
	if ProfileOps.ownedCount(data, item.Id) < 1 then
		return false, "not_owned"
	end
	data.EquippedItems[item.Slot] = item.Id
	return true, nil
end

-- ---------------------------------------------------------------------------
-- Clubs
-- ---------------------------------------------------------------------------

function ProfileOps.grantClub(data: ProfileData, clubId: string): (boolean, string?)
	if ClubDatabase.get(clubId) == nil then
		return false, "unknown_club"
	end
	data.OwnedClubs[clubId] = true
	return true, nil
end

-- Buy a club from the club shop for its coin price.
function ProfileOps.buyClub(data: ProfileData, clubId: any): (boolean, string?)
	local club = ClubDatabase.get(clubId)
	if club == nil then
		return false, "unknown_club"
	end
	if data.OwnedClubs[club.Id] then
		return false, "already_owned"
	end
	if club.Starter then
		return false, "not_for_sale" -- starter clubs are granted, never sold
	end
	local ok, reason = ProfileOps.spend(data, { Currency = "Coins", Amount = club.Price })
	if not ok then
		return false, reason
	end
	data.OwnedClubs[club.Id] = true
	return true, nil
end

function ProfileOps.equipClub(data: ProfileData, clubId: any): (boolean, string?)
	local club = ClubDatabase.get(clubId)
	if club == nil then
		return false, "unknown_club"
	end
	if not data.OwnedClubs[club.Id] then
		return false, "not_owned"
	end
	data.EquippedClubs[club.SlotLabel] = club.Id
	return true, nil
end

-- Upgrade levels for a club (all zero if never upgraded). Returns a COPY.
function ProfileOps.clubLevels(data: ProfileData, clubId: string): ProfileTemplate.ClubLevels
	local levels = data.ClubUpgrades[clubId]
	if levels == nil then
		return { Distance = 0, Accuracy = 0, Forgiveness = 0 }
	end
	return { Distance = levels.Distance, Accuracy = levels.Accuracy, Forgiveness = levels.Forgiveness }
end

-- Effective stats = base + upgrades (what SwingMath consumes).
function ProfileOps.clubStats(data: ProfileData, clubId: string): ClubDatabase.Stats?
	local club = ClubDatabase.get(clubId)
	if club == nil then
		return nil
	end
	local levels = ProfileOps.clubLevels(data, clubId)
	return {
		Distance = ClubDatabase.statAtLevel(club.BaseStats.Distance, levels.Distance),
		Accuracy = ClubDatabase.statAtLevel(club.BaseStats.Accuracy, levels.Accuracy),
		Forgiveness = ClubDatabase.statAtLevel(club.BaseStats.Forgiveness, levels.Forgiveness),
	}
end

-- Spend coins to raise one stat of an owned club by one level.
-- Returns (true, nil, newLevel) or (false, reason).
function ProfileOps.upgradeClub(data: ProfileData, clubId: any, stat: any): (boolean, string?, number?)
	local club = ClubDatabase.get(clubId)
	if club == nil then
		return false, "unknown_club", nil
	end
	if not Validate.oneOf(stat, STAT_IDS) then
		return false, "bad_stat", nil
	end
	if not data.OwnedClubs[club.Id] then
		return false, "not_owned", nil
	end

	local statName = stat :: string
	local levels = ProfileOps.clubLevels(data, club.Id)
	local level = (levels :: any)[statName] :: number
	local cost = ClubDatabase.upgradeCost(level)
	if cost == nil then
		return false, "max_level", nil
	end
	-- Don't sell upgrades that no longer do anything.
	local current = (ClubDatabase.statAtLevel((club.BaseStats :: any)[statName], level))
	if current >= Config.Clubs.StatCap then
		return false, "stat_capped", nil
	end

	local ok, reason = ProfileOps.spend(data, { Currency = "Coins", Amount = cost })
	if not ok then
		return false, reason, nil
	end
	(levels :: any)[statName] = level + 1
	data.ClubUpgrades[club.Id] = levels
	return true, nil, level + 1
end

-- Player OVR for the lobby/leaderboard: mean OVR of the clubs in the bag.
function ProfileOps.playerOvr(data: ProfileData): number
	local total, count = 0, 0
	for _, slot in ClubDatabase.BagSlots do
		local clubId = data.EquippedClubs[slot.Label]
		local stats = if clubId then ProfileOps.clubStats(data, clubId) else nil
		if stats then
			total += ClubDatabase.overall(stats)
			count += 1
		end
	end
	if count == 0 then
		return 0
	end
	return math.floor(total / count + 0.5)
end

return ProfileOps
