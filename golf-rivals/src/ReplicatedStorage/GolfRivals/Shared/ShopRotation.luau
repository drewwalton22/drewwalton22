--!strict
--[[
	ShopRotation.luau  (ReplicatedStorage.GolfRivals.Shared)

	The 24-hour rotating Daily Shop, as a PURE FUNCTION OF TIME:

	    rotation index = floor(unixTime / RotationSeconds)       (days since epoch)
	    offers         = f(rotation index)

	Every server computes the same index from the same clock and derives the
	same offers, so all servers show the same shop and it flips at the same
	instant (UTC midnight) with no cross-server messaging or DataStore.

	DRAW: for each rarity tier, take Config.Shop.SlotsPerRarity[tier] distinct
	items from ItemDatabase.ShopPool[tier] (starter items excluded) using a
	partial Fisher-Yates shuffle driven by Prng seeded from (index, tier). The
	pool is sorted by Id, so the draw is reproducible everywhere.

	PRICING (spec): comes from the item's rarity - Common..Legendary in COINS,
	Mythical in GEMS. Mythical can therefore never be bought with coins.

	Caveat: offers are derived from the current catalogue. Adding or removing
	shop-eligible items in an update changes that day's draw for servers
	running the new version.
]]

local Types = require(script.Parent.Types)
local Config = require(script.Parent.Config)
local Rarity = require(script.Parent.Rarity)
local ItemDatabase = require(script.Parent.ItemDatabase)
local Prng = require(script.Parent.Prng)

export type Offer = {
	ItemId: string,
	Rarity: Types.RarityId,
	Price: Types.Price,
}

local ShopRotation = {}

local cache: { [number]: { Offer } } = {}

function ShopRotation.indexAt(now: number): number
	return math.floor(now / Config.Shop.RotationSeconds)
end

-- Unix time the rotation `index` ends (and the next begins).
function ShopRotation.endsAt(index: number): number
	return (index + 1) * Config.Shop.RotationSeconds
end

function ShopRotation.offersFor(index: number): { Offer }
	local cached = cache[index]
	if cached then
		return cached
	end

	local offers: { Offer } = {}
	for tier, rarityId in Rarity.Order do
		local pool = ItemDatabase.ShopPool[rarityId]
		local slots = math.min(Config.Shop.SlotsPerRarity[rarityId] or 0, #pool)
		local prng = Prng.new(index * 1000003 + tier * 7919 + 12345)

		-- Partial Fisher-Yates over a copy of the (sorted) pool: after step i,
		-- positions 1..i hold i distinct randomly chosen items.
		local bag: { ItemDatabase.Item } = table.clone(pool)
		for i = 1, slots do
			local j = i + math.floor(prng.next() * (#bag - i + 1))
			bag[i], bag[j] = bag[j], bag[i]
			local item = bag[i]
			table.insert(offers, {
				ItemId = item.Id,
				Rarity = rarityId,
				Price = Rarity.Info[rarityId].ShopPrice,
			})
		end
	end

	-- One small entry per day; even a server that runs for months stays tiny.
	cache[index] = offers
	return offers
end

function ShopRotation.findOffer(index: number, itemId: string): Offer?
	for _, offer in ShopRotation.offersFor(index) do
		if offer.ItemId == itemId then
			return offer
		end
	end
	return nil
end

return ShopRotation
