--!strict
--[[
	BotBrain.luau  (ServerScriptService.GolfRivals.Server)

	Decides a bot's swing. A bot plays by the SAME physics as a human:

	  PLAN  (what a good player would try)
	    1. Club   : recommended club for the distance; if a full-power swing still
	                falls short, step up to the next longer club.
	    2. Aim    : for each candidate aim offset (degrees), simulate a perfect
	                swing that lands near the pin; score = distance from the pin
	                after the ball stops, +1000 for water/out of bounds, +8 for
	                sand, +2 for rough. Pick the best (this is how a
	                bot learns to avoid a pond in front of the green).
	    3. Power  : secant search for the power whose total distance (carry +
	                roll) matches the distance to the target. The plan simulates
	                with only `WindAwareness` of the real wind, so weak bots
	                misjudge it like a person would.

	  EXECUTE (human-like error, from the difficulty profile in Config.Bots)
	    power  += Normal(0, PowerSigma * (0.35 + 0.65 * power/100))   (soft strokes err less)
	    offset  = Normal(0, OffsetSigma)    (a "perfect" click is offset 0)
	    with probability BlunderChance the click is badly mistimed (|offset| ~ 0.7)
	    with probability ClubMistakeChance a neighbouring club is used

	`world` abstracts the engine so the brain is testable: it can read the
	situation and dry-run any swing (no state change).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage") -- OFFLINE-STRIP
local Shared = ReplicatedStorage.GolfRivals.Shared -- OFFLINE-STRIP
local Types = require(Shared.Types)
local Config = require(Shared.Config)
local ClubDatabase = require(Shared.ClubDatabase)
local ShotPhysics = require(Shared.ShotPhysics)
local SwingMath = require(Shared.SwingMath)
local MatchEngine = require(script.Parent.MatchEngine)

local YD = Config.Physics.YardsToMeters

export type World = {
	situation: () -> MatchEngine.Situation,
	preview: (label: string, aimOffsetDeg: number, power: number, offset: number, windScale: number) -> SwingMath.ResolvedShot?,
	-- (lie, inBounds) where a previewed shot would end up.
	landing: (aimOffsetDeg: number, result: ShotPhysics.ShotResult) -> (Types.LieId, boolean),
	statsFor: (label: string) -> ClubDatabase.Stats,
}

export type Decision = {
	ClubLabel: string,
	AimDeg: number,
	Power: number,
	Offset: number,
	Planned: boolean, -- false only when nothing could be planned (falls back to a safe swing)
}

local BotBrain = {}

-- Standard normal via Box-Muller from a uniform rng in [0,1).
local function gauss(rng: () -> number): number
	local u1 = math.max(rng(), 1e-12)
	local u2 = rng()
	return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end
BotBrain.gauss = gauss

-- Where a shot of `total` metres along the shot frame ends relative to the pin,
-- in yards (smaller is better).
local function missYards(result: ShotPhysics.ShotResult, pinXl: number, pinZl: number): number
	local dx, dz = result.FinalX - pinXl, result.FinalZ - pinZl
	return math.sqrt(dx * dx + dz * dz) / YD
end

-- Power (1..100) that makes a straight swing's FinalX reach `targetXl` (metres
-- along the aim), found by secant iteration on the monotone power -> distance map.
local function solvePower(world: World, label: string, aim: number, targetXl: number, windScale: number): (number, ShotPhysics.ShotResult?)
	local function reach(power: number): (number, ShotPhysics.ShotResult?)
		local shot = world.preview(label, aim, power, 0, windScale)
		if shot == nil then
			return 0, nil
		end
		return shot.Result.FinalX, shot.Result
	end

	local lo, hi = 1.0, 100.0
	local reachHi, resHi = reach(hi)
	if reachHi <= targetXl then
		return hi, resHi -- even full power won't get there
	end
	local reachLo, resLo = reach(lo)
	if reachLo >= targetXl then
		return lo, resLo
	end
	-- Regula falsi on [lo, hi], a few iterations is enough for ~0.5 yd accuracy.
	local bestPower, bestResult = hi, resHi
	for _ = 1, 9 do
		if hi - lo < 0.1 then
			break -- bracket collapsed: power resolution is already finer than a click
		end
		local mid = lo + (hi - lo) * (targetXl - reachLo) / (reachHi - reachLo)
		mid = math.clamp(mid, lo + (hi - lo) * 0.02, hi - (hi - lo) * 0.02)
		local reached, result = reach(mid)
		bestPower, bestResult = mid, result
		if math.abs(reached - targetXl) < 0.4 then -- within ~0.4 m
			break
		end
		if reached < targetXl then
			lo, reachLo = mid, reached
		else
			hi, reachHi = mid, reached
		end
	end
	return bestPower, bestResult
end

function BotBrain.decide(world: World, difficulty: string, rng: () -> number): Decision
	local profile = Config.Bots[difficulty]
	local situation = world.situation()
	local windScale = profile.WindAwareness

	-- 1) CLUB ---------------------------------------------------------------
	local label = MatchEngine.recommendClub(situation.DistanceYds, situation.Lie, world.statsFor)
	if label ~= "PT" then
		-- Step up while a full swing falls clearly short of the pin.
		local reach = MatchEngine.ClubsByReach
		local index = 1
		for i, slot in reach do
			if slot.Label == label then
				index = i
			end
		end
		while index < #reach do
			local shot = world.preview(reach[index].Label, 0, 100, 0, windScale)
			if shot and shot.Result.FinalX * 1.0 >= situation.DistanceYds * YD * 0.98 then
				break
			end
			index += 1
		end
		label = reach[index].Label
		-- Human-like club mistakes: a neighbouring club.
		if rng() < profile.ClubMistakeChance then
			index = math.clamp(index + (if rng() < 0.5 then -1 else 1), 1, #reach)
			label = reach[index].Label
		end
	end

	-- 2) AIM + 3) POWER -------------------------------------------------------
	local bestAim, bestPower, bestScore = 0.0, 50.0, math.huge
	for _, aim in profile.AimCandidates do
		-- Distance to the pin measured along this aim line.
		local pinHeading = math.rad(aim)
		local targetXl = situation.DistanceYds * YD * math.cos(pinHeading)
		-- Pin position in the shot frame, for scoring the planned landing.
		local pinXl, pinZl = situation.DistanceYds * YD * math.cos(pinHeading), -situation.DistanceYds * YD * math.sin(pinHeading)
		local power, planned = solvePower(world, label, aim, targetXl, windScale)
		if planned then
			local score = missYards(planned, pinXl, pinZl)
			local endLie, inBounds = world.landing(aim, planned)
			if planned.Outcome == "Water" or endLie == "Water" or not inBounds then
				score += 1000 -- never plan into a hazard if any alternative exists
			elseif planned.Outcome == "Holed" then
				score = 0
			elseif endLie == "Sand" then
				score += 8 -- a bunker costs about 8 yards of expected result
			elseif endLie == "Rough" then
				score += 2
			end
			-- Prefer the pin line over fancy angles when it is equally good.
			score += math.abs(aim) * 0.05
			if score < bestScore then
				bestAim, bestPower, bestScore = aim, power, score
			end
		end
	end

	-- 4) EXECUTION ERROR ------------------------------------------------------
	-- Gauge error scales with how hard the swing is: a soft chip or putt has a
	-- proportionally smaller absolute error than a full swing (a 30% putt isn't
	-- off by 9 points just because a driver might be).
	local powerSigma = profile.PowerSigma * (0.35 + 0.65 * bestPower / 100)
	local power = math.clamp(bestPower + gauss(rng) * powerSigma, 1, 100)
	local offset = gauss(rng) * profile.OffsetSigma
	if rng() < profile.BlunderChance then
		offset = (if rng() < 0.5 then -1 else 1) * (0.6 + rng() * 0.2)
	end
	offset = math.clamp(offset, -1, 1)

	return { ClubLabel = label, AimDeg = bestAim, Power = power, Offset = offset, Planned = bestScore < math.huge }
