--!strict
--[[
	SwingMath.luau  (ReplicatedStorage.GolfRivals.Shared)

	Turns the player's two swing numbers (power 0-100, accuracy offset -1..1)
	plus club, stats, lie and wind into launch conditions, then into a full
	shot via ShotPhysics. Also holds the anti-cheat plausibility check.

	PIPELINE
	  1. fullSpeed  = calibrated ball speed whose flat, no-wind carry equals the
	                  slot's BaseCarryYds (bisection over ShotPhysics; cached).
	  2. ballSpeed  = fullSpeed * (power/100)^PowerToSpeedExponent
	                  * ClubStats.speedFactor(Power stat)
	                  * LieSpeedMult
	  3. green zone = GreenHalfWidth + GreenWidthPerAccuracy * Accuracy/100,
	                  shrunk by the lie penalty:  g = g0 * (1 - penalty)
	     penalty   = ClubStats.liePenalty(lie, Spin stat)
	  4. inside the green zone -> no curve ("Perfect").  Outside:
	       t        = (|offset| - g) / (1 - g)                      (0..1)
	       severity = t ^ SidespinExponent * (1 - AccuracyMitigation * Accuracy/100)
	                  * (1 + penalty)
	       sidespin = -sign(offset) * severity * MaxSidespinRpm
	     (offset < 0 = early = slice = negative sidespin = curves right)
	  5. backspin   = slot.BackspinRpm * LieSpinMult * (0.5 + 0.5 * power/100)
	     grip       = ClubStats.gripFactor(Spin stat)  (landing check only - no carry change)
	  6. launch angle = slot.LaunchDeg

	Putter: speed is calibrated so a 100% putt rolls PuttFullPowerYards on a
	flat green (v = sqrt(2 * mu * g * d)); with the 0.5 exponent, distance is
	then linear in power. A timing miss becomes an aim error instead of curve.
]]

local Types = require(script.Parent.Types)
local Config = require(script.Parent.Config)
local ClubDatabase = require(script.Parent.ClubDatabase)
local ClubStats = require(script.Parent.ClubStats)
local ShotPhysics = require(script.Parent.ShotPhysics)
local Validate = require(script.Parent.Validate)

local S = Config.Swing
local P = Config.Physics

export type Quality = "Perfect" | "Good" | "Poor"

export type ShotInput = {
	Slot: ClubDatabase.BagSlot,
	Stats: ClubDatabase.Stats, -- upgrade-adjusted (ClubDatabase.statAtLevel)
	Power: number, -- 0..100
	AccuracyOffset: number, -- -1..1
	Lie: Types.LieId, -- lie the ball is hit FROM
	Wind: ShotPhysics.Wind?, -- local frame, m/s
}

export type ResolvedShot = {
	Launch: ShotPhysics.Launch,
	Quality: Quality,
	GreenHalfWidth: number, -- effective green zone (UI can draw it)
	Result: ShotPhysics.ShotResult,
}

local SwingMath = {}

-- ---------------------------------------------------------------------------
-- Calibration cache: slot label -> full-power ball speed (m/s)
-- ---------------------------------------------------------------------------
local fullSpeedCache: { [string]: number } = {}

function SwingMath.fullSpeed(slot: ClubDatabase.BagSlot): number
	local cached = fullSpeedCache[slot.Label]
	if cached then
		return cached
	end
	local speed: number
	if slot.Class == "Putter" then
		-- A rolling ball with friction mu decelerates at mu*g: d = v^2 / (2 mu g).
		local mu = Config.Lies.Green.RollFriction
		speed = math.sqrt(2 * mu * P.Gravity * S.PuttFullPowerYards * P.YardsToMeters)
	else
		speed = ShotPhysics.calibrateBallSpeed(slot.LaunchDeg, slot.BackspinRpm, slot.BaseCarryYds)
	end
	fullSpeedCache[slot.Label] = speed
	return speed
end

-- ---------------------------------------------------------------------------
-- Accuracy
-- ---------------------------------------------------------------------------

-- Lie penalty after the Spin stat: 0 (none) .. ~0.45 (sand, Spin 0).
function SwingMath.effectivePenalty(lie: Types.LieId, spin: number): number
	return ClubStats.liePenalty(lie, spin)
end

-- Effective green-zone half-width in offset units.
function SwingMath.greenHalfWidth(accuracy: number, penalty: number): number
	local base = S.GreenHalfWidth + S.GreenWidthPerAccuracy * math.clamp(accuracy, 0, 100) / 100
	return base * (1 - penalty)
end

-- Curve severity 0..(1+penalty) for a given offset.
function SwingMath.severity(offset: number, accuracy: number, penalty: number): number
	local green = SwingMath.greenHalfWidth(accuracy, penalty)
	local miss = math.abs(offset)
	if miss <= green then
		return 0
	end
	local t = math.clamp((miss - green) / (1 - green), 0, 1)
	local mitigation = 1 - S.AccuracyMitigation * math.clamp(accuracy, 0, 100) / 100
	return t ^ S.SidespinExponent * mitigation * (1 + penalty)
end

function SwingMath.quality(offset: number, greenHalfWidth: number): Quality
	local miss = math.abs(offset)
	if miss <= greenHalfWidth then
		return "Perfect"
	elseif miss <= S.GoodHalfWidth then
		return "Good"
	end
	return "Poor"
