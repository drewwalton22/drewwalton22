--!strict
--[[
	CaseRoller.luau  (ServerScriptService.GolfRivals.Server)

	Rolls what a case drops. Two independent draws:

	  1. RARITY: integer cumulative-weight roll.
	       roll = floor(rng() * WEIGHT_TOTAL)            -- 0 .. 9999
	       walk Rarity.Order accumulating DropWeights; the first tier whose
	       running total exceeds `roll` wins.
	     Integer weights make the odds exact: Mythical weight 100/10000 is 1.00%.
	  2. ITEM: uniform pick among the case's items of that rarity.

	`rng` is injected: the game passes the server's unpredictable Random; tests
	pass a seeded generator. It must return a float in [0, 1). NEVER seed this
	from anything a client can influence or observe (time, UserId...), or loot
	becomes predictable.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage") -- OFFLINE-STRIP
local Shared = ReplicatedStorage.GolfRivals.Shared -- OFFLINE-STRIP
local Types = require(Shared.Types)
local Rarity = require(Shared.Rarity)
local CaseDatabase = require(Shared.CaseDatabase)
local ItemDatabase = require(Shared.ItemDatabase)

local CaseRoller = {}

function CaseRoller.rollRarity(weights: { [Types.RarityId]: number }, rng: () -> number): Types.RarityId
	local total = CaseDatabase.WEIGHT_TOTAL
	-- min() guards an rng that (incorrectly) returns exactly 1.0.
	local roll = math.min(math.floor(rng() * total), total - 1)
	local running = 0
	for _, rarityId in Rarity.Order do
		running += weights[rarityId] or 0
		if roll < running then
			return rarityId
		end
	end
	-- Unreachable while weights sum to WEIGHT_TOTAL (DatabaseValidator enforces it).
	return Rarity.Order[#Rarity.Order]
end

function CaseRoller.rollItem(case: CaseDatabase.CaseDef, rng: () -> number): ItemDatabase.Item
	local rarityId = CaseRoller.rollRarity(case.DropWeights, rng)
	local pool = CaseDatabase.getPool(case.Id, rarityId)
	local index = math.clamp(math.floor(rng() * #pool) + 1, 1, #pool)
	return pool[index]
end

return CaseRoller
