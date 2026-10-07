--!strict
--[[
	ClubAdvisor.luau  (ReplicatedStorage.GolfRivals.Shared)

	Which club to hit. Used by the server (default club each turn, bot planning)
	and by the client (the club picker shows each club's reach and highlights the
	recommendation), so both always agree.

	REACH ESTIMATE
	  Carry grows slightly faster than ball speed (~speed^1.1), so
	      reach = BaseCarryYds * (speedFactor ^ 1.1)
	      speedFactor = ClubStats.speedFactor(Power) * LieSpeedMult
	  It is an estimate for UI and club choice; the real shot is always simulated.
]]

local Types = require(script.Parent.Types)
local Config = require(script.Parent.Config)
local ClubDatabase = require(script.Parent.ClubDatabase)
local ClubStats = require(script.Parent.ClubStats)

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
	local speedFactor = ClubStats.speedFactor(stats.Power) * Config.Lies[lie].SpeedMult
	return slot.BaseCarryYds * speedFactor ^ 1.1
end

-- On the green: ALWAYS the putter (the "auto-putter" rule - nobody chips on a
-- green in Golf Rivals). On short grass (fairway / fringe / tee) within
-- Config.Match.FringeAutoPutterYds of the hole: the putter too. Elsewhere: the
-- shortest club that reaches `distanceYds` (4% margin for roll), else the longest.
function ClubAdvisor.recommendClub(distanceYds: number, lie: Types.LieId, statsFor: (string) -> ClubDatabase.Stats): string
	if lie == "Green" then
		return ClubStats.PUTTER
	end
	if (lie == "Fairway" or lie == "Tee") and distanceYds <= Config.Match.FringeAutoPutterYds then
		return ClubStats.PUTTER
	end
	for _, slot in byReach do
		if ClubAdvisor.estimateCarry(slot, statsFor(slot.Label), lie) * 1.04 >= distanceYds then
			return slot.Label
		end
	end
	return byReach[#byReach].Label
end

return ClubAdvisor
