--!strict
--[[
	CaseDatabase.luau  (ReplicatedStorage.GolfRivals.Shared)

	The three loot-box ("case") types. Each case draws from exactly one item
	category in ItemDatabase:

	  club_skins_case      -> ClubSkin
	  animations_case      -> Animation   (swings, stances, victory emotes)
	  ball_cosmetics_case  -> BallCosmetic (ball models, trails, hole effects)

	HOW A CASE OPENS (implemented server-side in a later step):
	  1. Pick a rarity using DropWeights (cumulative-weight roll over Rarity.Order).
	  2. Pick uniformly among getPool(caseId, rarity).
	  Both rolls use the server's Random - never the client.

	DROP WEIGHTS are integers out of WEIGHT_TOTAL (10,000 = basis points) so
	the odds are exact (no floating-point drift). The default table gives the
	percentages shown in the case-opening UI:
	  Common 45% | Uncommon 30% | Rare 15% | Unique 7% | Legendary 2% | Mythical 1%
]]

local Types = require(script.Parent.Types)
local Rarity = require(script.Parent.Rarity)
local ItemDatabase = require(script.Parent.ItemDatabase)
local TableUtil = require(script.Parent.TableUtil)

type RarityId = Types.RarityId

export type CaseDef = {
	Id: string,
	Name: string,
	Description: string,
	Category: Types.ItemCategory,
	Price: Types.Price,
	DropWeights: { [RarityId]: number },
	IconAssetId: string, -- placeholder until the 3D crate art is uploaded
}

local CaseDatabase = {}

-- Every case's weights must sum to this.
CaseDatabase.WEIGHT_TOTAL = 10000

-- Shared by all cases unless a case overrides DropWeights (e.g. a future
-- "premium" crate with better odds).
CaseDatabase.DefaultDropWeights = {
	Common = 4500,
	Uncommon = 3000,
	Rare = 1500,
	Unique = 700,
	Legendary = 200,
	Mythical = 100,
} :: { [RarityId]: number }

local cases: { [string]: CaseDef } = {
	club_skins_case = {
		Id = "club_skins_case",
		Name = "Club Skins Case",
		Description = "Skins for all six clubs: Driver, Fairway Wood, Long Iron, Short Iron, Wedge and Putter.",
		Category = "ClubSkin",
		Price = { Currency = "Coins", Amount = 5000 },
		DropWeights = CaseDatabase.DefaultDropWeights,
		IconAssetId = "rbxassetid://0",
	},
	animations_case = {
		Id = "animations_case",
		Name = "Player Animations Case",
		Description = "Contains swings, stances and victory emotes.",
		Category = "Animation",
		Price = { Currency = "Coins", Amount = 4000 },
		DropWeights = CaseDatabase.DefaultDropWeights,
		IconAssetId = "rbxassetid://0",
	},
	ball_cosmetics_case = {
		Id = "ball_cosmetics_case",
		Name = "Golf Ball Cosmetics Case",
		Description = "Contains ball models, trails and hole-drop effects.",
		Category = "BallCosmetic",
		Price = { Currency = "Coins", Amount = 2500 },
		DropWeights = CaseDatabase.DefaultDropWeights,
		IconAssetId = "rbxassetid://0",
	},
}

-- Display order for the Cases UI.
CaseDatabase.Order = TableUtil.deepFreeze({ "club_skins_case", "animations_case", "ball_cosmetics_case" }) :: { string }
CaseDatabase.Cases = TableUtil.deepFreeze(cases) :: { [string]: CaseDef }

-- Takes untrusted input (remote arguments); returns nil for unknown ids.
function CaseDatabase.get(id: any): CaseDef?
	if type(id) ~= "string" then
		return nil
	end
	return CaseDatabase.Cases[id]
end

-- Items this case can drop at a given rarity (sorted by Id).
function CaseDatabase.getPool(caseId: string, rarity: RarityId): { ItemDatabase.Item }
	local def = CaseDatabase.Cases[caseId]
	assert(def, "unknown case id: " .. caseId)
	return ItemDatabase.list(def.Category, rarity)
end

-- Drop chances as percentages (45, 30, 15, 7, 2, 1) for the UI's Drop Rates panel.
function CaseDatabase.getDropPercents(caseId: string): { [RarityId]: number }
	local def = CaseDatabase.Cases[caseId]
	assert(def, "unknown case id: " .. caseId)
	local percents: { [RarityId]: number } = {}
	for _, rarityId in Rarity.Order do
		-- Multiply before dividing: 700/10000*100 drifts to 7.000000000000001,
		-- whereas 700*100/10000 is exactly 7 (all operands are small integers).
		percents[rarityId] = (def.DropWeights[rarityId] or 0) * 100 / CaseDatabase.WEIGHT_TOTAL
	end
	return percents
end

-- Expected coin value of one opening if the player sells whatever drops:
--   EV = sum( weight/total * SellValue[rarity] )
-- DatabaseValidator requires EV < case price so cases are a net coin sink.
function CaseDatabase.expectedSellValue(caseId: string): number
	local def = CaseDatabase.Cases[caseId]
	assert(def, "unknown case id: " .. caseId)
	local total = 0
	for _, rarityId in Rarity.Order do
		local weight = def.DropWeights[rarityId] or 0
		total += weight / CaseDatabase.WEIGHT_TOTAL * Rarity.Info[rarityId].SellValue
	end
	return total
end

return CaseDatabase
