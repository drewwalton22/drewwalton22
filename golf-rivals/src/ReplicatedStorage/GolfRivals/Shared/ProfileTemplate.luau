--!strict
--[[
	ProfileTemplate.luau  (ReplicatedStorage.GolfRivals.Shared)

	The shape of a player's saved data, how a brand-new profile looks, and how a
	profile loaded from the DataStore is validated and repaired before the game
	ever touches it.

	PROFILE (SchemaVersion 1)
	  Coins / Gems          balances (non-negative integers, capped)
	  OwnedItems            itemId -> copy count (duplicates stack; they feed
	                        Sell and Trade-Up)
	  EquippedItems         slot ("Driver","Swing","BallTrail",...) -> itemId
	  OwnedClubs            clubId -> true
	  EquippedClubs         bag slot label ("D","7i","PT",...) -> clubId
	  ClubUpgrades          clubId -> { Distance, Accuracy, Forgiveness } levels
	  Stats                 lifetime counters (quests/leaderboards read these)
	  Quests                owned by the quest system (filled in a later step)
	  Shop                  today's purchases, so a rotation item can't be bought twice
	  Meta                  CreatedAt / Sessions

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
	Distance: number,
	Accuracy: number,
	Forgiveness: number,
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
	},
	Quests: { [string]: any },
	Shop: {
		Rotation: number, -- shop rotation index these purchases belong to
		Purchased: { [string]: boolean },
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

ProfileTemplate.CURRENT_VERSION = 1

-- migrations[v] upgrades a version-v profile IN PLACE to version v+1.
-- (None yet: version 1 is the first schema.) Example for later:
--   [1] = function(data) data.NewField = 0 end,
ProfileTemplate.Migrations = {} :: { [number]: Migration }

local STAT_IDS: { Types.StatId } = { "Distance", "Accuracy", "Forgiveness" }
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
		},
		Quests = {},
		Shop = { Rotation = 0, Purchased = {} },
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
	for _, section in { "Stats", "Shop", "Meta" } do
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
