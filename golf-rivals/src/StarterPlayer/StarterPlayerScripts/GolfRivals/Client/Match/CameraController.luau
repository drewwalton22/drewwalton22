--!strict
--[[
	CameraController.luau  (Client/Match)

	Owns the camera during a match and applies the poses from CameraMath. Modes:

	  intro(tee, pin, seconds)      flyover from the green back to the tee box
	  address(ball, aimX, aimZ)     behind the ball, looking down the aim line
	  follow(getBall)               chase camera: tracks behind and alongside the
	                                ball every frame until the caller switches mode
	  release()                     give the camera back to Roblox

	It binds one render-step callback while active and sets the camera to Scriptable;
	`release()` restores the previous camera type so the lobby works normally.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CameraMath = require(ReplicatedStorage.GolfRivals.Shared.CameraMath)

local CameraController = {}

local BIND_NAME = "GolfRivalsMatchCamera"

type Mode = "None" | "Intro" | "Address" | "Follow"

local mode: Mode = "None"
local previousType: Enum.CameraType? = nil
local introTee: Vector3? = nil
local introPin: Vector3? = nil
local introStart = 0.0
local introSeconds = 4.0
local introDone: (() -> ())? = nil
local addressPose: CameraMath.Pose? = nil
local followState: CameraMath.FollowState? = nil
local getBall: (() -> Vector3?)? = nil

local function toVec(v: Vector3): CameraMath.Vec3
	return { X = v.X, Y = v.Y, Z = v.Z }
end

local function apply(pose: CameraMath.Pose, fov: number)
	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = fov
	camera.CFrame = CFrame.lookAt(Vector3.new(pose.Pos.X, pose.Pos.Y, pose.Pos.Z), Vector3.new(pose.Look.X, pose.Look.Y, pose.Look.Z))
end

local function step(dt: number)
	if mode == "Intro" and introTee and introPin then
		local alpha = (os.clock() - introStart) / introSeconds
		apply(CameraMath.introPose(toVec(introTee), toVec(introPin), alpha), 55)
		if alpha >= 1 then
			mode = "None"
			local done = introDone
			introDone = nil
			if done then
				done()
			end
		end
	elseif mode == "Address" and addressPose then
		apply(addressPose, 60)
	elseif mode == "Follow" and followState and getBall then
		local ball = getBall()
		if ball then
			local nextState, pose = CameraMath.follow(followState, toVec(ball), dt)
			followState = nextState
			apply(pose, 62)
		end
	end
end

local function ensureBound()
	if previousType == nil then
		local camera = workspace.CurrentCamera
		previousType = if camera then camera.CameraType else Enum.CameraType.Custom
		RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, step)
	end
end

function CameraController.intro(tee: Vector3, pin: Vector3, seconds: number, onDone: (() -> ())?)
	ensureBound()
	mode, introTee, introPin, introStart, introSeconds, introDone = "Intro", tee, pin, os.clock(), seconds, onDone
end

function CameraController.address(ball: Vector3, aimX: number, aimZ: number)
	ensureBound()
	mode = "Address"
	addressPose = CameraMath.addressPose(toVec(ball), aimX, aimZ)
end

function CameraController.follow(ball: Vector3, aimX: number, aimZ: number, provider: () -> Vector3?)
	ensureBound()
	mode = "Follow"
	followState = CameraMath.startFollow(toVec(ball), aimX, aimZ)
	getBall = provider
end

function CameraController.release()
	if previousType ~= nil then
		RunService:UnbindFromRenderStep(BIND_NAME)
		local camera = workspace.CurrentCamera
		if camera then
			camera.CameraType = previousType
			camera.FieldOfView = 70
		end
		previousType = nil
	end
	mode, introDone, followState, getBall, addressPose = "None", nil, nil, nil, nil
end

return CameraController
