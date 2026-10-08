--!strict
--[[
	BallAnimator.luau  (Client/Match)

	A golf ball Part that can sit on the course or fly a server-authoritative shot.

	`play(shot, ...)` walks the ball along the shot's sampled trajectory
	(Samples = { {t, x, y, z}, ... } in the hole frame, from MatchEngine) by
	advancing a clock each frame and interpolating with TelemetryView.positionAt.
	The server already decided where the ball goes; the client only shows it, so a
	modified client can't change a result.

	Cosmetics come from CosmeticsData via CosmeticBuilder: the equipped Ball Model
	(colour, material, optional mesh skin, glow) and Ball Trail (streak, sparkles or
	a lagging Beam ribbon). `burst` is a plain particle pop (water splash etc.);
	hole-drop effects use CosmeticBuilder.holeEffect.

	SIZE: CourseLayout.BALL_DIAMETER (0.4 studs - below an avatar's ankle). So it stays
	easy to see, it keeps its trail and gets a white OUTLINE (a Highlight) whenever
	it's more than OUTLINE_DISTANCE studs from the camera.

	HOLE DROP: the physics catches a holed ball at the hole's EDGE (it no longer
	snaps to the pole). From there the ball keeps travelling across the hole while
	it falls (CupGeometry.dropAt), lands on the pocket's floor against the far wall
	beside the flagstick, rattles once (Assets.sound("CupDrop")) and stays there,
	its top below the green surface. A tap-in that stopped short first rolls to
	the edge. restInCup() puts a holed ball back in the same spot whenever the
	match state is re-applied.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.GolfRivals.Shared
local CosmeticsData = require(Shared.CosmeticsData)
local CourseLayout = require(Shared.CourseLayout)
local TelemetryView = require(Shared.TelemetryView)
local CupGeometry = require(Shared.CupGeometry)
local Assets = require(Shared.Assets)

local CosmeticBuilder = require(script.Parent.Parent.Golf.CosmeticBuilder)

export type Appearance = {
	Ball: CosmeticsData.BallLook,
	Trail: CosmeticsData.TrailLook,
}

export type Animator = {
	Part: Part,
	placeAt: (position: Vector3) -> (),
	setVisible: (visible: boolean) -> (),
	play: (shot: any, toWorld: (number, number, number) -> Vector3, onFrame: ((t: number, position: Vector3) -> ())?, onDone: (() -> ())?) -> (),
	stop: () -> (),
	restInCup: (cupSurface: Vector3) -> (), -- cupSurface = turf point at the cup centre
	destroy: () -> (),
}

local BallAnimator = {}

local BALL_DIAMETER = CourseLayout.BALL_DIAMETER
local LIFT = BALL_DIAMETER / 2 + 0.1 -- centre above the ground (the green turf sits 0.1 proud)
local ROLL_IN_SPEED = 4 -- studs/s: a tap-in rolling up to the hole's edge
local OUTLINE_DISTANCE = 35 -- studs from the camera before the outline turns on

local function playSound(parent: Instance, id: string, volume: number)
	if id == "" then
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.Volume = volume
	sound.RollOffMaxDistance = 120
	sound.Parent = parent
	sound:Play()
	Debris:AddItem(sound, 3)
end

function BallAnimator.new(parent: Instance, appearance: Appearance, name: string): Animator
	local ball = Instance.new("Part")
	ball.Name = name
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(BALL_DIAMETER, BALL_DIAMETER, BALL_DIAMETER)
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanTouch = false
	ball.CanQuery = false
	ball.CastShadow = true
	ball.Parent = parent
	CosmeticBuilder.dressBall(ball, appearance.Ball)
	local trail = CosmeticBuilder.trail(ball, appearance.Trail)

	-- Far away the small ball gets a bright outline so it never gets lost.
	local outline = Instance.new("Highlight")
	outline.Name = "FarOutline"
	outline.Adornee = ball
	outline.FillTransparency = 1
	outline.OutlineColor = Color3.new(1, 1, 1)
	outline.OutlineTransparency = 0.1
	outline.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	outline.Enabled = false
	outline.Parent = ball
	local outlineConnection = RunService.RenderStepped:Connect(function()
		local camera = workspace.CurrentCamera
		if camera then
			outline.Enabled = ball.Transparency < 1 and (camera.CFrame.Position - ball.Position).Magnitude > OUTLINE_DISTANCE
		end
	end)

	local connection: RBXScriptConnection? = nil

	local function stop()
		if connection then
			connection:Disconnect()
			connection = nil
		end
		trail.setEnabled(false)
	end

	-- The ball keeps a rolling orientation so its pattern turns as it travels.
	local spin = CFrame.identity
	local function placeAt(position: Vector3)
		local target = position + Vector3.new(0, LIFT, 0)
		local moved = target - ball.Position
		local flat = Vector3.new(moved.X, 0, moved.Z)
		if flat.Magnitude > 1e-4 and flat.Magnitude < 50 then
			-- Rolling without slipping: turn by distance / radius about the axis
			-- perpendicular to the motion.
			local axis = Vector3.yAxis:Cross(flat.Unit)
			spin = CFrame.fromAxisAngle(axis, flat.Magnitude / (BALL_DIAMETER / 2)) * spin
		end
		ball.CFrame = CFrame.new(target) * spin
	end

	local function setVisible(visible: boolean)
		CosmeticBuilder.setBallVisible(ball, visible) -- the pattern and its effects too
	end

	-- Where a holed ball lies: its side of the cup (from the drop), its depth.
	local restSide: Vector3? = nil
	local droppedAt: Vector3? = nil -- the cup this ball last dropped into (exact surface)
	local function restInCup(cupSurface: Vector3)
		local surface = cupSurface
		local known = droppedAt
		if known and Vector3.new(known.X - surface.X, 0, known.Z - surface.Z).Magnitude < 0.6 then
			surface = known -- the same cup it just dropped into: don't move it
		else
			restSide = nil
		end
		local side = restSide or Vector3.xAxis
		ball.CFrame = CFrame.new(surface + side * CupGeometry.restOffset() - Vector3.new(0, CupGeometry.restDepth(), 0)) * spin
		setVisible(true)
	end

	-- The holed ball rolls to the hole's edge (if it stopped short), falls in
	-- toward the far wall, rattles on the bottom and stays there.
	local function dropIntoCup(shot: any, samples: { { number } }, toWorld: (number, number, number) -> Vector3, onDone: (() -> ())?)
		local last = samples[#samples]
		local cupSurface = if shot.End then toWorld(shot.End.X, last[3], shot.End.Z) else ball.Position - Vector3.new(0, LIFT, 0)
		-- Horizontal velocity at the moment it was caught (studs/s).
		local velocity = Vector3.zero
		local before = samples[#samples - 1]
		if before and last[1] - before[1] > 1e-3 then
			local d = toWorld(last[2], last[3], last[4]) - toWorld(before[2], before[3], before[4])
			velocity = Vector3.new(d.X, 0, d.Z) / (last[1] - before[1])
		end
		local start = ball.Position - cupSurface
		local entry = Vector3.new(start.X, 0, start.Z)
		local rollFrom, rollTime = entry, 0
		local edge = CupGeometry.RADIUS - 0.05
		if entry.Magnitude > edge then
			-- Stopped short (a tap-in): roll up to the edge first.
			rollTime = math.min((entry.Magnitude - edge) / ROLL_IN_SPEED, 0.6)
			local inward = -entry.Unit
			velocity = inward * math.max(velocity.Magnitude, 1.5)
			entry = -inward * edge
		end
		local clock = 0.0
		local dropped = false
		connection = RunService.RenderStepped:Connect(function(dt: number)
			clock += dt
			if clock < rollTime then
				local p = rollFrom:Lerp(entry, clock / rollTime)
				placeAt(cupSurface + p)
				return
			end
			if not dropped then
				dropped = true
				playSound(ball, Assets.sound("CupDrop"), 0.9)
			end
			local d = CupGeometry.dropAt(clock - rollTime, entry.X, entry.Z, velocity.X, velocity.Z, LIFT)
			ball.CFrame = CFrame.new(cupSurface + Vector3.new(d.X, d.Y, d.Z)) * spin
			if d.Done then
				local side = Vector3.new(d.X, 0, d.Z)
				restSide = if side.Magnitude > 1e-4 then side.Unit else nil
				droppedAt = cupSurface
				stop() -- resting in the bottom of the cup
				if onDone then
					onDone()
				end
			end
		end)
	end

	local function play(shot: any, toWorld: (number, number, number) -> Vector3, onFrame: ((t: number, position: Vector3) -> ())?, onDone: (() -> ())?)
		stop()
		local samples = shot.Samples :: { { number } }
		local duration = TelemetryView.duration(shot)
		local clock = 0.0
		local x, y, z = TelemetryView.positionAt(samples, 0)
		placeAt(toWorld(x, y, z))
		trail.setEnabled(true)
		connection = RunService.RenderStepped:Connect(function(dt: number)
			clock += dt
			local px, py, pz = TelemetryView.positionAt(samples, clock)
			local position = toWorld(px, py, pz)
			placeAt(position)
			trail.step()
			if onFrame then
				onFrame(clock, position)
			end
			if clock >= duration then
				stop()
				if shot.PickedUp then
					setVisible(false) -- picked up (stroke limit): nothing drops
				elseif shot.Holed or shot.Outcome == "Holed" then
					dropIntoCup(shot, samples, toWorld, onDone)
					return
				end
				if onDone then
					onDone()
				end
			end
		end)
	end

	return {
		Part = ball,
		placeAt = placeAt,
		setVisible = setVisible,
		play = play,
		stop = stop,
		restInCup = restInCup,
		destroy = function()
			stop()
			outlineConnection:Disconnect()
			trail.destroy()
			ball:Destroy()
		end,
	}
end

-- A short particle pop at `position` (hole-drop effect / water splash).
function BallAnimator.burst(position: Vector3, color: Color3, amount: number?)
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Position = position + Vector3.new(0, 2, 0)
	anchor.Parent = workspace

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color)
	emitter.LightEmission = 0.6
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.4), NumberSequenceKeypoint.new(1, 0) })
	emitter.Lifetime = NumberRange.new(0.8, 1.6)
	emitter.Speed = NumberRange.new(14, 30)
	emitter.SpreadAngle = Vector2.new(70, 70)
	emitter.Acceleration = Vector3.new(0, -40, 0)
	emitter.Rate = 0
	emitter.Enabled = false
	emitter.Parent = anchor
	emitter:Emit(amount or 60)
	Debris:AddItem(anchor, 2.5)
end

return BallAnimator
