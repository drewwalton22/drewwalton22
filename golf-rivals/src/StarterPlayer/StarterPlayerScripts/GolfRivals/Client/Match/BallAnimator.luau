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
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.GolfRivals.Shared
local CosmeticsData = require(Shared.CosmeticsData)
local TelemetryView = require(Shared.TelemetryView)

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
	destroy: () -> (),
}

local BallAnimator = {}

local BALL_DIAMETER = 1.7 -- studs: bigger than a real ball so it is visible from the chase camera
local LIFT = BALL_DIAMETER / 2

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

	local connection: RBXScriptConnection? = nil

	local function stop()
		if connection then
			connection:Disconnect()
			connection = nil
		end
		trail.setEnabled(false)
	end

	local function placeAt(position: Vector3)
		ball.CFrame = CFrame.new(position + Vector3.new(0, LIFT, 0))
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
				if onDone then
					onDone()
				end
			end
		end)
	end

	return {
		Part = ball,
		placeAt = placeAt,
		setVisible = function(visible: boolean)
			ball.Transparency = if visible then 0 else 1
		end,
		play = play,
		stop = stop,
		destroy = function()
			stop()
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
