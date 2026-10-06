--!strict
--[[
	Rarity.luau  (ReplicatedStorage.GolfRivals.Shared)

	Single source of truth for the six rarity tiers:
		Common < Uncommon < Rare < Unique < Legendary < Mythical

	Per tier we define:
	  * Tier       - 1..6, used for ordering and "next higher tier" (trade-up)
	  * Color      - UI accent color (RGB 0-255)
	  * ShopPrice  - what the Daily Shop charges. Spec rule: Common..Legendary
	                 cost COINS only, Mythical costs GEMS only.
	  * SellValue  - coins refunded when a player sells a duplicate.

	ECONOMY INVARIANTS (enforced at server boot by DatabaseValidator):
	  1. Trade-up must not be profitable: selling 5 items of tier N must be worth
	     MORE than selling 1 item of tier N+1, otherwise players could farm
	     coins by trading up forever.  =>  SellValue[N+1] < 5 * SellValue[N]
	  2. Buy-then-sell must lose coins: SellValue < ShopPrice (coin tiers).
]]

local Types = require(script.Parent.Types)
local TableUtil = require(script.Parent.TableUtil)

type RarityId = Types.RarityId

export type RarityInfo = {
	Id: RarityId,
	Tier: number,
	Color: Types.RGB,
	ShopPrice: Types.Price,
	SellValue: number,
}

local Rarity = {}

-- Defined lowest -> highest. Tier numbers must be 1..N with no gaps.
local definitions: { RarityInfo } = {
	{ Id = "Common", Tier = 1, Color = { 190, 190, 190 }, ShopPrice = { Currency = "Coins", Amount = 500 }, SellValue = 100 },
	{ Id = "Uncommon", Tier = 2, Color = { 80, 200, 110 }, ShopPrice = { Currency = "Coins", Amount = 1200 }, SellValue = 250 },
	{ Id = "Rare", Tier = 3, Color = { 70, 140, 255 }, ShopPrice = { Currency = "Coins", Amount = 2500 }, SellValue = 600 },
	{ Id = "Unique", Tier = 4, Color = { 170, 90, 255 }, ShopPrice = { Currency = "Coins", Amount = 6000 }, SellValue = 1500 },
	{ Id = "Legendary", Tier = 5, Color = { 255, 190, 40 }, ShopPrice = { Currency = "Coins", Amount = 15000 }, SellValue = 5000 },
	-- Mythical is gem-only in the shop. It still sells for coins (so duplicates
	-- aren't dead weight); that implies a gem->coin value, tuned in SellValue.
	{ Id = "Mythical", Tier = 6, Color = { 255, 60, 150 }, ShopPrice = { Currency = "Gems", Amount = 750 }, SellValue = 12000 },
}

-- Ordered list of rarity ids (index == Tier). Iterate THIS, never the Info map.
local order: { RarityId } = {}
local info: { [RarityId]: RarityInfo } = {}
for index, def in definitions do
	assert(def.Tier == index, "Rarity tiers must be contiguous and listed in order")
	order[index] = def.Id
	info[def.Id] = def
end

Rarity.Order = TableUtil.deepFreeze(order) :: { RarityId }
Rarity.Info = TableUtil.deepFreeze(info) :: { [RarityId]: RarityInfo }
Rarity.Count = #order

function Rarity.get(id: RarityId): RarityInfo
	return Rarity.Info[id]
end

-- Accepts untrusted strings (e.g. from a RemoteEvent) so the server can
-- reject garbage before indexing anything.
function Rarity.isValid(id: any): boolean
	return type(id) == "string" and (Rarity.Info :: any)[id] ~= nil
end

-- The next higher tier, or nil for Mythical. Used by Trade-Up Contracts.
function Rarity.nextTier(id: RarityId): RarityId?
	return order[Rarity.Info[id].Tier + 1]
end

-- Negative if a < b, 0 if equal, positive if a > b.
function Rarity.compare(a: RarityId, b: RarityId): number
	return Rarity.Info[a].Tier - Rarity.Info[b].Tier
end

return Rarity
