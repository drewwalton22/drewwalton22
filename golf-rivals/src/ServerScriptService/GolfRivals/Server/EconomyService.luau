--!strict
-- ROBLOX-ONLY: binds remotes and uses Random/os.time. All money rules live in the
-- offline-tested Economy module; this file only authenticates, adapts and notifies.
--[[
	EconomyService.luau  (ServerScriptService.GolfRivals.Server)

	Connects the client-callable remotes to Economy / ProfileOps:

	  GetShop, BuyShopItem, OpenCases, SellItems, TradeUp,
	  UpgradeClub, BuyClub, EquipItem, EquipClub

	Per request:  rate limit + error guard (Remotes.onInvoke)  ->
	              profile must be loaded                       ->
	              Economy.* validates every argument and applies the change
	                atomically                                  ->
	              on success: push the changed profile sections to the client
	                (ProfileChanged) and schedule a debounced save.

	The client NEVER sends prices, results or balances - only ids and counts.
	Randomness comes from this server's Random; the client can neither see nor
	influence a roll.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Logger = require(Shared.Logger)
local Remotes = require(Shared.Remotes)
local ProfileOps = require(Shared.ProfileOps)
local ProfileTemplate = require(Shared.ProfileTemplate)
local Economy = require(script.Parent.Economy)
local ProfileService = require(script.Parent.ProfileService)

type ProfileData = ProfileTemplate.ProfileData

local EconomyService = {}

local random = Random.new() -- unpredictable per-server stream

local function context(): Economy.Context
	return {
		Now = os.time(),
		Rng = function(): number
			return random:NextNumber()
		end,
	}
end

-- Profile sections each kind of change can touch (what we push to the client).
local INVENTORY_KEYS = { "Coins", "Gems", "OwnedItems", "EquippedItems", "Shop", "Stats" }
local CLUB_KEYS = { "Coins", "OwnedClubs", "EquippedClubs", "ClubUpgrades" }

local function commit(player: Player, data: ProfileData, keys: { string })
	local view = ProfileTemplate.clientView(data)
	local patch: { [string]: any } = {}
	for _, key in keys do
		patch[key] = view[key]
	end
	ProfileService.notify(player, patch)
	ProfileService.saveSoon(player)
end

-- Wraps a handler: loads the profile (or replies not_loaded), runs it, and
-- commits the listed profile sections to the client when it succeeded.
local function handler(keys: { string }?, run: (player: Player, data: ProfileData, ...any) -> Economy.Result): (player: Player, ...any) -> any
	return function(player: Player, ...: any): any
		local data = ProfileService.get(player)
		if data == nil then
			return { ok = false, reason = "not_loaded" }
		end
		local result = run(player, data, ...)
		if result.ok and keys then
			commit(player, data, keys)
		end
		return result
	end
end

function EconomyService.start()
	Remotes.onInvoke("GetShop", handler(nil, function(_player, data)
		return Economy.getShop(data, context())
	end))

	Remotes.onInvoke("BuyShopItem", handler(INVENTORY_KEYS, function(_player, data, itemId)
		return Economy.buyShopItem(data, itemId, context())
	end))

	Remotes.onInvoke("OpenCases", handler(INVENTORY_KEYS, function(_player, data, caseId, count)
		return Economy.openCases(data, caseId, count, context())
	end))

	Remotes.onInvoke("SellItems", handler(INVENTORY_KEYS, function(_player, data, itemIds)
		return Economy.sellItems(data, itemIds, context())
	end))

	Remotes.onInvoke("TradeUp", handler(INVENTORY_KEYS, function(_player, data, itemIds)
		return Economy.tradeUp(data, itemIds, context())
	end))

	Remotes.onInvoke("UpgradeClub", handler(CLUB_KEYS, function(_player, data, clubId, stat)
		return Economy.upgradeClub(data, clubId, stat)
	end))

	Remotes.onInvoke("BuyClub", handler(CLUB_KEYS, function(_player, data, clubId)
		return Economy.buyClub(data, clubId)
	end))

	Remotes.onInvoke("EquipItem", handler({ "EquippedItems" }, function(_player, data, itemId)
		local ok, reason = ProfileOps.equipItem(data, itemId)
		return { ok = ok, reason = reason }
	end))

	Remotes.onInvoke("EquipClub", handler({ "EquippedClubs" }, function(_player, data, clubId)
		local ok, reason = ProfileOps.equipClub(data, clubId)
		return { ok = ok, reason = reason }
	end))

	Logger.info("Economy", "Economy service started (shop, cases, sell, trade-up, club upgrades, equip).")
end

return EconomyService
