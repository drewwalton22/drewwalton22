--!strict
--[[
	DatabaseValidator.luau  (ReplicatedStorage.GolfRivals.Shared)

	Cross-checks every static database at server boot. A typo in a data table
	(a case whose odds sum to 99%, a rarity with no items, a payout that mints
	infinite coins) should crash the server loudly on startup, not surface as a
	player exploit weeks later.

	Usage:
	  local errors = DatabaseValidator.run()      -- returns {string}, empty = OK
	  DatabaseValidator.assertValid()             -- throws listing every problem
]]

local Types = require(script.Parent.Types)
local Config = require(script.Parent.Config)
local Rarity = require(script.Parent.Rarity)
local ItemDatabase = require(script.Parent.ItemDatabase)
local CaseDatabase = require(script.Parent.CaseDatabase)
local ClubDatabase = require(script.Parent.ClubDatabase)
local ProfileTemplate = require(script.Parent.ProfileTemplate)
local QuestDatabase = require(script.Parent.QuestDatabase)

local DatabaseValidator = {}

function DatabaseValidator.run(): { string }
	local errors: { string } = {}
	local function check(condition: boolean, message: string)
		if not condition then
			table.insert(errors, message)
		end
	end

	-- 1) RARITY / PRICING INVARIANTS --------------------------------------
	local tradeUpInputs = Config.TradeUp.InputCount
	for _, rarityId in Rarity.Order do
		local info = Rarity.Info[rarityId]
		local isTop = Rarity.nextTier(rarityId) == nil

		-- Spec: Common..Legendary cost Coins only; Mythical costs Gems only.
		local expectedCurrency: Types.CurrencyId = if isTop then "Gems" else "Coins"
		check(info.ShopPrice.Currency == expectedCurrency, `{rarityId}: shop currency must be {expectedCurrency}`)
		check(info.ShopPrice.Amount > 0, `{rarityId}: shop price must be positive`)
		check(info.SellValue > 0, `{rarityId}: sell value must be positive`)

		-- Buying with coins then selling must lose coins (no buy/sell loop).
		if info.ShopPrice.Currency == "Coins" then
			check(info.SellValue < info.ShopPrice.Amount, `{rarityId}: sell value must be below coin shop price`)
		end

		-- Trade-up must not mint coins: N inputs sell for more than 1 output.
		local nextId = Rarity.nextTier(rarityId)
		if nextId then
			local nextInfo = Rarity.Info[nextId]
			check(
				nextInfo.SellValue < tradeUpInputs * info.SellValue,
				`trade-up {rarityId}->{nextId} is profitable ({tradeUpInputs}x{info.SellValue} <= {nextInfo.SellValue})`
			)
		end
	end

	-- 2) ITEMS --------------------------------------------------------------
	for _, item in ItemDatabase.Ordered do
		check(Rarity.isValid(item.Rarity), `item {item.Id}: invalid rarity {item.Rarity}`)
		local slots = ItemDatabase.CategorySlots[item.Category]
		check(slots ~= nil and table.find(slots, item.Slot) ~= nil, `item {item.Id}: slot {item.Slot} not valid for {item.Category}`)
	end

	-- Every (category, rarity) needs >= 1 item or trade-up/case rolls dead-end.
	for _, category in ItemDatabase.Categories do
		for _, rarityId in Rarity.Order do
			check(#ItemDatabase.list(category, rarityId) > 0, `no {category} items at rarity {rarityId}`)
		end
		-- Each slot must have a default so a fresh player can equip something.
		for _, slot in ItemDatabase.CategorySlots[category] do
			local hasDefault = false
			for _, item in ItemDatabase.DefaultItems do
				if item.Category == category and item.Slot == slot then
					hasDefault = true
				end
			end
			check(hasDefault, `no default item for slot {slot}`)
		end
	end

	-- 3) DAILY SHOP --------------------------------------------------------
	check(Config.Shop.RotationSeconds > 0, "shop rotation must be positive")
	for _, rarityId in Rarity.Order do
		local slots = Config.Shop.SlotsPerRarity[rarityId]
		check(slots ~= nil and slots >= 0, `shop slots missing for {rarityId}`)
		check(#ItemDatabase.ShopPool[rarityId] >= (slots or 0), `shop pool too small for {rarityId}`)
	end

	-- 4) CASES -------------------------------------------------------------
	for _, caseId in CaseDatabase.Order do
		local case = CaseDatabase.Cases[caseId]
		local total = 0
		for _, rarityId in Rarity.Order do
			local weight = case.DropWeights[rarityId]
			check(weight ~= nil and weight >= 0, `case {caseId}: missing weight for {rarityId}`)
			total += weight or 0
			-- A tier with a non-zero chance must have something to drop.
			if (weight or 0) > 0 then
				check(#CaseDatabase.getPool(caseId, rarityId) > 0, `case {caseId}: empty pool at {rarityId}`)
			end
		end
		check(total == CaseDatabase.WEIGHT_TOTAL, `case {caseId}: weights sum to {total}, expected {CaseDatabase.WEIGHT_TOTAL}`)
		check(case.Price.Amount > 0, `case {caseId}: price must be positive`)
		-- Cases must be a coin sink: expected resale value below the price.
		if case.Price.Currency == "Coins" then
			check(
				CaseDatabase.expectedSellValue(caseId) < case.Price.Amount,
				`case {caseId}: expected sell value >= price (cases would print coins)`
			)
		end
	end

	-- 5) CLUBS -------------------------------------------------------------
	for _, club in ClubDatabase.Ordered do
		local s = club.BaseStats
		for _, statValue in { s.Power, s.Accuracy, s.Spin } do
			check(statValue >= 1 and statValue <= Config.Clubs.StatCap, `club {club.Id}: stat out of range`)
		end
	end
	-- Exactly the six club categories, one skin slot each.
	check(#ClubDatabase.BagSlots == 6, "the bag must have exactly six club categories")
	check(#ItemDatabase.ClubClasses == #ClubDatabase.BagSlots, "every club category needs a skin slot")
	-- A brand-new player must be able to fill the whole bag for free.
	for _, slot in ClubDatabase.BagSlots do
		local hasStarter = false
		for _, club in ClubDatabase.StarterClubs do
			if club.SlotLabel == slot.Label then
				hasStarter = true
			end
		end
		check(hasStarter, `no starter club for bag slot {slot.Label}`)
	end

	-- 6) LEAGUES -----------------------------------------------------------
	local lastFee = 0
	for _, league in Config.Leagues do
		check(league.EntryFee > lastFee, `league {league.Id}: entry fee must increase with league tier`)
		check(league.WinPayout >= league.EntryFee, `league {league.Id}: payout below entry fee`)
		check(
			league.WinPayout <= league.EntryFee * Config.LeagueRules.MaxPayoutMultiplier,
			`league {league.Id}: payout exceeds MaxPayoutMultiplier`
		)
		lastFee = league.EntryFee
	end

	-- 7) QUESTS ------------------------------------------------------------
	local freshStats = ProfileTemplate.new(0).Stats :: any
	for _, quest in QuestDatabase.All do
		check(type(freshStats[quest.Stat]) == "number", `quest {quest.Id}: stat {quest.Stat} is not a profile counter`)
		check(quest.Target > 0, `quest {quest.Id}: target must be positive`)
		check((quest.Reward.Coins or 0) > 0 or (quest.Reward.Gems or 0) > 0, `quest {quest.Id}: needs a coin or gem reward`)
		check(quest.Period == "Lifetime" or quest.Kind == "Delta", `quest {quest.Id}: only lifetime quests may use absolute (Value) stats`)
	end
	check(#QuestDatabase.Pools.Daily >= QuestDatabase.DailyCount * 2, "daily quest pool too small to rotate")
	check(#QuestDatabase.Pools.Weekly >= QuestDatabase.WeeklyCount * 2, "weekly quest pool too small to rotate")
	check(#QuestDatabase.Pools.Lifetime > 0, "no lifetime quests")

	return errors
end

function DatabaseValidator.assertValid()
	local errors = DatabaseValidator.run()
	if #errors > 0 then
		error("GolfRivals database validation failed:\n - " .. table.concat(errors, "\n - "), 2)
	end
end

return DatabaseValidator
