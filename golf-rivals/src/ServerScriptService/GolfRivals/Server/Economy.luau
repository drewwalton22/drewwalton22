--!strict
--[[
	Economy.luau  (ServerScriptService.GolfRivals.Server)

	The game's money rules, as pure functions on a profile. Each function takes
	UNTRUSTED arguments (typed `any`), validates everything, and returns a result
	table { ok = boolean, reason = string?, ...extra }.

	  openCases     charge, roll, grant N cases of one type
	  buyShopItem   buy today's offer (once per rotation per item)
	  sellItems     sell spare copies for coins
	  tradeUp       5 items of one rarity -> 1 item of the next rarity
	  upgradeClub   spend coins to raise a club stat
	  buyClub       buy a club from the club shop
	  getShop       read today's offers + what's already been bought

	THE TWO GUARANTEES
	  1. A FAILED call changes nothing. Validation happens before mutation, and
	     every multi-step mutation runs inside `atomic`, which snapshots the
	     profile and restores it if any step fails (or throws).
	  2. A SUCCESSFUL call is all-or-nothing: no half-charged purchases.
	  Callers must not yield inside these functions (they don't) - Luau is
	  single-threaded between yields, so no other request or save can observe a
	  half-applied state.

	CONTEXT: { Now = unix seconds, Rng = () -> float in [0,1) }. Injected so tests
	are deterministic. Production passes os.time() and the server's Random.

	Exploit invariants (checked at boot by DatabaseValidator and by the fuzz /
	Monte-Carlo tests): selling never returns more than buying cost; trade-up can't
	mint coins; cases are a net coin sink; Mythical costs gems only.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage") -- OFFLINE-STRIP
local Shared = ReplicatedStorage.GolfRivals.Shared -- OFFLINE-STRIP
local Types = require(Shared.Types)
local Config = require(Shared.Config)
local Rarity = require(Shared.Rarity)
local ItemDatabase = require(Shared.ItemDatabase)
local CaseDatabase = require(Shared.CaseDatabase)
local ShopRotation = require(Shared.ShopRotation)
local ProfileOps = require(Shared.ProfileOps)
local ProfileTemplate = require(Shared.ProfileTemplate)
local TableUtil = require(Shared.TableUtil)
local Validate = require(Shared.Validate)
local CaseRoller = require(script.Parent.CaseRoller)

type ProfileData = ProfileTemplate.ProfileData

export type Context = {
	Now: number,
	Rng: () -> number,
}

export type Drop = {
	ItemId: string,
	Rarity: Types.RarityId,
	IsNew: boolean, -- first copy the player has ever owned
}

export type ShopEntry = {
	ItemId: string,
	Rarity: Types.RarityId,
	Price: Types.Price,
	Purchased: boolean,
}

export type Result = {
	ok: boolean,
	reason: string?,
	Drops: { Drop }?,
	Spent: Types.Price?,
	CoinsGained: number?,
	Reward: Drop?,
	NewLevel: number?,
	Cost: number?,
	Offers: { ShopEntry }?,
	EndsAt: number?,
}

local Economy = {}

local function fail(reason: string): Result
	return { ok = false, reason = reason }
end

-- ---------------------------------------------------------------------------
-- Transactions
-- ---------------------------------------------------------------------------

-- Runs `step` against the profile. If it returns false (or throws), the profile
-- is restored byte-for-byte to its state before the call.
function Economy.atomic(data: ProfileData, step: () -> (boolean, string?)): (boolean, string?)
	local snapshot = TableUtil.deepCopy(data)
	local called, ok, reason = pcall(step)
	if called and ok then
		return true, nil
	end
	-- Restore in place: the profile table identity must survive (the profile
	-- service and other systems hold references to it).
	local live = data :: any
	for key in live do
		live[key] = nil
	end
	for key, value in snapshot do
		live[key] = value
	end
	if not called then
		return false, "internal_error"
	end
	return false, reason
end

-- ---------------------------------------------------------------------------
-- Cases
-- ---------------------------------------------------------------------------

function Economy.openCases(data: ProfileData, caseId: any, count: any, ctx: Context): Result
	local case = CaseDatabase.get(caseId)
	if case == nil then
		return fail("unknown_case")
	end
	if not Validate.integerInRange(count, 1, Config.Economy.MaxCasesPerOpen) then
		return fail("bad_count")
	end
	local n = count :: number
	local total: Types.Price = { Currency = case.Price.Currency, Amount = case.Price.Amount * n }
	if not ProfileOps.canAfford(data, total) then
		return fail("insufficient_funds")
	end

	local drops: { Drop } = {}
	local ok, reason = Economy.atomic(data, function(): (boolean, string?)
		local spent, why = ProfileOps.spend(data, total)
		if not spent then
			return false, why
		end
		for _ = 1, n do
			local item = CaseRoller.rollItem(case, ctx.Rng)
			local isNew = ProfileOps.ownedCount(data, item.Id) == 0
			local granted, grantWhy = ProfileOps.grantItem(data, item.Id, 1)
			if not granted then
				return false, grantWhy
			end
			table.insert(drops, { ItemId = item.Id, Rarity = item.Rarity, IsNew = isNew })
		end
		data.Stats.CasesOpened += n
		return true, nil
	end)
	if not ok then
		return fail(reason or "failed")
	end
	return { ok = true, Drops = drops, Spent = total }
end

-- ---------------------------------------------------------------------------
-- Daily shop
-- ---------------------------------------------------------------------------

-- Purchases recorded for the CURRENT rotation (a stale record counts as empty).
local function purchasedThisRotation(data: ProfileData, index: number): { [string]: boolean }
	if data.Shop.Rotation == index then
		return data.Shop.Purchased
	end
	return {}
end

function Economy.getShop(data: ProfileData, ctx: Context): Result
	local index = ShopRotation.indexAt(ctx.Now)
	local bought = purchasedThisRotation(data, index)
	local entries: { ShopEntry } = {}
	for _, offer in ShopRotation.offersFor(index) do
		table.insert(entries, {
			ItemId = offer.ItemId,
			Rarity = offer.Rarity,
			Price = offer.Price,
			Purchased = bought[offer.ItemId] == true,
		})
	end
	return { ok = true, Offers = entries, EndsAt = ShopRotation.endsAt(index) }
end

function Economy.buyShopItem(data: ProfileData, itemId: any, ctx: Context): Result
	local item = ItemDatabase.get(itemId)
	if item == nil then
		return fail("unknown_item")
	end
	local index = ShopRotation.indexAt(ctx.Now)
	local offer = ShopRotation.findOffer(index, item.Id)
	if offer == nil then
		return fail("not_in_shop")
	end
	if purchasedThisRotation(data, index)[item.Id] then
		return fail("already_purchased")
	end
	if not ProfileOps.canAfford(data, offer.Price) then
		return fail("insufficient_funds")
	end

	local ok, reason = Economy.atomic(data, function(): (boolean, string?)
		local spent, why = ProfileOps.spend(data, offer.Price)
		if not spent then
			return false, why
		end
		local granted, grantWhy = ProfileOps.grantItem(data, item.Id, 1)
		if not granted then
			return false, grantWhy
		end
		if data.Shop.Rotation ~= index then
			data.Shop = { Rotation = index, Purchased = {} } -- new day: forget yesterday's
		end
		data.Shop.Purchased[item.Id] = true
		data.Stats.ShopPurchases += 1
		return true, nil
	end)
	if not ok then
		return fail(reason or "failed")
	end
	return { ok = true, Spent = offer.Price }
end

-- ---------------------------------------------------------------------------
-- Selling
-- ---------------------------------------------------------------------------

local function isItemIdString(value: any): boolean
	return Validate.string(value, 64)
end

-- itemIds is a list; repeating an id sells several copies of it.
function Economy.sellItems(data: ProfileData, itemIds: any, _ctx: Context): Result
	if not Validate.array(itemIds, Config.Economy.SellBatchMax, isItemIdString) or #itemIds == 0 then
		return fail("bad_items")
	end

	local wanted: { [string]: number } = {}
	for _, id in itemIds :: { string } do
		wanted[id] = (wanted[id] or 0) + 1
	end

	-- Validate EVERYTHING before touching anything.
	local coins = 0
	for id, n in wanted do
		local item = ItemDatabase.get(id)
		if item == nil then
			return fail("unknown_item")
		end
		if ProfileOps.ownedCount(data, id) < 1 then
			return fail("not_owned")
		end
		if ProfileOps.spareCount(data, id) < n then
			return fail("insufficient_spare") -- would sell a starter / equipped copy
		end
		coins += Rarity.Info[item.Rarity].SellValue * n
	end

	local ok, reason = Economy.atomic(data, function(): (boolean, string?)
		for id, n in wanted do
			local removed, why = ProfileOps.removeItem(data, id, n)
			if not removed then
				return false, why
			end
		end
		return ProfileOps.add(data, "Coins", coins)
	end)
	if not ok then
		return fail(reason or "failed")
	end
	return { ok = true, CoinsGained = coins }
end

-- ---------------------------------------------------------------------------
-- Trade-up contract
-- ---------------------------------------------------------------------------

-- Exactly TradeUp.InputCount items of ONE rarity (and, if configured, one
-- category) are consumed and one item of the next rarity is granted, rolled
-- uniformly from that rarity's pool.
function Economy.tradeUp(data: ProfileData, itemIds: any, ctx: Context): Result
	local required = Config.TradeUp.InputCount
	if not Validate.array(itemIds, required, isItemIdString) or #itemIds ~= required then
		return fail("bad_inputs")
	end

	local wanted: { [string]: number } = {}
	local rarity: Types.RarityId? = nil
	local category: Types.ItemCategory? = nil
	for _, id in itemIds :: { string } do
		local item = ItemDatabase.get(id)
		if item == nil then
			return fail("unknown_item")
		end
		if rarity == nil then
			rarity, category = item.Rarity, item.Category
		elseif item.Rarity ~= rarity then
			return fail("mixed_rarity")
		elseif Config.TradeUp.RequireSameCategory and item.Category ~= category then
			return fail("mixed_category")
		end
		wanted[id] = (wanted[id] or 0) + 1
	end

	local inputRarity = rarity :: Types.RarityId
	local nextRarity = Rarity.nextTier(inputRarity)
	if nextRarity == nil then
		return fail("max_rarity")
	end

	for id, n in wanted do
		if ProfileOps.ownedCount(data, id) < 1 then
			return fail("not_owned")
		end
		if ProfileOps.spareCount(data, id) < n then
			return fail("insufficient_spare")
		end
	end

	-- Reward pool: the inputs' category (or every category if not restricted).
	local pool: { ItemDatabase.Item } = {}
	for _, cat in ItemDatabase.Categories do
		if not Config.TradeUp.RequireSameCategory or cat == category then
			for _, item in ItemDatabase.list(cat, nextRarity) do
				table.insert(pool, item)
			end
		end
	end
	if #pool == 0 then
		return fail("no_reward_pool")
	end

	local reward: Drop? = nil
	local ok, reason = Economy.atomic(data, function(): (boolean, string?)
		for id, n in wanted do
			local removed, why = ProfileOps.removeItem(data, id, n)
			if not removed then
				return false, why
			end
		end
		local item = pool[math.clamp(math.floor(ctx.Rng() * #pool) + 1, 1, #pool)]
		local isNew = ProfileOps.ownedCount(data, item.Id) == 0
		local granted, grantWhy = ProfileOps.grantItem(data, item.Id, 1)
		if not granted then
			return false, grantWhy
		end
		data.Stats.TradeUps += 1
		reward = { ItemId = item.Id, Rarity = item.Rarity, IsNew = isNew }
		return true, nil
	end)
	if not ok then
		return fail(reason or "failed")
	end
	return { ok = true, Reward = reward }
end

-- ---------------------------------------------------------------------------
-- Clubs
-- ---------------------------------------------------------------------------

function Economy.upgradeClub(data: ProfileData, clubId: any, stat: any): Result
	-- Cost is read BEFORE the upgrade so the result reports what was paid.
	local before = data.Coins
	local ok, reason, newLevel = ProfileOps.upgradeClub(data, clubId, stat)
	if not ok then
		return fail(reason or "failed")
	end
	data.Stats.ClubUpgrades += 1
	return { ok = true, NewLevel = newLevel, Cost = before - data.Coins }
end

function Economy.buyClub(data: ProfileData, clubId: any): Result
	local before = data.Coins
	local ok, reason = ProfileOps.buyClub(data, clubId)
	if not ok then
		return fail(reason or "failed")
	end
	return { ok = true, Spent = { Currency = "Coins", Amount = before - data.Coins } }
end

return Economy