end

-- ---------------------------------------------------------------------------
-- Launch + full shot
-- ---------------------------------------------------------------------------

function SwingMath.computeLaunch(input: ShotInput): (ShotPhysics.Launch, Quality, number)
	local slot, stats = input.Slot, input.Stats
	local power = math.clamp(input.Power, 0, 100)
	local offset = math.clamp(input.AccuracyOffset, -1, 1)
	local lie = Config.Lies[input.Lie]

	local penalty = SwingMath.effectivePenalty(input.Lie, stats.Spin)
	local green = SwingMath.greenHalfWidth(stats.Accuracy, penalty)
	local severity = SwingMath.severity(offset, stats.Accuracy, penalty)
	-- negative offset (early) -> slice (right); positive (late) -> hook (left)
	local signedSeverity = if offset < 0 then -severity else severity

	local distanceFactor = ClubStats.speedFactor(stats.Power)
	local powerFactor = (power / 100) ^ S.PowerToSpeedExponent
	local isPutt = slot.Class == "Putter"
	-- Lie speed penalty doesn't apply to putts (they're hit on the green).
	local lieSpeed = if isPutt then 1 else lie.SpeedMult
	local ballSpeed = SwingMath.fullSpeed(slot) * powerFactor * distanceFactor * lieSpeed

	local launch: ShotPhysics.Launch = {
		BallSpeed = ballSpeed,
		LaunchAngleRad = math.rad(slot.LaunchDeg),
		BackspinRpm = slot.BackspinRpm * lie.SpinMult * (0.5 + 0.5 * power / 100),
		SidespinRpm = signedSeverity * S.MaxSidespinRpm, -- early (<0) = negative = slice
		AimOffsetRad = if isPutt then -signedSeverity * math.rad(S.MaxPuttAngleDeg) else 0,
		IsPutt = isPutt,
		GripMult = ClubStats.gripFactor(stats.Spin),
	}
	if isPutt then
		launch.SidespinRpm = 0
	end
	return launch, SwingMath.quality(offset, green), green
end

function SwingMath.resolveShot(input: ShotInput, terrain: ShotPhysics.Terrain, cup: ShotPhysics.Cup?): ResolvedShot
	local launch, quality, green = SwingMath.computeLaunch(input)
	-- Putts ignore wind (ball stays on the ground).
	local wind = if launch.IsPutt then nil else input.Wind
	return {
		Launch = launch,
		Quality = quality,
		GreenHalfWidth = green,
		Result = ShotPhysics.simulate(launch, terrain, wind, cup),
	}
end

-- ---------------------------------------------------------------------------
-- Wind helper
-- ---------------------------------------------------------------------------

-- Convert a world wind (speed in mph, direction the air moves TOWARD, degrees
-- clockwise on the map) into the shot-local frame, given the aim heading in the
-- same convention.  rel = windDir - aimDir:
--    rel = 0   -> wind blows the way you aim  (tailwind, +X)
--    rel = 90  -> wind blows to your right    (+Z)
--    rel = 180 -> headwind                    (-X)
function SwingMath.windToLocal(speedMph: number, windDirDeg: number, aimDirDeg: number): ShotPhysics.Wind
	local rel = math.rad(windDirDeg - aimDirDeg)
	local mps = speedMph * P.MphToMetersPerSec
	return { X = mps * math.cos(rel), Z = mps * math.sin(rel) }
end

-- ---------------------------------------------------------------------------
-- Anti-cheat
-- ---------------------------------------------------------------------------

-- Fastest a human could have produced (power, offset) from the moment the
-- timing bar became available (2-stage bar, see SwingStateMachine):
--   power stage    = power/100 * PowerSweep            (first rise of the marker)
--   accuracy stage = (offset + 1) / 2 * AccuracySweep  (needle travel to `offset`)
-- offset == -1 is a CLAMP ("this early or earlier"): it can be produced by
-- clicking immediately after click 1, so it needs no accuracy time.
-- Putts use the slower putting speeds.
function SwingMath.minSwingSeconds(power: number, offset: number, isPutt: boolean?): number
	local p = math.clamp(power, 0, 100) / 100
	local powerSweep = if isPutt then S.PuttPowerSweepSeconds else S.PowerSweepSeconds
	local accuracySweep = if isPutt then S.PuttAccuracySweepSeconds else S.AccuracySweepSeconds
	local accuracy = if offset <= -1 then 0 else (math.clamp(offset, -1, 1) + 1) / 2 * accuracySweep
	return p * powerSweep + accuracy
end

-- Full server-side check of a swing payload. `elapsedSeconds` is how long the
-- server has had the timing bar open for this player (measured on the SERVER).
-- Returns (true) or (false, reason).
function SwingMath.validateSubmission(power: any, offset: any, elapsedSeconds: number, isPutt: boolean?): (boolean, string?)
	if not Validate.numberInRange(power, 0, 100) then
		return false, "bad_power"
	end
	if not Validate.numberInRange(offset, -1, 1) then
		return false, "bad_offset"
	end
	if (power :: number) < S.MinPower then
		return false, "power_too_low"
	end
	if elapsedSeconds + S.TimingToleranceSeconds < SwingMath.minSwingSeconds(power :: number, offset :: number, isPutt) then
		return false, "too_fast"
	end
	return true, nil
end

return SwingMath
