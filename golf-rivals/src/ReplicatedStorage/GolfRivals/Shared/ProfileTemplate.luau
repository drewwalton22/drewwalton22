--!strict
--[[
	ProfileTemplate.luau  (ReplicatedStorage.GolfRivals.Shared)

	The shape of a player's saved data, how a brand-new profile looks, and how a
	profile loaded from the DataStore is validated and repaired before the game
	ever touches it.

	PROFILE (SchemaVersion 2)
	  Coins / Gems          balances (non-negative integers, capped)
	  OwnedItems            itemId -> copy count (duplicates stack; they feed
	                        Sell and Trade-Up)
	  EquippedItems         slot ("Driver","LongIron","Swing","BallTrail",...) -> itemId
	  OwnedClubs            clubId -> true
	  EquippedClubs         category label ("DR","FW","LI","SI","WG","PT") -> clubId
	  ClubUpgrades          clubId -> { Power, Accuracy, Spin } levels
	  Earnings              today's lobby coin earnings (driving range / AFK zone),
	                        for the daily caps; reset when Day changes
	  Wheel                 daily wheelspin: last free spin time, bought spins,
	                        recent Robux receipt ids (added without a schema bump:
	                        fillMissing gives old profiles an empty Wheel)
	  Stats                 lifetime counters (quests/leaderboards read these)
	  Quests                owned by the quest system (filled in a later step)
	  Shop                  today's purchases, so a rotation item can't be bought twice
	  Meta                  CreatedAt / Sessions

	SCHEMA HISTORY
	  v1  14-club bag (D, 3W, 5W, 4i-9i, PW, GW, SW, LW, PT), stats Distance /
	      Accuracy / Forgiveness, five skin slots (Driver, Wood, Iron, Wedge, Putter).
	  v2  six club categories (ClubStats), stats Power / Accuracy / Spin, six skin
	      slots, Earnings section. migrateV1 maps every v1 club to its category
	      (keeping the highest upgrade levels when several merge), renames the
	      stats, and gives Iron skins to BOTH new iron slots so nothing is lost.

	LOAD PIPELINE  (`prepare`)
	  1. reject non-tables ("corrupt") and data from a NEWER schema ("too_new"):
	     an old server must never load, edit and save a newer profile, or it
	     would silently strip fields it doesn't know about
	  2. run migrations version -> version+1 until current
	  3. fill missing/mistyped fields from a fresh template
	  4. sanitize: drop items/clubs no longer in the catalogue, clamp balances,
	     un-equip anything not owned or in the wrong slot
	  5. ensure defaults: starter items/clubs owned and equipped
	Items removed from the game therefore vanish cleanly instead of breaking a
	player's loadout.
]]

local Types = require(script.Parent.Types)
local Config = require(script.Parent.Config)
local ItemDatabase = require(script.Parent.ItemDatabase)
local ClubDatabase = require(script.Parent.ClubDatabase)
local TableUtil = require(script.Parent.TableUtil)

export type ClubLevels = {
	Power: number,
	Accuracy: number,
	Spin: number,
}

export type ProfileData = {
	SchemaVersion: number,
	Coins: number,
	Gems: number,
	OwnedItems: { [string]: number },
	EquippedItems: { [string]: string },
	OwnedClubs: { [string]: boolean },
	EquippedClubs: { [string]: string },
	ClubUpgrades: { [string]: ClubLevels },
	Stats: {
		MatchesPlayed: number,
		Wins: number,
		Losses: number,
		HolesPlayed: number,
		CasesOpened: number,
		TradeUps: number,
		HolesInOne: number,
		LongestDriveYds: number,
		TotalCoinsEarned: number,
		FairwaysHit: number,
		ClubUpgrades: number,
		ShopPurchases: number,
		RookieWins: number,
		AmateurWins: number,
		ProWins: number,
		ChampionWins: number,
	},
	Quests: { [string]: any },
	Shop: {
		Rotation: number, -- shop rotation index these purchases belong to
		Purchased: { [string]: boolean },
	},
	Wheel: {
		LastFreeSpinAt: number, -- os.time() of the last FREE spin (24 h cooldown)
		ExtraSpins: number, -- bought with gems / Robux, used after the free one
		TotalSpins: number,
		Receipts: { string }, -- recent Robux PurchaseIds (makes grants idempotent)
	},
	Earnings: {
		Day: number, -- floor(os.time() / 86400) the counters belong to
		Range: number, -- coins earned at the driving range that day
		Afk: number, -- coins earned in the AFK lounge that day
	},
	Meta: {
		CreatedAt: number,
		Sessions: number,
	},
}

