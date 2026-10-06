--!strict
--[[
	CasesView.luau  (ReplicatedStorage.GolfRivals.Shared)

	The Cases screens (mockup panels 4-6): case cards with their drop-rate table, what
	opening N cases costs, the roulette strip shown while opening, and the results
	screen with the "Sell All" value.

	ROULETTE  The strip is decoration only: the server already rolled the real drop.
	The client builds a row of plausible items (drawn with the case's own rarity
	weights so the blur "feels" right) and places the real item at the stopping
	position, then tweens the row so that item lands under the marker.
]]

local Types = require(script.Parent.Types)
local CaseDatabase = require(script.Parent.CaseDatabase)
local Config = require(script.Parent.Config)
local Format = require(script.Parent.Format)
local ItemDatabase = require(script.Parent.ItemDatabase)
local Prng = require(script.Parent.Prng)
local ProfileOps = require(script.Parent.ProfileOps)
local ProfileTemplate = require(script.Parent.ProfileTemplate)
local Rarity = require(script.Parent.Rarity)
local ShopView = require(script.Parent.ShopView)

export type Odds = { Rarity: Types.RarityId, Percent: number, Color: Types.RGB }

export type CaseCard = {
	Id: string,
	Name: string,
	Description: string,
	Price: Types.Price,
	PriceText: string,
	Odds: { Odds },
	MaxAffordable: number,
}

export type ResultCard = {
	ItemId: string,
	Name: string,
	Rarity: Types.RarityId,
	Color: Types.RGB,
	IsNew: boolean,
	SlotLabel: string,
	Primary: Types.RGB?,
	Secondary: Types.RGB?,
}

export type Results = {
	Cards: { ResultCard },
	SellIds: { string }, -- spare copies of what dropped (repeat an id per copy)
	SellValue: number,
}

local CasesView = {}

CasesView.Quantities = { 1, 3, 5, 10 }

function CasesView.total(caseId: string, count: number): Types.Price
	local case = CaseDatabase.Cases[caseId]
	return { Currency = case.Price.Currency, Amount = case.Price.Amount * count }
end

function CasesView.maxAffordable(profile: ProfileTemplate.ProfileData, caseId: string): number
	local case = CaseDatabase.Cases[caseId]
	local balance = ProfileOps.balance(profile, case.Price.Currency)
	return math.min(Config.Economy.MaxCasesPerOpen, math.floor(balance / case.Price.Amount))
end

function CasesView.canOpen(profile: ProfileTemplate.ProfileData, caseId: string, count: number): (boolean, string?)
	local case = CaseDatabase.Cases[caseId]
	if case == nil then
		return false, "Unknown case"
	end
	if count < 1 or count > Config.Economy.MaxCasesPerOpen then
		return false, "Pick 1 to 10 cases"
	end
	if not ProfileOps.canAfford(profile, CasesView.total(caseId, count)) then
		return false, "Not enough coins"
	end
	return true, nil
end

function CasesView.cards(profile: ProfileTemplate.ProfileData): { CaseCard }
	local cards: { CaseCard } = {}
	for _, caseId in CaseDatabase.Order do
		local case = CaseDatabase.Cases[caseId]
		local percents = CaseDatabase.getDropPercents(caseId)
		local odds: { Odds } = {}
		for _, rarityId in Rarity.Order do
			table.insert(odds, { Rarity = rarityId, Percent = percents[rarityId], Color = Rarity.Info[rarityId].Color })
		end
		table.insert(cards, {
			Id = case.Id, Name = case.Name, Description = case.Description, Price = case.Price,
			PriceText = Format.commas(case.Price.Amount), Odds = odds, MaxAffordable = CasesView.maxAffordable(profile, caseId),
		})
	end
	return cards
end

-- Results of an OpenCases reply: display cards plus what "Sell All" would sell/pay.
function CasesView.results(drops: { { ItemId: string, Rarity: Types.RarityId, IsNew: boolean } }, profile: ProfileTemplate.ProfileData): Results
	local cards: { ResultCard } = {}
	local dropped: { [string]: number } = {}
	for _, drop in drops do
		local item = ItemDatabase.get(drop.ItemId)
		if item then
			table.insert(cards, {
				ItemId = item.Id, Name = item.Name, Rarity = item.Rarity, Color = Rarity.Info[item.Rarity].Color,
				IsNew = drop.IsNew, SlotLabel = ShopView.slotLabel(item), Primary = item.Visual.Primary, Secondary = item.Visual.Secondary,
			})
			dropped[item.Id] = (dropped[item.Id] or 0) + 1
		end
	end
	-- Only SPARE copies may be sold (never a starter or equipped item).
	local ids: { string } = {}
	local value = 0
	local keys: { string } = {}
	for id in dropped do
		table.insert(keys, id)
	end
	table.sort(keys)
	for _, id in keys do
		local n = math.min(dropped[id], ProfileOps.spareCount(profile, id))
		local item = ItemDatabase.get(id) :: ItemDatabase.Item
		for _ = 1, n do
			table.insert(ids, id)
			value += Rarity.Info[item.Rarity].SellValue
		end
	end
	return { Cards = cards, SellIds = ids, SellValue = value }
end

-- A roulette row of `length` item ids with the real drop at `finalIndex`.
function CasesView.strip(caseId: string, finalItemId: string, length: number, finalIndex: number, seed: number): { string }
	local case = CaseDatabase.Cases[caseId]
	local prng = Prng.new(seed)
	local total = CaseDatabase.WEIGHT_TOTAL
	local strip: { string } = {}
	for i = 1, length do
		if i == finalIndex then
			table.insert(strip, finalItemId)
		else
			-- Same two-step draw the server uses: weighted rarity, then a pool item.
			local roll = math.floor(prng.next() * total)
			local running = 0
			local picked: Types.RarityId = "Common"
			for _, rarityId in Rarity.Order do
				running += case.DropWeights[rarityId] or 0
				if roll < running then
					picked = rarityId
					break
				end
			end
			local pool = CaseDatabase.getPool(caseId, picked)
			table.insert(strip, pool[prng.nextInt(#pool)].Id)
		end
	end
	return strip
end

return CasesView
