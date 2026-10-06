--!strict
--[[
	Types.luau  (ReplicatedStorage.GolfRivals.Shared)

	Central place for the string-literal union types shared by every module.
	Keeping them here avoids circular requires (e.g. Rarity <-> ItemDatabase)
	and gives the Luau type checker one source of truth for ids.

	This module has no runtime values; `require` it only to reach the types:
		local Types = require(script.Parent.Types)
		local r: Types.RarityId = "Rare"
]]

-- The two currencies. Coins are earned through play/quests; Gems are premium.
export type CurrencyId = "Coins" | "Gems"

-- Rarity tiers, lowest -> highest. Order lives in Rarity.Order.
export type RarityId = "Common" | "Uncommon" | "Rare" | "Unique" | "Legendary" | "Mythical"

-- The three cosmetic families; each maps 1:1 to a case type.
export type ItemCategory = "ClubSkin" | "Animation" | "BallCosmetic"

-- The six club categories (the whole bag) - also the skin slot a club skin
-- occupies. Defined in ClubStats; never add a seventh without updating it.
export type ClubClass = "Driver" | "FairwayWood" | "LongIron" | "ShortIron" | "Wedge" | "Putter"

-- Every equip slot a cosmetic can occupy. Club skins use a ClubClass as slot.
export type ItemSlot =
	ClubClass
	| "Swing" | "Stance" | "Emote" -- Animation slots
	| "BallModel" | "BallTrail" | "HoleEffect" -- BallCosmetic slots

-- Surface the ball sits on / lands on. Drives lie penalties, bounce and roll.
export type LieId = "Tee" | "Fairway" | "Rough" | "Sand" | "Green" | "Water"

-- The three upgradeable club stats (see ClubStats for what each one does).
export type StatId = "Power" | "Accuracy" | "Spin"

export type Price = {
	Currency: CurrencyId,
	Amount: number,
}

-- {r, g, b} 0-255. Plain numbers (not Color3) so the data modules also run in
-- standalone Luau for offline validation; clients convert with Color3.fromRGB.
export type RGB = { number }

return {}