export type Migration = (data: any) -> ()

export type PrepareOptions = {
	CurrentVersion: number?,
	Migrations: { [number]: Migration }?,
}

local ProfileTemplate = {}

ProfileTemplate.CURRENT_VERSION = 2

local function tableOr(value: any): { [any]: any }
	return if type(value) == "table" then value else {}
end

local function level(value: any): number
	return if type(value) == "number" and value == value then value else 0
end

-- v1 -> v2: 14-club bag -> six categories, Distance/Forgiveness -> Power/Spin,
-- five skin slots -> six. Defensive against garbage (sanitize runs afterwards).
local function migrateV1(data: any)
	-- Owned clubs: each legacy club becomes its category's club of the same line.
	local owned: { [string]: boolean } = {}
	for oldId, flag in tableOr(data.OwnedClubs) do
		local newId = ClubDatabase.migrateLegacyId(oldId)
		if newId and flag then
			owned[newId] = true
		end
	end
	data.OwnedClubs = owned

	-- Upgrades: rename the stats; when clubs merge keep the best level per stat.
	local upgrades: { [string]: ClubLevels } = {}
	for oldId, levels in tableOr(data.ClubUpgrades) do
		local newId = ClubDatabase.migrateLegacyId(oldId)
		if newId and type(levels) == "table" then
			local merged = upgrades[newId] or { Power = 0, Accuracy = 0, Spin = 0 }
			merged.Power = math.max(merged.Power, level(levels.Distance))
			merged.Accuracy = math.max(merged.Accuracy, level(levels.Accuracy))
			merged.Spin = math.max(merged.Spin, level(levels.Forgiveness))
			upgrades[newId] = merged
		end
	end
	data.ClubUpgrades = upgrades

	-- Equipped clubs: the club from the category's "main" legacy slot wins.
	local equipped: { [string]: string } = {}
	for oldLabel, oldId in tableOr(data.EquippedClubs) do
		local newLabel = if type(oldLabel) == "string" then ClubDatabase.LegacyLabelMap[oldLabel] else nil
		local newId = ClubDatabase.migrateLegacyId(oldId)
		if newLabel and newId and (equipped[newLabel] == nil or ClubDatabase.LegacyPreferred[newLabel] == oldLabel) then
			equipped[newLabel] = newId
		end
	end
	data.EquippedClubs = equipped

	-- Skins: "_wood" -> "_fairwaywood"; "_iron" -> both "_longiron" and "_shortiron".
	local function skinTargets(itemId: any): { string }?
		if type(itemId) ~= "string" or string.sub(itemId, 1, 5) ~= "skin_" then
			return nil
		end
		local base = string.match(itemId, "^(.*)_wood$")
		if base then
			return { base .. "_fairwaywood" }
		end
		base = string.match(itemId, "^(.*)_iron$")
		if base then
			return { base .. "_longiron", base .. "_shortiron" }
		end
		return nil
	end
	local items: { [any]: any } = {}
	for itemId, count in tableOr(data.OwnedItems) do
		local targets = skinTargets(itemId)
		if targets then
			for _, target in targets do
				items[target] = level(items[target]) + level(count)
			end
		else
			items[itemId] = count
		end
	end
	data.OwnedItems = items
	local slots: { [any]: any } = {}
	for slot, itemId in tableOr(data.EquippedItems) do
		if slot == "Wood" or slot == "Iron" then
			local targets = skinTargets(itemId)
			if targets then
				for _, target in targets do
					local newSlot = if string.match(target, "_fairwaywood$") then "FairwayWood" elseif string.match(target, "_longiron$") then "LongIron" else "ShortIron"
					slots[newSlot] = target
				end
			end
		else
			slots[slot] = itemId
		end
	end
	data.EquippedItems = slots
