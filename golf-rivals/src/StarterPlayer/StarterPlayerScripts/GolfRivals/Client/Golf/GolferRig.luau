--!strict
--[[
	GolferRig.luau  (Client/Golf)

	Puts a golfer on screen: stands them at the ball, puts a club in their hands,
	and plays the swing - with the club meeting the ball on the IMPACT FRAME - plus
	victory / defeat celebrations for the podium.

	WORKS ON ANY RIG
	  GolferRig.forCharacter(model)   a player's avatar (R15 or R6)
	  GolferRig.newBot(name, parent)  a blocky "Rival Bot" built locally (bots have
	                                  no avatar; every client builds its own copy)

	HOW THE ANIMATION IS DRIVEN
	  1. If Assets.Animations has a real id for the move, it is loaded on the rig's
	     Animator and played; the ball launches on the animation's "Impact" marker
	     (or at the fallback time if the marker never fires).
	  2. Otherwise (the default) SwingPose supplies a procedural pose every frame and
	     this module writes it into the rig's Motor6D.Transform values on
	     RunService.Stepped - after Roblox's own animations, so it wins - for the
	     spine, neck, both shoulders and the root (hops). Poses are defined in the
	     torso's frame and converted per joint as  Transform = R0^-1 * R * R0  (R0 =
	     the joint's C0 rotation), so the same pose is correct on R15, R6 and the bot.
	  Either way `onImpact` fires exactly once, at Config.Match.SwingLeadSeconds
	  into the swing - the moment the server's ball starts flying.

	ADDRESS
	  A right-handed golfer stands side-on: beside the ball, facing it, with the
	  target to their LEFT:  position = ball - right * gap,  facing +right.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Assets = require(Shared.Assets)
local SwingPose = require(Shared.SwingPose)

export type Rig = {
	Model: Model,
	IsBot: boolean,
	play: (kind: SwingPose.Kind, power: number?, onImpact: (() -> ())?) -> (),
	stop: () -> (),
	address: (ball: Vector3, aimDir: Vector3, isPutt: boolean) -> (),
	standAt: (cframe: CFrame) -> (),
	setClub: (color: Color3?, material: Enum.Material?, isPutter: boolean?) -> (),
	removeClub: () -> (),
	destroy: () -> (),
}

local GolferRig = {}

local ASSET_KIND: { [string]: string } = { Swing = "Swing", Putt = "Putt", Victory = "Victory", Defeat = "Defeat", Address = "Address", PuttAddress = "Address" }
local LOOPED: { [string]: boolean } = { Victory = true, Defeat = true, Address = true, PuttAddress = true }

type JointRef = { Motor: Motor6D, R0: CFrame, R0Inv: CFrame }

local function rotationOf(cf: CFrame): CFrame
	return cf - cf.Position
end

local function jointRef(motor: Motor6D?): JointRef?
	if motor == nil then
		return nil
	end
	local r0 = rotationOf(motor.C0)
	return { Motor = motor, R0 = r0, R0Inv = r0:Inverse() }
end

local function findMotor(model: Model, name: string): Motor6D?
	local found = model:FindFirstChild(name, true)
	return if found and found:IsA("Motor6D") then found else nil
end

-- Desired joint CFrame in the parent part's frame -> Motor6D.Transform.
local function drive(joint: JointRef?, desired: CFrame)
	if joint then
		joint.Motor.Transform = joint.R0Inv * desired * joint.R0
	end
end

local function spineRotation(pose: SwingPose.Pose): CFrame
	return CFrame.Angles(0, math.rad(pose.SpineYaw), 0) * CFrame.Angles(math.rad(-pose.SpineBend), 0, 0)
end

local function armRotation(pitch: number, roll: number): CFrame
	return CFrame.Angles(0, 0, math.rad(roll)) * CFrame.Angles(math.rad(pitch), 0, 0)
end

local function partNamed(model: Model, names: { string }): BasePart?
	for _, name in names do
		local part = model:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return part
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Core: wrap any model that has the expected joints
-- ---------------------------------------------------------------------------
local function wrap(model: Model, isBot: boolean): Rig
	local isR6 = model:FindFirstChild("Torso") ~= nil
	local spine = jointRef(if isR6 then findMotor(model, "RootJoint") else findMotor(model, "Waist"))
	local root = if isR6 then nil else jointRef(findMotor(model, "Root"))
	local neck = jointRef(findMotor(model, "Neck"))
	local rightShoulder = jointRef(findMotor(model, if isR6 then "Right Shoulder" else "RightShoulder"))
	local leftShoulder = jointRef(findMotor(model, if isR6 then "Left Shoulder" else "LeftShoulder"))
	-- R6 legs hang off the torso, so they are counter-rotated to stay planted.
	local rightHip = if isR6 then jointRef(findMotor(model, "Right Hip")) else nil
	local leftHip = if isR6 then jointRef(findMotor(model, "Left Hip")) else nil
	local rightHand = partNamed(model, { "RightHand", "Right Arm", "RightArm" })

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local controller = model:FindFirstChildOfClass("AnimationController")
	local animatorHost: Instance? = humanoid or controller
	local rootPart = partNamed(model, { "HumanoidRootPart" })

	local stepConnection: RBXScriptConnection? = nil
	local track: AnimationTrack? = nil
	local club: Model? = nil
	local generation = 0 -- invalidates timers from a previous play()

	local function applyPose(pose: SwingPose.Pose)
		local spineCf = spineRotation(pose)
		if isR6 then
			drive(spine, CFrame.new(0, pose.Hop, 0) * spineCf)
			local counter = spineCf:Inverse()
			drive(rightHip, counter)
			drive(leftHip, counter)
		else
			drive(spine, spineCf)
			drive(root, CFrame.new(0, pose.Hop, 0))
		end
		drive(neck, CFrame.Angles(math.rad(pose.HeadPitch), 0, 0))
		drive(rightShoulder, armRotation(pose.RArmPitch, pose.RArmRoll))
		drive(leftShoulder, armRotation(pose.LArmPitch, -pose.LArmRoll))
	end

	local function clearPose()
		for _, joint in { spine, root, neck, rightShoulder, leftShoulder, rightHip, leftHip } do
			if joint then
				joint.Motor.Transform = CFrame.identity
			end
		end
	end

	local function stop()
		generation += 1
		if stepConnection then
			stepConnection:Disconnect()
			stepConnection = nil
		end
		if track then
			track:Stop(0.15)
			track = nil
		end
		clearPose()
	end

	-- Plays an uploaded animation; returns false when none is configured/loadable.
	local function playAsset(kind: SwingPose.Kind, onImpact: (() -> ())?): boolean
		local id = Assets.animation(ASSET_KIND[kind] or "")
		if id == nil or animatorHost == nil then
			return false
		end
		local host = animatorHost :: Instance
		local existing = host:FindFirstChildOfClass("Animator")
		local animator: Animator = if existing then existing else Instance.new("Animator")
		animator.Parent = host
		local animation = Instance.new("Animation")
		animation.AnimationId = id :: string
		local ok, loaded = pcall(function(): any
			return animator:LoadAnimation(animation)
		end)
		if not ok or typeof(loaded) ~= "Instance" then
			return false
		end
		local newTrack = loaded :: AnimationTrack
		newTrack.Looped = LOOPED[kind] == true
		track = newTrack
		local fired = false
		local myGeneration = generation
		local function fire()
			if not fired and myGeneration == generation then
				fired = true
				if onImpact then
					onImpact()
				end
			end
		end
		newTrack:GetMarkerReachedSignal("Impact"):Connect(fire)
		local impact = SwingPose.impactTime(kind)
		if impact and onImpact then
			task.delay(impact + 0.35, fire) -- no marker on the animation: don't stall the shot
		end
		newTrack:Play(0.1)
		return true
	end

	local function play(kind: SwingPose.Kind, power: number?, onImpact: (() -> ())?)
		stop()
		if kind == "Idle" then
			return
		end
		if playAsset(kind, onImpact) then
			return
		end
		-- Procedural fallback.
		local start = os.clock()
		local impact = SwingPose.impactTime(kind)
		local duration = SwingPose.duration(kind, power)
		local fired = impact == nil
		stepConnection = RunService.Stepped:Connect(function()
			local t = os.clock() - start
			applyPose(SwingPose.sample(kind, t, power))
			if not fired and impact and t >= impact then
				fired = true
				if onImpact then
					task.spawn(onImpact)
				end
			end
			if not LOOPED[kind] and t >= duration then
				-- One-shot finished: let the rig relax to its normal idle.
				if stepConnection then
					stepConnection:Disconnect()
					stepConnection = nil
				end
				clearPose()
			end
		end)
	end

	local function standAt(cframe: CFrame)
		-- Height of the root above the ground: R15 uses HipHeight, R6 is a fixed 3,
		-- the bot's legs reach 2.5 studs below its root.
		local height = if isBot then 2.5 else 3
		if humanoid and rootPart and humanoid.RigType == Enum.HumanoidRigType.R15 then
			height = humanoid.HipHeight + rootPart.Size.Y / 2
		end
		model:PivotTo(cframe + Vector3.new(0, height, 0))
	end

	-- Stand side-on to the ball, target on the golfer's left (see header).
	local function address(ball: Vector3, aimDir: Vector3, isPutt: boolean)
		local forward = Vector3.new(aimDir.X, 0, aimDir.Z)
		if forward.Magnitude < 1e-6 then
			forward = Vector3.new(1, 0, 0)
		end
		forward = forward.Unit
		local right = Vector3.new(-forward.Z, 0, forward.X)
		local ground = Vector3.new(ball.X, ball.Y, ball.Z)
		local gap = if isPutt then 2.4 else 3.0
		local position = ground - right * gap - forward * 0.4
		standAt(CFrame.lookAt(position, position + right))
		play(if isPutt then "PuttAddress" else "Address", nil, nil)
	end

	local function removeClub()
		if club then
			club:Destroy()
			club = nil
		end
	end

	-- A club in the right hand: shaft down and slightly forward, coloured by the
	-- equipped skin. Putters get a short shaft and a flat head.
	local function setClub(color: Color3?, material: Enum.Material?, isPutter: boolean?)
		removeClub()
		local hand = rightHand
		if hand == nil then
			return
		end
		local length = if isPutter then 3.0 else 4.2
		local newClub = Instance.new("Model")
		newClub.Name = "GolfClub"
		local shaft = Instance.new("Part")
		shaft.Name = "Shaft"
		shaft.Shape = Enum.PartType.Cylinder
		shaft.Size = Vector3.new(length, 0.16, 0.16) -- cylinder axis = X
		shaft.Color = Color3.fromRGB(205, 210, 220)
		shaft.Material = Enum.Material.Metal
		local head = Instance.new("Part")
		head.Name = "Head"
		head.Size = if isPutter then Vector3.new(0.3, 0.35, 0.9) else Vector3.new(0.45, 0.42, 0.7)
		head.Color = color or Color3.fromRGB(30, 30, 36)
		head.Material = material or Enum.Material.Metal
		for _, part in { shaft, head } do
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Massless = true
			part.Anchored = false
			part.Parent = newClub
		end
		-- Grip at the bottom of the hand; the shaft runs down the hand's -Y axis,
		-- tilted forward (-Z) so the head reaches the ball in front of the golfer.
		local gripOffset = CFrame.new(0, -hand.Size.Y / 2 + 0.1, 0) * CFrame.Angles(math.rad(25), 0, 0)
		local shaftCf = gripOffset * CFrame.new(0, -length / 2, 0) * CFrame.Angles(0, 0, math.rad(90))
		shaft.CFrame = hand.CFrame * shaftCf
		local headCf = gripOffset * CFrame.new(0, -length, -0.18)
		head.CFrame = hand.CFrame * headCf
		local function attach(part: BasePart, offset: CFrame)
			local weld = Instance.new("Weld")
			weld.Part0 = hand
			weld.Part1 = part
			weld.C0 = offset
			weld.Parent = part
		end
		attach(shaft, shaftCf)
		attach(head, headCf)
		newClub.Parent = model
		club = newClub
	end

	return {
		Model = model,
		IsBot = isBot,
		play = play,
		stop = stop,
		address = address,
		standAt = standAt,
		setClub = setClub,
		removeClub = removeClub,
		destroy = function()
			stop()
			removeClub()
			if isBot then
				model:Destroy()
			end
		end,
	}
end

-- A player's own avatar. Returns nil if it has no recognisable joints yet.
function GolferRig.forCharacter(character: Model): Rig?
	if character:FindFirstChild("HumanoidRootPart") == nil then
		return nil
	end
	return wrap(character, false)
end

-- ---------------------------------------------------------------------------
-- The bot: a small blocky rig with R15-style joint names and identity C0
-- rotations (so poses map 1:1). Built locally; anchored at the root.
-- ---------------------------------------------------------------------------
function GolferRig.newBot(name: string, parent: Instance, shirt: Color3?): Rig
	local model = Instance.new("Model")
	model.Name = name

	local function block(partName: string, size: Vector3, color: Color3, material: Enum.Material?): Part
		local part = Instance.new("Part")
		part.Name = partName
		part.Size = size
		part.Color = color
		part.Material = material or Enum.Material.SmoothPlastic
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Anchored = false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = model
		return part
	end

	local skin = Color3.fromRGB(234, 184, 146)
	local shirtColor = shirt or Color3.fromRGB(40, 70, 160)
	local pants = Color3.fromRGB(235, 235, 240)

	local rootPart = block("HumanoidRootPart", Vector3.new(2, 2, 1), Color3.new(1, 1, 1))
	rootPart.Transparency = 1
	rootPart.Anchored = true
	local lower = block("LowerTorso", Vector3.new(2, 0.6, 1), pants)
	local upper = block("UpperTorso", Vector3.new(2, 1.6, 1), shirtColor)
	local head = block("Head", Vector3.new(1.2, 1.2, 1.2), skin)
	local cap = block("Cap", Vector3.new(1.3, 0.35, 1.3), shirtColor)
	local visor = block("Visor", Vector3.new(1.1, 0.12, 0.6), shirtColor)
	local rightArm = block("RightArm", Vector3.new(0.8, 1.9, 0.8), skin)
	local leftArm = block("LeftArm", Vector3.new(0.8, 1.9, 0.8), skin)
	local rightHand = block("RightHand", Vector3.new(0.7, 0.4, 0.7), Color3.fromRGB(245, 245, 245))
	local rightLeg = block("RightLeg", Vector3.new(0.9, 2, 0.9), pants)
	local leftLeg = block("LeftLeg", Vector3.new(0.9, 2, 0.9), pants)
	model.PrimaryPart = rootPart

	local function motor(motorName: string, part0: BasePart, part1: BasePart, c0: Vector3, c1: Vector3)
		local m = Instance.new("Motor6D")
		m.Name = motorName
		m.Part0 = part0
		m.Part1 = part1
		m.C0 = CFrame.new(c0)
		m.C1 = CFrame.new(c1)
		m.Parent = part1
	end
	local function weld(part0: BasePart, part1: BasePart, offset: Vector3)
		local w = Instance.new("Weld")
		w.Part0 = part0
		w.Part1 = part1
		w.C0 = CFrame.new(offset)
		w.Parent = part1
	end
	-- Root (hips) -> spine -> neck / shoulders; legs hang from the hips.
	motor("Root", rootPart, lower, Vector3.new(0, -0.2, 0), Vector3.zero)
	motor("Waist", lower, upper, Vector3.new(0, 0.3, 0), Vector3.new(0, -0.8, 0))
	motor("Neck", upper, head, Vector3.new(0, 0.8, 0), Vector3.new(0, -0.6, 0))
	motor("RightShoulder", upper, rightArm, Vector3.new(1.4, 0.75, 0), Vector3.new(0, 0.8, 0))
	motor("LeftShoulder", upper, leftArm, Vector3.new(-1.4, 0.75, 0), Vector3.new(0, 0.8, 0))
	motor("RightHip", lower, rightLeg, Vector3.new(0.5, -0.3, 0), Vector3.new(0, 1, 0))
	motor("LeftHip", lower, leftLeg, Vector3.new(-0.5, -0.3, 0), Vector3.new(0, 1, 0))
	weld(rightArm, rightHand, Vector3.new(0, -1.1, 0))
	weld(head, cap, Vector3.new(0, 0.62, 0))
	weld(head, visor, Vector3.new(0, 0.5, -0.8))

	-- Face: two eyes so the bot reads as a character from the camera.
	for _, x in { -0.25, 0.25 } do
		local eye = block("Eye", Vector3.new(0.16, 0.22, 0.05), Color3.fromRGB(20, 20, 26))
		weld(head, eye, Vector3.new(x, 0.08, -0.61))
	end

	-- Name tag.
	local tag = Instance.new("BillboardGui")
	tag.Size = UDim2.fromOffset(160, 30)
	tag.StudsOffset = Vector3.new(0, 2.2, 0)
	tag.AlwaysOnTop = true
	tag.Adornee = head
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = name
	label.Font = Enum.Font.BuilderSansExtraBold
	label.TextSize = 18
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.4
	label.Parent = tag
	tag.Parent = head

	model.Parent = parent
	return wrap(model, true)
end

return GolferRig
