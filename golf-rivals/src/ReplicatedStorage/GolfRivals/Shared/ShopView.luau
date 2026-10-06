--!strict
--[[
	ShopView.luau  (ReplicatedStorage.GolfRivals.Shared)

	What the Skin Shop screen (mockup panel 3) shows, from the server's GetShop reply
	and the local profile. Tabs split today's offers by what they are; club skins can
	also be filtered by club class (All / Drivers / Fairway Woods / Irons / Wedges /
	Putters). Cards are sorted by rarity then name so the layout is stable.
]]

local Types = require(script.Parent.Types)
local Format = require(script.Parent.Format)
local ItemDatabase = require(script.Parent.ItemDatabase)
local Rarity = require(script.Parent.Rarity)
local ProfileOps = require(script.Parent.ProfileOps)
local ProfileTemplate = require(script.Parent.ProfileTemplate)

export type Offer = {
	ItemId: string,
	Rarity: Types.RarityId,
	Price: Types.Price,
	Purchased: boolean,
}

export type Card = {
	ItemId: string,
	Name: string,
	Description: string,
	Rarity: Types.RarityId,
	Color: Types.RGB,
	SlotLabel: string,
	Currency: Types.CurrencyId,
	Amount: number,
	AmountText: string,
	Purchased: boolean,
	CanAfford: boolean,
	Buyable: boolean, -- not already bought and affordable
	OwnedCount: number,
	Primary: Types.RGB?,
	Secondary: Types.RGB?,
}

local ShopView = {}

ShopView.Tabs = {
	{ Id = "ClubSkin", Label = "CLUB SKINS" },
	{ Id = "BallModel", Label = "BALLS" },
	{ Id = "BallTrail", Label = "TRAILS" },
	{ Id = "HoleEffect", Label = "HOLE EFFECTS" },
	{ Id = "Animation", Label = "ANIMATIONS" },
}

ShopView.ClassFilters = {
	{ Id = "All", Label = "All Clubs" },
	{ Id = "Driver", Label = "Drivers" },
	{ Id = "Wood", Label = "Fairway Woods" },
	{ Id = "Iron", Label = "Irons" },
	{ Id = "Wedge", Label = "Wedges" },
	{ Id = "Putter", Label = "Putters" },
}

local SLOT_NAMES: { [string]: string } = {
	Driver = "Driver Skin", Wood = "Wood Skin", Iron = "Iron Skin", Wedge = "Wedge Skin", Putter = "Putter Skin",
	Swing = "Swing", Stance = "Stance", Emote = "Victory Emote",
	BallModel = "Ball", BallTrail = "Trail", HoleEffect = "Hole Effect",
}

function ShopView.slotLabel(item: ItemDatabase.Item): string
	return SLOT_NAMES[item.Slot] or item.Slot
end

-- Which tab an item belongs to.
function ShopView.tabOf(item: ItemDatabase.Item): string
	if item.Category == "ClubSkin" then
		return "ClubSkin"
	elseif item.Category == "Animation" then
		return "Animation"
	end
	return item.Slot -- BallModel / BallTrail / HoleEffect
end

function ShopView.cards(offers: { Offer }, profile: ProfileTemplate.ProfileData, tab: string, classFilter: string?): { Card }
	local cards: { Card } = {}
	for _, offer in offers do
		local item = ItemDatabase.get(offer.ItemId)
		if item and ShopView.tabOf(item) == tab and (tab ~= "ClubSkin" or classFilter == nil or classFilter == "All" or item.Slot == classFilter) then
			local canAfford = ProfileOps.canAfford(profile, offer.Price)
			table.insert(cards, {
				ItemId = item.Id,
				Name = item.Name,
				Description = item.Description,
				Rarity = item.Rarity,
				Color = Rarity.Info[item.Rarity].Color,
				SlotLabel = ShopView.slotLabel(item),
				Currency = offer.Price.Currency,
				Amount = offer.Price.Amount,
				AmountText = Format.commas(offer.Price.Amount),
				Purchased = offer.Purchased,
				CanAfford = canAfford,
				Buyable = canAfford and not offer.Purchased,
				OwnedCount = ProfileOps.ownedCount(profile, item.Id),
				Primary = item.Visual.Primary,
				Secondary = item.Visual.Secondary,
			})
		end
	end
	table.sort(cards, function(a: Card, b: Card)
		local ta, tb = Rarity.Info[a.Rarity].Tier, Rarity.Info[b.Rarity].Tier
		if ta ~= tb then
			return ta < tb
		end
		return a.Name < b.Name
	end)
	return cards
end

-- Offers per tab (for the little count badges on the tab buttons).
function ShopView.tabCounts(offers: { Offer }): { [string]: number }
	local counts: { [string]: number } = {}
	for _, offer in offers do
		local item = ItemDatabase.get(offer.ItemId)
		if item then
			local tab = ShopView.tabOf(item)
			counts[tab] = (counts[tab] or 0) + 1
		end
	end
	return counts
end

function ShopView.countdown(endsAt: number, now: number): string
	return "REFRESHES IN " .. Format.countdown(endsAt - now)
end

return ShopView