end

-- Bots use their difficulty's stats on every club.
function BotBrain.statsFor(difficulty: string): (string) -> ClubDatabase.Stats
	local stats = Config.Bots[difficulty].Stats
	local copy: ClubDatabase.Stats = { Power = stats.Power, Accuracy = stats.Accuracy, Spin = stats.Spin }
	return function(_label: string): ClubDatabase.Stats
		return copy
	end
end

-- Convenience for the match loop: plan and play one bot swing on an engine.
-- Returns the decision that was played (nil if the engine refused it).
function BotBrain.play(engine: MatchEngine.Engine, playerId: string, difficulty: string, rng: () -> number, now: number): Decision?
	local world: World = {
		situation = function(): MatchEngine.Situation
			return engine.situation(playerId) :: MatchEngine.Situation
		end,
		preview = function(label: string, aimOffsetDeg: number, power: number, offset: number, windScale: number): SwingMath.ResolvedShot?
			return engine.preview(playerId, label, aimOffsetDeg, power, offset, windScale)
		end,
		landing = function(aimOffsetDeg: number, result: ShotPhysics.ShotResult): (Types.LieId, boolean)
			return engine.landing(playerId, aimOffsetDeg, result)
		end,
		statsFor = BotBrain.statsFor(difficulty),
	}
	local decision = BotBrain.decide(world, difficulty, rng)
	local ok = engine.submitBotSwing(playerId, decision.ClubLabel, decision.AimDeg, decision.Power, decision.Offset, now)
	return if ok then decision else nil
end

return BotBrain