end

-- migrations[v] upgrades a version-v profile IN PLACE to version v+1.
ProfileTemplate.Migrations = {
	[1] = migrateV1,
} :: { [number]: Migration }

local STAT_IDS: { Types.StatId } = { "Power", "Accuracy", "Spin" }
local MAX_ITEM_COPIES = 1e6

-- A fresh profile: starting currency, starter items/clubs owned AND equipped.
function ProfileTemplate.new(now: number): ProfileData
	local data: ProfileData = {
		SchemaVersion = ProfileTemplate.CURRENT_VERSION,
		Coins = Config.Economy.StartingCoins,
		Gems = Config.Economy.StartingGems,
		OwnedItems = {},
		EquippedItems = {},
		OwnedClubs = {},
		EquippedClubs = {},
		ClubUpgrades = {},
		Stats = {
			MatchesPlayed = 0,
			Wins = 0,
			Losses = 0,
			HolesPlayed = 0,
			CasesOpened = 0,
			TradeUps = 0,
			HolesInOne = 0,
			LongestDriveYds = 0,
			TotalCoinsEarned = 0,
			FairwaysHit = 0,
			ClubUpgrades = 0,
			ShopPurchases = 0,
			RookieWins = 0,
			AmateurWins = 0,
			ProWins = 0,
			ChampionWins = 0,
		},
		Quests = {},
		Shop = { Rotation = 0, Purchased = {} },
		Earnings = { Day = 0, Range = 0, Afk = 0 },
		Wheel = { LastFreeSpinAt = 0, ExtraSpins = 0, TotalSpins = 0, Receipts = {} },
		Meta = { CreatedAt = now, Sessions = 0 },
	}
	ProfileTemplate.ensureDefaults(data)
	return data
end

-- Starter items owned + equipped for every slot, starter clubs filling the bag.
function ProfileTemplate.ensureDefaults(data: ProfileData)
	for _, item in ItemDatabase.DefaultItems do
		if (data.OwnedItems[item.Id] or 0) < 1 then
			data.OwnedItems[item.Id] = 1
		end
		if data.EquippedItems[item.Slot] == nil then
			data.EquippedItems[item.Slot] = item.Id
		end
	end
	for _, club in ClubDatabase.StarterClubs do
		data.OwnedClubs[club.Id] = true
		if data.EquippedClubs[club.SlotLabel] == nil then
			data.EquippedClubs[club.SlotLabel] = club.Id
		end
	end
end

local function cleanBalance(value: any, cap: number): number
	if type(value) ~= "number" or value ~= value or value < 0 then
		return 0
	end
	return math.min(cap, math.floor(value))
end

