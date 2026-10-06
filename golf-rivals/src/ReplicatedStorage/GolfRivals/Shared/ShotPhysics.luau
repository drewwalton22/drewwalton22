--!strict
--[[
	ShotPhysics.luau  (ReplicatedStorage.GolfRivals.Shared)

	Server-authoritative ball flight: launch -> air -> bounce(s) -> roll -> rest.
	Pure Luau (no Roblox APIs), deterministic (no RNG), so the same inputs give
	the same result on the server, in bot simulations, and in the client's
	trajectory prediction.

	COORDINATE FRAME (metres, seconds; the shot is simulated in its own local
	frame, the Roblox layer rotates/translates it to the world by the aim):
	    +X = downrange (toward the target)   +Y = up   +Z = to the golfer's right
	Start position is (0, ground, 0).

	FLIGHT MODEL - three forces per unit mass, integrated with a fixed step
	(semi-implicit Euler, dt = Config.Physics.TimeStep):
	  vrel   = v - wind                          (air-relative velocity)
	  gravity: a = (0, -g, 0)
	  drag:    a = -(1/2 rho A Cd / m) * |vrel| * vrel
	  lift:    a =  (1/2 rho A Cl / m) * |vrel|^2 * unit(omega x vrel)     (Magnus)
	where omega is the spin vector (rad/s):
	    omega = (0, sidespin, backspin)
	    omega x v has +Y (lift) for backspin > 0, and -Z (curve LEFT) for
	    sidespin > 0. So sidespin > 0 = hook, < 0 = slice.
	  Lift coefficient from the spin parameter S = |omega| r / |vrel|:
	    Cl = min(LiftCap, LiftPerSpin * S)
	  (real golf-ball data is roughly linear: Cl ~ 0.15 at S ~ 0.1, saturating ~0.25-0.3)
	  Spin decays exponentially: omega *= exp(-SpinDecayPerSec * dt).

	LANDING (each time the ball reaches the ground):
	  n = terrain surface normal, vn = v.n (negative = into the ground)
	  vn_out = -vn * Restitution[lie]                      (vertical bounce)
	  v_tangent_out = v_tangent * retain
	  retain = TangentRetain[lie] * (1 - BackspinBrake * backspin/SpinReference)
	           floored at MinTangentRetain  (negative = ball spins BACK)
	  spin *= SpinImpactLoss.
	  When vn_out < MinBounceSpeed (or MaxBounces reached) the ball starts rolling.

	ROLL (2D on the ground, dt = RollTimeStep):
	  a = -g * gradH  -  mu * g * unit(v)       (slope pull minus rolling friction)
	  gradH = (dh/dx, dh/dz) from the terrain. If friction would reverse the
	  motion the ball stops; a stopped ball stays put only if |gradH| <= mu,
	  otherwise it starts rolling down the slope again (steep greens).

	TERRAIN is injected (see `Terrain`): heightAt / lieAt / slopeAt. The server
	supplies a raycast-backed implementation; tests use flat or sloped functions.
]]

local Types = require(script.Parent.Types)
local Config = require(script.Parent.Config)

export type Terrain = {
	heightAt: (x: number, z: number) -> number,
	lieAt: (x: number, z: number) -> Types.LieId,
	-- Surface gradient (dh/dx, dh/dz), dimensionless (0.03 = 3% slope).
	slopeAt: (x: number, z: number) -> (number, number),
	-- Optional per-surface physics (bounce, roll friction...) overriding the lie's
	-- defaults - e.g. a raycast terrain returns the Smooth Terrain material's own
	-- values (rock bounces more than grass). nil = Config.Lies[lie].
	physicsAt: ((x: number, z: number) -> Config.LieDef?)?,
}

export type Wind = { X: number, Z: number } -- m/s the air moves toward (+X tailwind, +Z blows right)
export type Cup = { X: number, Z: number }

export type Launch = {
	BallSpeed: number, -- m/s
	LaunchAngleRad: number, -- above horizontal (ignored for putts)
	BackspinRpm: number,
	SidespinRpm: number, -- + hook (left), - slice (right)
	AimOffsetRad: number, -- putts only: aim error, + = right
	IsPutt: boolean,
	-- Spin-stat grip: multiplies the landing backspin brake (nil = 1). Changes how
	-- quickly the ball stops after landing, never the carry.
	GripMult: number?,
}

export type Sample = { T: number, X: number, Y: number, Z: number }

export type Outcome = "Rest" | "Water" | "Holed"

