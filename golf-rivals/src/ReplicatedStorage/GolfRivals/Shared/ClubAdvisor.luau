--!strict
--[[
	ClubAdvisor.luau  (ReplicatedStorage.GolfRivals.Shared)

	Which club to hit. Used by the server (default club each turn, bot planning)
	and by the client (the club picker shows each club's reach and highlights the
	recommendation), so both always agree.

	REACH ESTIMATE
	  Carry grows slightly faster than ball speed (~speed^1.1), so
	      reach = BaseCarryYds * (speedFactor ^ 1.1)
	      speedFactor = (1 + DistanceSpeedPerPoint * (Distance - Baseline)) * LieSpeedMult
	  It is an estimate for UI and club choice; the real shot is always simulated.
]]

local Types = require(script.Parent.Types)
local Config = require(script.Parent.Config)
local ClubDatabase = require(script.Parent.ClubDatabase)

local ClubAdvisor = {}

-- Non-putter bag slots, shortest reach first.
local byReach: { ClubDatabase.BagSlot } = {}
for _, slot in ClubDatabase.BagSlots do
	if slot.Class ~= "Putter" then
		table.insert(byReach, slot)
	end
end
table.sort(byReach, function(a: ClubDatabase.BagSlot, b: ClubDatabase.BagSlot)
	return a.BaseCarryYds < b.BaseCarryYds
end)
ClubAdvisor.ClubsByReach = byReach

-- Rough full-power carry of a slot for given stats and lie, in yards.
function ClubAdvisor.estimateCarry(slot: ClubDatabase.BagSlot, stats: ClubDatabase.Stats, lie: Types.LieId): number
	local S = Config.Swing
	local speedFactor = (1 + S.DistanceSpeedPerPoint * (stats.Distance - S.DistanceStatBaseline)) * Config.Lies[lie].SpeedMult
	return slot.BaseCarryYds * speedFactor ^ 1.1
end

-- Shortest club that reaches `distanceYds` (4% margin for roll), the putter on
-- the green when a putt can cover it, else the longest club.
function ClubAdvisor.recommendClub(distanceYds: number, lie: Types.LieId, statsFor: (string) -> ClubDatabase.Stats): string
	if lie == "Green" and distanceYds <= Config.Swing.PuttFullPowerYards * 0.95 then
		return "PT"
	end
	for _, slot in byReach do
		if ClubAdvisor.estimateCarry(slot, statsFor(slot.Label), lie) * 1.04 >= distanceYds then
			return slot.Label
		end
	end
	return byReach[#byReach].Label
end

return ClubAdvisor