-- Repairs a profile in place. Safe to run on every load.
function ProfileTemplate.sanitize(data: ProfileData)
	data.Coins = cleanBalance(data.Coins, Config.Economy.MaxCoins)
	data.Gems = cleanBalance(data.Gems, Config.Economy.MaxGems)

	-- Owned items: only catalogue items with a positive whole count.
	for itemId, count in data.OwnedItems :: { [any]: any } do
		local valid = type(itemId) == "string" and ItemDatabase.get(itemId) ~= nil
		if valid and type(count) == "number" and count == count and count >= 1 then
			data.OwnedItems[itemId] = math.min(MAX_ITEM_COPIES, math.floor(count))
		else
			data.OwnedItems[itemId :: any] = nil
		end
	end

	-- Equipped items must exist, be owned, and match the slot they sit in.
	for slot, itemId in data.EquippedItems :: { [any]: any } do
		local item = ItemDatabase.get(itemId)
		if not (item and item.Slot == slot and (data.OwnedItems[item.Id] or 0) >= 1) then
			data.EquippedItems[slot :: any] = nil
		end
	end

	for clubId in data.OwnedClubs :: { [any]: any } do
		if ClubDatabase.get(clubId) == nil then
			data.OwnedClubs[clubId :: any] = nil
		end
	end
	for label, clubId in data.EquippedClubs :: { [any]: any } do
		local club = ClubDatabase.get(clubId)
		if not (club and club.SlotLabel == label and data.OwnedClubs[club.Id]) then
			data.EquippedClubs[label :: any] = nil
		end
	end

	-- Wheel: non-negative whole counters, a bounded list of receipt ids.
	local wheel = data.Wheel
	wheel.ExtraSpins = math.clamp(math.floor(cleanBalance(wheel.ExtraSpins, Config.Wheel.MaxStoredSpins)), 0, Config.Wheel.MaxStoredSpins)
	wheel.TotalSpins = cleanBalance(wheel.TotalSpins, 1e9)
	wheel.LastFreeSpinAt = cleanBalance(wheel.LastFreeSpinAt, 1e12)
	local receipts: { string } = {}
	for _, id in wheel.Receipts :: { any } do
		if type(id) == "string" and #receipts < 50 then
			table.insert(receipts, id)
		end
	end
	wheel.Receipts = receipts

	-- Upgrade levels: whole numbers in [0, MaxUpgradeLevel], owned clubs only.
	for clubId, levels in data.ClubUpgrades :: { [any]: any } do
		if ClubDatabase.get(clubId) == nil or not data.OwnedClubs[clubId] or type(levels) ~= "table" then
			data.ClubUpgrades[clubId :: any] = nil
		else
			for _, stat in STAT_IDS do
				local level = levels[stat]
				if type(level) ~= "number" or level ~= level then
					level = 0
				end
				levels[stat] = math.clamp(math.floor(level), 0, Config.Clubs.MaxUpgradeLevel)
			end
		end
	end
end

-- Fill any top-level field that is missing or the wrong type, and any missing
-- counter inside the fixed-shape sections, from a fresh template.
local function fillMissing(raw: any, now: number)
	local template: any = ProfileTemplate.new(now)
	for key, defaultValue in template do
		if type(raw[key]) ~= type(defaultValue) then
			raw[key] = TableUtil.deepCopy(defaultValue)
		end
	end
	for _, section in { "Stats", "Shop", "Earnings", "Wheel", "Meta" } do
		for key, defaultValue in template[section] do
			if type(raw[section][key]) ~= type(defaultValue) then
				raw[section][key] = TableUtil.deepCopy(defaultValue)
			end
		end
	end
end

-- Full load pipeline. Returns (profile) or (nil, reason) where reason is
-- "corrupt" or "too_new".
function ProfileTemplate.prepare(raw: any, now: number, options: PrepareOptions?): (ProfileData?, string?)
	local currentVersion = (options and options.CurrentVersion) or ProfileTemplate.CURRENT_VERSION
	local migrations = (options and options.Migrations) or ProfileTemplate.Migrations

	if type(raw) ~= "table" then
		return nil, "corrupt"
	end
	local version = raw.SchemaVersion
	if type(version) ~= "number" or version ~= version or version < 1 or math.floor(version) ~= version then
		return nil, "corrupt"
	end
	if version > currentVersion then
		return nil, "too_new"
	end

	while version < currentVersion do
		local migrate = migrations[version]
		if migrate == nil then
			return nil, "corrupt" -- no path forward from this version
		end
		migrate(raw)
		version += 1
		raw.SchemaVersion = version
	end

	fillMissing(raw, now)
	local data = raw :: ProfileData
	ProfileTemplate.sanitize(data)
	ProfileTemplate.ensureDefaults(data)
	return data, nil
end

-- The copy sent to the owning client: everything the UI needs, minus Meta.
function ProfileTemplate.clientView(data: ProfileData): any
	local view = TableUtil.deepCopy(data)
	view.Meta = nil
	return view
end

return ProfileTemplate
