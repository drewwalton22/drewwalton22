--!strict
--[[
	CameraMath.luau  (ReplicatedStorage.GolfRivals.Shared)

	Camera poses for the match, as pure functions (units are studs; X/Z horizontal,
	Y up). The controller turns a Pose into a CFrame each frame.

	  addressPose : behind the ball, looking down the aim line (waiting to swing).
	  follow      : the post-shot chase camera. "Tracks behind and alongside the
	                ball until it comes to a complete rest":
	                  desired = ball - dir * back + right * side + up * height
	                  back/side/height shrink toward a close-up as the ball slows
	                  (ball speed vs SlowSpeed), height rises a little with the ball's
	                  altitude so the arc stays in frame, and the camera position
	                  chases `desired` with exponential smoothing
	                      pos += (desired - pos) * (1 - e^(-K dt))
	                The camera always LOOKS AT THE BALL, so the ball can never leave
	                the frame; only the camera's position lags (that lag is what gives
	                the broadcast feel).
	  overview / introPose : whole-hole view and the flyover from the green to the tee.

	`dir` is the ball's smoothed horizontal travel direction; `right` = (-dir.Z, dir.X)
	matches the course frame (+Z is to the golfer's right when facing +X).

	ELEVATION: courses have hills, so "the ball's altitude" means its height above
	the GROUND LEVEL the camera tracks (`Floor`: the launch height, following the
	ball down at once and up while it rolls), never its absolute Y - otherwise a
	ball resting on a raised green would keep the camera hovering high above it.
]]

export type Vec3 = { X: number, Y: number, Z: number }
export type Pose = { Pos: Vec3, Look: Vec3 }

export type FollowState = {
	Pos: Vec3,
	Ball: Vec3, -- ball position last frame (for velocity)
	DirX: number, -- smoothed horizontal travel direction (unit)
	DirZ: number,
	Floor: number, -- tracked ground level under the ball (studs)
}

local CameraMath = {}

CameraMath.Tuning = {
	AddressBack = 20,
	AddressHeight = 7,
	Back = 28, -- chase distance behind the ball at speed
	Side = 10, -- offset to the right of the line of flight
	Height = 9,
	HeightPerBallHeight = 0.35, -- extra camera height per stud of ball altitude
	CloseBack = 11, -- close-up distance once the ball is nearly stopped
	CloseSide = 4,
	CloseHeight = 4.5,
	SlowSpeed = 20, -- studs/s at or below which the camera is fully "close"
	PositionK = 5, -- position smoothing rate (1/s) in flight
	ClosePositionK = 7,
	DirectionK = 4, -- how fast the travel direction estimate turns
	GroundY = 0,
	MinGroundClearance = 3,
}

local T = CameraMath.Tuning

local function normalize(x: number, z: number, fallbackX: number, fallbackZ: number): (number, number)
	local length = math.sqrt(x * x + z * z)
	if length < 1e-9 then
		return fallbackX, fallbackZ
	end
	return x / length, z / length
end

local function vec(x: number, y: number, z: number): Vec3
	return { X = x, Y = y, Z = z }
end

-- Behind the ball, looking along the aim direction.
function CameraMath.addressPose(ball: Vec3, aimX: number, aimZ: number): Pose
	local dx, dz = normalize(aimX, aimZ, 1, 0)
	return {
		Pos = vec(ball.X - dx * T.AddressBack, ball.Y + math.max(T.AddressHeight, T.MinGroundClearance), ball.Z - dz * T.AddressBack),
		Look = vec(ball.X + dx * 40, ball.Y + 2, ball.Z + dz * 40),
	}
end

function CameraMath.startFollow(ball: Vec3, aimX: number, aimZ: number): FollowState
	local dx, dz = normalize(aimX, aimZ, 1, 0)
	local pose = CameraMath.addressPose(ball, dx, dz)
	return { Pos = pose.Pos, Ball = ball, DirX = dx, DirZ = dz, Floor = ball.Y }
end