export type ShotResult = {
	Outcome: Outcome,
	-- Telemetry (overlay values; yards/feet/rpm/mph as shown to the player)
	CarryYds: number,
	TotalYds: number, -- straight-line horizontal distance start -> rest
	RollYds: number, -- TotalYds - CarryYds (negative if the ball spun back)
	ApexFeet: number,
	SpinRpm: number, -- total spin at launch
	BallSpeedMph: number,
	LateralYds: number, -- final offset, + = right of the aim line
	FlightSeconds: number,
	TotalSeconds: number,
	-- Metres, in the local frame
	LandingX: number,
	LandingZ: number,
	FinalX: number,
	FinalY: number,
	FinalZ: number,
	Samples: { Sample }, -- every SampleInterval, for the client camera/ball playback
}

local ShotPhysics = {}

local P = Config.Physics
local RPM_TO_RADS = 2 * math.pi / 60
local BALL_AREA = math.pi * P.BallRadius * P.BallRadius
-- Constant part of drag/lift acceleration: (1/2) * rho * A / m
local AERO_K = 0.5 * P.AirDensity * BALL_AREA / P.BallMass

-- Flat terrain of a single lie, for tests and bot practice ranges.
function ShotPhysics.flatTerrain(lie: Types.LieId): Terrain
	return {
		heightAt = function(_x: number, _z: number): number
			return 0
		end,
		lieAt = function(_x: number, _z: number): Types.LieId
			return lie
		end,
		slopeAt = function(_x: number, _z: number): (number, number)
			return 0, 0
		end,
	}
end

-- Lie and bounce/roll physics of the surface under (x, z).
local function surfaceAt(terrain: Terrain, x: number, z: number): (Types.LieId, Config.LieDef)
	local lie = terrain.lieAt(x, z)
	local custom = if terrain.physicsAt then terrain.physicsAt(x, z) else nil
	return lie, custom or Config.Lies[lie]
end

-- The cup's "magnet": a gentle pull toward the hole for a slow ball near the
-- rim (forgiving putts and chips). Acceleration (m/s^2) toward the cup centre:
--   a = MagnetAccel * (1 - d / MagnetRadius)   for d < MagnetRadius and
--   ball speed < MagnetMaxSpeed; zero otherwise.
function ShotPhysics.magnetAt(cup: Cup?, x: number, z: number, speed: number): (number, number)
	if cup == nil or speed > P.MagnetMaxSpeed then
		return 0, 0
	end
	local dx, dz = cup.X - x, cup.Z - z
	local d = math.sqrt(dx * dx + dz * dz)
	if d >= P.MagnetRadius or d < 1e-9 then
		return 0, 0
	end
	local a = P.MagnetAccel * (1 - d / P.MagnetRadius)
	return dx / d * a, dz / d * a
end

local function surfaceNormal(terrain: Terrain, x: number, z: number): (number, number, number)
	local gx, gz = terrain.slopeAt(x, z)
	-- Surface y = h(x,z) has normal (-dh/dx, 1, -dh/dz), normalised.
	local inv = 1 / math.sqrt(gx * gx + 1 + gz * gz)
	return -gx * inv, inv, -gz * inv
end

export type Options = {
	-- Stop at the first touchdown (used by carry calibration and the aim arc).
	CarryOnly: boolean?,
	-- With CarryOnly: still record trajectory samples (calibration skips them for speed).
	KeepSamples: boolean?,
}

