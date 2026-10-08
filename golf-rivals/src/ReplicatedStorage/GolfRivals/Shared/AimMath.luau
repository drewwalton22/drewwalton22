--!strict
--[[
	AimMath.luau  (ReplicatedStorage.GolfRivals.Shared)

	The aerial aiming reticle as pure math (hole-frame metres, like everything the
	engine uses). The client drags a reticle on the ground in the top-down view;
	this module turns "where the player pointed" into what the game needs:

	  clamp(ball, point, ...)  -> the reticle actually allowed:
	        distance  clamped to [MinMeters, the club's MaxDistance]
	                  (ClubStats.maxDistanceYds, stat-adjusted)
	        direction clamped to +/- MaxAimDegrees from the pin line (the same limit
	                  the server enforces on SetAim)
	  -> AimDeg (sent to the server with SetAim) and DistanceYds

	  targetPower(distanceYds, maxYds) -> the power (0..1) that sends a perfect
	        strike that far. Carry% tracks power% for full swings (PowerToSpeedExponent
	        is tuned for it) and putt roll is linear in power, so it is the ratio.
	        The timing bar shows it as a white tick on the power track.
]]

local Config = require(script.Parent.Config)

export type Reticle = {
	X: number, -- clamped reticle position (hole frame metres)
	Z: number,
	DistanceMeters: number,
	DistanceYds: number,
	AimDeg: number, -- offset from the pin line, what SetAim takes
	Clamped: boolean, -- the requested point was pulled back inside the limits
}

local AimMath = {}

AimMath.MIN_METERS = 1.5

local function wrapDegrees(deg: number): number
	return (deg + 180) % 360 - 180
end

-- `pinHeadingRad`: direction from the ball to the pin (hole frame).
function AimMath.clamp(ballX: number, ballZ: number, pointX: number, pointZ: number, pinHeadingRad: number, maxMeters: number, maxAimDeg: number?): Reticle
	local limit = maxAimDeg or Config.Match.MaxAimDegrees
	local dx, dz = pointX - ballX, pointZ - ballZ
	local distance = math.sqrt(dx * dx + dz * dz)
	local aimDeg = if distance > 1e-6 then wrapDegrees(math.deg(math.atan2(dz, dx) - pinHeadingRad)) else 0
	local clampedAim = math.clamp(aimDeg, -limit, limit)
	local clampedDistance = math.clamp(distance, AimMath.MIN_METERS, math.max(AimMath.MIN_METERS, maxMeters))
	local heading = pinHeadingRad + math.rad(clampedAim)
	return {
		X = ballX + math.cos(heading) * clampedDistance,
		Z = ballZ + math.sin(heading) * clampedDistance,
		DistanceMeters = clampedDistance,
		DistanceYds = clampedDistance / Config.Physics.YardsToMeters,
		AimDeg = clampedAim,
		Clamped = math.abs(clampedAim - aimDeg) > 1e-9 or math.abs(clampedDistance - distance) > 1e-9,
	}
end

-- Power (0..1) for a perfect strike that travels `distanceYds` with a club whose
-- full-power distance is `maxYds`.
function AimMath.targetPower(distanceYds: number, maxYds: number): number
	if maxYds <= 0 then
		return 1
	end
	return math.clamp(distanceYds / maxYds, Config.Swing.MinPower / 100, 1)
end

-- Where the reticle starts each turn: on the pin line, at the pin or the club's
-- full distance, whichever is closer.
function AimMath.defaultReticle(ballX: number, ballZ: number, pinX: number, pinZ: number, maxMeters: number): Reticle
	local heading = math.atan2(pinZ - ballZ, pinX - ballX)
	return AimMath.clamp(ballX, ballZ, pinX, pinZ, heading, maxMeters)
end

return AimMath