-- Advance the chase camera by dt seconds with the ball now at `ball`.
function CameraMath.follow(state: FollowState, ball: Vec3, dt: number): (FollowState, Pose)
	dt = math.max(dt, 1e-4)

	-- Ball velocity from the last frame.
	local vx, vy, vz = (ball.X - state.Ball.X) / dt, (ball.Y - state.Ball.Y) / dt, (ball.Z - state.Ball.Z) / dt
	local speed = math.sqrt(vx * vx + vy * vy + vz * vz)

	-- Smoothed horizontal direction of travel (kept when the ball is nearly still).
	local dirX, dirZ = state.DirX, state.DirZ
	if math.sqrt(vx * vx + vz * vz) > 4 then
		local tx, tz = normalize(vx, vz, dirX, dirZ)
		local a = 1 - math.exp(-T.DirectionK * dt)
		dirX, dirZ = normalize(dirX + (tx - dirX) * a, dirZ + (tz - dirZ) * a, dirX, dirZ)
	end

	-- 0 = full chase distance (fast), 1 = close-up (almost stopped).
	local close = math.clamp(1 - speed / T.SlowSpeed, 0, 1)
	-- Ground level: drops with the ball at once; rises toward it while it's slow
	-- (rolling on higher ground).
	local floor = math.min(state.Floor, ball.Y)
	if close > 0.3 then
		floor += (ball.Y - floor) * (1 - math.exp(-4 * dt))
	end
	local back = T.Back + (T.CloseBack - T.Back) * close
	local side = T.Side + (T.CloseSide - T.Side) * close
	local height = T.Height + (T.CloseHeight - T.Height) * close + T.HeightPerBallHeight * math.max(0, ball.Y - floor)

	local rightX, rightZ = -dirZ, dirX
	local desired = vec(
		ball.X - dirX * back + rightX * side,
		math.max(ball.Y + height, floor + T.MinGroundClearance),
		ball.Z - dirZ * back + rightZ * side
	)

	local k = T.PositionK + (T.ClosePositionK - T.PositionK) * close
	local a = 1 - math.exp(-k * dt)
	local pos = vec(
		state.Pos.X + (desired.X - state.Pos.X) * a,
		state.Pos.Y + (desired.Y - state.Pos.Y) * a,
		state.Pos.Z + (desired.Z - state.Pos.Z) * a
	)
	pos.Y = math.max(pos.Y, floor + T.MinGroundClearance)

	local nextState: FollowState = { Pos = pos, Ball = ball, DirX = dirX, DirZ = dirZ, Floor = floor }
	return nextState, { Pos = pos, Look = vec(ball.X, ball.Y + 1, ball.Z) }
end

-- Whole hole from behind the tee, high enough to see the green.
function CameraMath.overviewPose(tee: Vec3, pin: Vec3): Pose
	local dx, dz = normalize(pin.X - tee.X, pin.Z - tee.Z, 1, 0)
	local length = math.sqrt((pin.X - tee.X) ^ 2 + (pin.Z - tee.Z) ^ 2)
	return {
		Pos = vec(tee.X - dx * 60, 60 + length * 0.15, tee.Z - dz * 60),
		Look = vec(tee.X + (pin.X - tee.X) * 0.55, 0, tee.Z + (pin.Z - tee.Z) * 0.55),
	}
end

local function smoothstep(a: number): number
	local t = math.clamp(a, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Flyover at hole start: alpha 0 = hovering over the green looking back at the tee,
-- alpha 1 = the overview behind the tee.
function CameraMath.introPose(tee: Vec3, pin: Vec3, alpha: number): Pose
	local e = smoothstep(alpha)
	local dx, dz = normalize(pin.X - tee.X, pin.Z - tee.Z, 1, 0)
	local start: Pose = {
		Pos = vec(pin.X + dx * 70, 55, pin.Z + dz * 70),
		Look = vec(pin.X, 0, pin.Z),
	}
	local finish = CameraMath.overviewPose(tee, pin)
	return {
		Pos = vec(
			start.Pos.X + (finish.Pos.X - start.Pos.X) * e,
			start.Pos.Y + (finish.Pos.Y - start.Pos.Y) * e,
			start.Pos.Z + (finish.Pos.Z - start.Pos.Z) * e
		),
		Look = vec(
			start.Look.X + (finish.Look.X - start.Look.X) * e,
			start.Look.Y + (finish.Look.Y - start.Look.Y) * e,
			start.Look.Z + (finish.Look.Z - start.Look.Z) * e
		),
	}
end

return CameraMath