-- Simulates one shot. `cup` is optional (greens only matter near the hole).
function ShotPhysics.simulate(launch: Launch, terrain: Terrain, wind: Wind?, cup: Cup?, options: Options?): ShotResult
	local windX = if wind then wind.X else 0
	local windZ = if wind then wind.Z else 0
	local carryOnly = options ~= nil and options.CarryOnly == true
	local skipSamples = carryOnly and not (options ~= nil and options.KeepSamples == true)

	local x, z = 0.0, 0.0
	local startY = terrain.heightAt(0, 0)
	local y = startY
	local t = 0.0
	local apex = 0.0
	local outcome: Outcome = "Rest"
	local landingX, landingZ = 0.0, 0.0
	local flightSeconds = 0.0

	local samples: { Sample } = {}
	local nextSample = 0.0
	local function record(force: boolean)
		if skipSamples then
			return
		end
		if force or t >= nextSample then
			table.insert(samples, { T = t, X = x, Y = y, Z = z })
			nextSample = t + P.SampleInterval
		end
	end

	-- Velocity and spin (spin vector is (0, wy, wz): side, back).
	local vx, vy, vz = 0.0, 0.0, 0.0
	local wy = launch.SidespinRpm * RPM_TO_RADS
	local wz = launch.BackspinRpm * RPM_TO_RADS
	local rolling = launch.IsPutt

	if launch.IsPutt then
		-- Putts start on the ground, already rolling, aimed AimOffsetRad off-line.
		vx = launch.BallSpeed * math.cos(launch.AimOffsetRad)
		vz = launch.BallSpeed * math.sin(launch.AimOffsetRad)
		wy, wz = 0, 0
	else
		vx = launch.BallSpeed * math.cos(launch.LaunchAngleRad)
		vy = launch.BallSpeed * math.sin(launch.LaunchAngleRad)
	end
	record(true)

	-- ---------------------------------------------------------------- FLIGHT
	local dt = P.TimeStep
	local bounces = 0
	local landed = false
	while not rolling and t < P.MaxFlightSeconds do
		local prevX, prevY, prevZ, prevT = x, y, z, t

		-- Air-relative velocity (wind moves the air, not the ball directly).
		local rx, ry, rz = vx - windX, vy, vz - windZ
		local speed = math.sqrt(rx * rx + ry * ry + rz * rz)

		local ax, ay, az = 0.0, -P.Gravity, 0.0
		if speed > 1e-6 then
			-- Drag opposes the air-relative velocity: a = -K * Cd * |v| * v
			local dragScale = AERO_K * P.DragCoeff * speed
			ax -= dragScale * rx
			ay -= dragScale * ry
			az -= dragScale * rz

			-- Magnus lift: direction omega x vrel, magnitude K * Cl * |v|^2.
			local spinMag = math.sqrt(wy * wy + wz * wz)
			if spinMag > 1e-6 then
				local cx = wy * rz - wz * ry
				local cy = wz * rx
				local cz = -wy * rx
				local crossMag = math.sqrt(cx * cx + cy * cy + cz * cz)
				if crossMag > 1e-9 then
					local s = spinMag * P.BallRadius / speed -- spin parameter
					local cl = math.min(P.LiftCap, P.LiftPerSpin * s)
					local liftScale = AERO_K * cl * speed * speed / crossMag
					ax += liftScale * cx
					ay += liftScale * cy
					az += liftScale * cz
				end
			end
		end

		vx += ax * dt
		vy += ay * dt
		vz += az * dt
		x += vx * dt
		y += vy * dt
		z += vz * dt
		t += dt

		local decay = math.exp(-P.SpinDecayPerSec * dt)
		wy *= decay
		wz *= decay

		if y - startY > apex then
			apex = y - startY
		end
		record(false)

		local ground = terrain.heightAt(x, z)
		if y <= ground then
			-- Touchdown. Interpolate back to the exact crossing so carry isn't
			-- quantised to the step size (1 step ~ 0.7 m at driver speed).
			local gapBefore = prevY - terrain.heightAt(prevX, prevZ)
			local gapAfter = y - ground
			local f = if gapBefore - gapAfter > 1e-9 then math.clamp(gapBefore / (gapBefore - gapAfter), 0, 1) else 1
			x = prevX + (x - prevX) * f
			z = prevZ + (z - prevZ) * f
			t = prevT + (t - prevT) * f
			y = terrain.heightAt(x, z)

			if not landed then
				landed = true
				landingX, landingZ = x, z
				flightSeconds = t
			end
			record(true)
			if carryOnly then
				break
			end

			local _, def = surfaceAt(terrain, x, z)
			if def.Sinks then
				outcome = "Water"
				break
			end

			-- Bounce: split velocity about the surface normal.
			local nx, ny, nz = surfaceNormal(terrain, x, z)
			local vn = vx * nx + vy * ny + vz * nz
			local tx, ty, tz = vx - vn * nx, vy - vn * ny, vz - vn * nz
			local backspinRpm = wz / RPM_TO_RADS
			local brake = P.BackspinBrake * math.clamp(backspinRpm / P.SpinReferenceRpm, 0, 1.5) * (launch.GripMult or 1)
			local retain = math.max(P.MinTangentRetain, def.TangentRetain * (1 - brake))
			local vnOut = -vn * def.Restitution

			bounces += 1
			wy *= P.SpinImpactLoss
			wz *= P.SpinImpactLoss
			if vnOut < P.MinBounceSpeed or bounces >= P.MaxBounces then
				-- Done bouncing: carry the (retained) horizontal motion into a roll.
				vx, vz = tx * retain, tz * retain
				vy = 0
				rolling = true
			else
				vx = tx * retain + nx * vnOut
				vy = ty * retain + ny * vnOut
				vz = tz * retain + nz * vnOut
				-- Lift slightly off the surface so the next step isn't an instant re-hit.
				y += 1e-4
			end
		end
	end

	if carryOnly then
		return {
			Outcome = outcome,
			CarryYds = math.sqrt(landingX * landingX + landingZ * landingZ) / P.YardsToMeters,
			TotalYds = 0,
			RollYds = 0,
			ApexFeet = apex * P.MetersToFeet,
			SpinRpm = 0,
			BallSpeedMph = launch.BallSpeed / P.MphToMetersPerSec,
			LateralYds = 0,
			FlightSeconds = flightSeconds,
			TotalSeconds = flightSeconds,
			LandingX = landingX,
			LandingZ = landingZ,
			FinalX = landingX,
			FinalY = y,
			FinalZ = landingZ,
			Samples = samples,
		}
	end

	-- ------------------------------------------------------------------ ROLL
	if rolling and outcome == "Rest" then
		local rdt = P.RollTimeStep
		local rvx, rvz = vx, vz
		local rollT = 0.0
		while rollT < P.MaxRollSeconds do
			local _, def = surfaceAt(terrain, x, z)
			if def.Sinks then
				outcome = "Water"
				break
			end

			local mu = def.RollFriction
			local gx, gz = terrain.slopeAt(x, z)
			local speed = math.sqrt(rvx * rvx + rvz * rvz)
			-- Driving force per unit mass: gravity down the slope + the cup magnet.
			local mx, mz = ShotPhysics.magnetAt(cup, x, z, speed)
			local fx, fz = -P.Gravity * gx + mx, -P.Gravity * gz + mz
			local fMag = math.sqrt(fx * fx + fz * fz)
			local grip = mu * P.Gravity

			if speed <= 1e-6 then
				-- At rest: static friction holds the ball unless slope + magnet beat it.
				if fMag <= grip then
					break
				end
				local a = fMag - grip
				rvx = fx / fMag * a * rdt
				rvz = fz / fMag * a * rdt
			else
				local dirX, dirZ = rvx / speed, rvz / speed
				local nvx = rvx + (fx - grip * dirX) * rdt
				local nvz = rvz + (fz - grip * dirZ) * rdt
				if nvx * dirX + nvz * dirZ <= 0 then
					-- Friction reversed the motion: the ball has stopped.
					nvx, nvz = 0, 0
				end
				rvx, rvz = nvx, nvz
			end

			x += rvx * rdt
			z += rvz * rdt
			y = terrain.heightAt(x, z)
			t += rdt
			rollT += rdt
			record(false)

			if cup then
				local dx, dz = x - cup.X, z - cup.Z
				if math.sqrt(dx * dx + dz * dz) < P.CupCaptureRadius and math.sqrt(rvx * rvx + rvz * rvz) < P.CupCaptureSpeed then
					x, z = cup.X, cup.Z
					outcome = "Holed"
					break
				end
			end
		end
	end
	record(true)

	if not landed then
		-- Putts (and shots that never touched down): no airborne phase.
		landingX, landingZ = 0, 0
	end

	local total = math.sqrt(x * x + z * z) / P.YardsToMeters
	local carry = if launch.IsPutt then 0 else math.sqrt(landingX * landingX + landingZ * landingZ) / P.YardsToMeters
	local spinRpm = math.sqrt(launch.BackspinRpm * launch.BackspinRpm + launch.SidespinRpm * launch.SidespinRpm)
	return {
		Outcome = outcome,
		CarryYds = carry,
		TotalYds = total,
		RollYds = total - carry,
		ApexFeet = apex * P.MetersToFeet,
		SpinRpm = if launch.IsPutt then 0 else spinRpm,
		BallSpeedMph = launch.BallSpeed / P.MphToMetersPerSec,
		LateralYds = z / P.YardsToMeters,
		FlightSeconds = flightSeconds,
		TotalSeconds = t,
		LandingX = landingX,
		LandingZ = landingZ,
		FinalX = x,
		FinalY = y,
		FinalZ = z,
		Samples = samples,
	}
end

-- Carry (yards) of a no-wind, flat, straight shot. Used for calibration.
function ShotPhysics.carryYards(ballSpeed: number, launchDeg: number, backspinRpm: number): number
	local result = ShotPhysics.simulate({
		BallSpeed = ballSpeed,
		LaunchAngleRad = math.rad(launchDeg),
		BackspinRpm = backspinRpm,
		SidespinRpm = 0,
		AimOffsetRad = 0,
		IsPutt = false,
	}, ShotPhysics.flatTerrain("Fairway"), nil, nil, { CarryOnly = true })
	return result.CarryYds
end

-- Ball speed (m/s) whose flat, no-wind carry equals targetCarryYds.
-- Carry increases monotonically with speed, so bisection converges.
function ShotPhysics.calibrateBallSpeed(launchDeg: number, backspinRpm: number, targetCarryYds: number): number
	local lo, hi = 5.0, 150.0
	for _ = 1, 40 do
		local mid = (lo + hi) / 2
		if ShotPhysics.carryYards(mid, launchDeg, backspinRpm) < targetCarryYds then
			lo = mid
		else
			hi = mid
		end
	end
	return (lo + hi) / 2
end

return ShotPhysics
