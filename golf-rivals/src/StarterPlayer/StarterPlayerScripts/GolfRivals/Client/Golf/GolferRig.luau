--!strict
--[[
	GolferRig.luau  (Client/Golf)

	Puts a golfer on screen: stands them at the ball, puts a club in their hands
	(clubhead resting ON the ground behind the ball), and plays the swing - with the
	club meeting the ball on the IMPACT FRAME - plus victory / defeat celebrations.

	WORKS ON ANY RIG
	  GolferRig.forCharacter(model)   a player's avatar (R15 or R6)
	  GolferRig.newBot(name, parent)  a blocky "Rival Bot" built locally

	WHY THE PLAYER USED TO STAND STILL (diagnosis)
	  The procedural pose was written into joints found with
	  FindFirstChild(name):IsA("Motor6D"). Avatars with Roblox's "Avatar Joint
	  Upgrade" have AnimationConstraint joints instead of Motor6Ds, so no joint was
	  found and nothing moved (the bot, built with Motor6Ds, did swing). On top of
	  that the default Animate script keeps playing idle tracks that write the same
	  joints every frame. Now:
	    * joints are found by the BODY PART THEY DRIVE (UpperTorso, Head, Right Arm
	      ...) and both Motor6D and AnimationConstraint are driven (same Transform
	      maths; an AnimationConstraint's Attachment0 plays the role of C0)
	    * while golfing, the local player's Animate script is disabled and every
	      default track is stopped; it is restored the moment the golfer is released
	    * procedural poses are written on RunService.PreSimulation - AFTER the
	      Animator's step in each frame - so nothing overwrites them

	HOW THE ANIMATION IS DRIVEN
	  1. If Assets.Animations has an uploaded id for the move AND this rig type
	     (R15 / R6), it plays as an AnimationTrack at Action4 priority; the ball
	     launches on its "Impact" marker (or the fallback time).
	  2. Otherwise SwingPose supplies a procedural pose every frame (spine, neck,
	     shoulders, root hop; R6 hips counter-rotate). Poses are defined in the
	     torso's frame and converted per joint as  Transform = R0^-1 * R * R0, so the
	     same pose is right on R15, R6 and the bot.
	  Either way `onImpact` fires exactly once, Config.Match.SwingLeadSeconds into
	  the swing - when the server's ball starts flying.

	ADDRESS (club on the ground)
	  A right-handed golfer stands side-on with the target to their LEFT, feet on the
	  real ground (a raycast, so slopes work). Once the address pose is on, the club
	  is aimed from the hands at a point on the ground just behind the ball, and the
	  golfer slides toward / away from the ball until the sole touches it exactly
	  (ClubSeat); a club too short for a tall avatar is scaled up.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Assets = require(Shared.Assets)
local ClubSeat = require(Shared.ClubSeat)
local CosmeticsData = require(Shared.CosmeticsData)
local SwingPose = require(Shared.SwingPose)

local CosmeticBuilder = require(script.Parent.CosmeticBuilder)

export type Rig = {
	Model: Model,
	IsBot: boolean,
	RigType: string, -- "R15" | "R6" | "Bot"
	-- animationId: an equipped Swing / Emote animation (CosmeticsData); nil = the
	-- Assets default for the move and rig type, then the procedural pose.
	play: (kind: SwingPose.Kind, power: number?, onImpact: (() -> ())?, animationId: string?) -> (),
	stop: () -> (),
	address: (ball: Vector3, aimDir: Vector3, isPutt: boolean) -> (),
	standAt: (cframe: CFrame) -> (),
	setClub: (look: CosmeticsData.ClubLook, isPutter: boolean?) -> (),
	removeClub: () -> (),
	destroy: () -> (),
}

local GolferRig = {}

local ASSET_KIND: { [string]: string } = { Swing = "Swing", Putt = "Putt", Victory = "Victory", Defeat = "Defeat", Address = "Address", PuttAddress = "PuttAddress" }
local LOOPED: { [string]: boolean } = { Victory = true, Defeat = true, Address = true, PuttAddress = true }
local BALL_CLEARANCE = 0.55 -- studs between the ball's centre and the clubhead's sole point

-- A driveable joint: a Motor6D or an AnimationConstraint (Avatar Joint Upgrade).
type JointRef = { Instance: Instance, R0: CFrame, R0Inv: CFrame }

local function rotationOf(cf: CFrame): CFrame
	return cf - cf.Position
end

-- The joint that moves the part named one of `childNames` (Part1 / Attachment1's part).
local function jointFor(model: Model, childNames: { string }): { JointRef }
	local wanted: { [string]: boolean } = {}
	for _, name in childNames do
		wanted[name] = true
	end
	local found: { JointRef } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") then
			local child = d.Part1
			if child and wanted[child.Name] then
				local r0 = rotationOf(d.C0)
				local ref: JointRef = { Instance = d :: Instance, R0 = r0, R0Inv = r0:Inverse() }
				table.insert(found, ref)
			end
		elseif d:IsA("AnimationConstraint") then
			local a0, a1 = d.Attachment0, d.Attachment1
			local child = if a1 then a1.Parent else nil
			if a0 and child and wanted[child.Name] then
				local r0 = rotationOf(a0.CFrame)
				local ref: JointRef = { Instance = d :: Instance, R0 = r0, R0Inv = r0:Inverse() }
				table.insert(found, ref)
			end
		end
	end
	return found
end

local function setTransform(joint: JointRef, transform: CFrame)
	local instance = joint.Instance
	if instance:IsA("Motor6D") then
		instance.Transform = transform
	elseif instance:IsA("AnimationConstraint") then
		instance.Transform = transform
	end
end

-- Desired joint CFrame in the parent part's frame -> Transform, on every joint found.
local function drive(joints: { JointRef }, desired: CFrame)
	for _, joint in joints do
		setTransform(joint, joint.R0Inv * desired * joint.R0)
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

local function vec(v: Vector3): ClubSeat.Vec
	return { X = v.X, Y = v.Y, Z = v.Z }
end

-- The ground (terrain / course parts) under `point`, skipping characters and
-- anything that isn't solid course geometry. Returns `point` itself if nothing.
local function groundBelow(point: Vector3, ignore: { Instance }): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude = table.clone(ignore)
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end
	local camera = workspace.CurrentCamera
	if camera then
		table.insert(exclude, camera)
	end
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = false
	local origin = point + Vector3.new(0, 30, 0)
	for _ = 1, 4 do
		local hit = workspace:Raycast(origin, Vector3.new(0, -80, 0), params)
		if hit == nil then
			return point
		end
		local model = hit.Instance:FindFirstAncestorOfClass("Model")
		if model and model:FindFirstChildOfClass("Humanoid") then
			table.insert(exclude, model) -- a golfer (bot) in the way: look past it
			params.FilterDescendantsInstances = exclude
		else
			return hit.Position
		end
	end
	return point
end

-- ---------------------------------------------------------------------------
-- Core: wrap any model that has the expected joints
-- ---------------------------------------------------------------------------
local function wrap(model: Model, isBot: boolean): Rig
	local isR6 = model:FindFirstChild("Torso") ~= nil
	local rigType = if isBot then "Bot" elseif isR6 then "R6" else "R15"
	local spine = jointFor(model, if isR6 then { "Torso" } else { "UpperTorso" })
	local root = if isR6 then {} else jointFor(model, { "LowerTorso" })
	local neck = jointFor(model, { "Head" })
	local rightShoulder = jointFor(model, { "RightUpperArm", "Right Arm", "RightArm" })
	local leftShoulder = jointFor(model, { "LeftUpperArm", "Left Arm", "LeftArm" })
	-- R6 legs hang off the torso, so they are counter-rotated to stay planted.
	local rightHip = if isR6 then jointFor(model, { "Right Leg" }) else {}
	local leftHip = if isR6 then jointFor(model, { "Left Leg" }) else {}
	local rightHand = partNamed(model, { "RightHand", "Right Arm", "RightArm" })

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local controller = model:FindFirstChildOfClass("AnimationController")
	local animatorHost: Instance? = humanoid or controller
	local rootPart = partNamed(model, { "HumanoidRootPart" })

	local stepConnection: RBXScriptConnection? = nil
	local track: AnimationTrack? = nil
	local club: Model? = nil
	local clubWeld: WeldConstraint? = nil
	local generation = 0 -- invalidates timers from a previous play()
	local seatGeneration = 0
	local pausedAnimate: Instance? = nil
	local addressKey = "" -- the last address(): repeated identical calls are no-ops

	local function animator(): Animator?
		local host = animatorHost
		if host == nil then
			return nil
		end
		local existing = host:FindFirstChildOfClass("Animator")
		if existing then
			return existing
		end
		local created = Instance.new("Animator")
		created.Parent = host
		return created
	end

	-- Stop Roblox's default Animate tracks (idle / walk) so they can't fight the
	-- golf pose; disable the local player's Animate script while golfing.
	local function pauseDefault()
		local animate = model:FindFirstChild("Animate")
		if pausedAnimate == nil and animate and animate:IsA("BaseScript") and model == Players.LocalPlayer.Character then
			if animate.Enabled then
				animate.Enabled = false
				pausedAnimate = animate
			end
		end
		local a = if animatorHost then (animatorHost :: Instance):FindFirstChildOfClass("Animator") else nil
		if a then
			for _, playing in a:GetPlayingAnimationTracks() do
				if playing ~= track then
					playing:Stop(0.1)
				end
			end
		end
	end

	local function resumeDefault()
		local animate = pausedAnimate
		pausedAnimate = nil
		if animate and animate.Parent and animate:IsA("BaseScript") then
			animate.Enabled = true
		end
	end

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
		for _, group in { spine, root, neck, rightShoulder, leftShoulder, rightHip, leftHip } do
			for _, joint in group do
				setTransform(joint, CFrame.identity)
			end
		end
	end

	-- Stop the current move without handing the rig back to Roblox's Animate.
	local function halt()
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

	-- Stop and release: the avatar idles normally again.
	local function stop()
		halt()
		seatGeneration += 1
		addressKey = ""
		resumeDefault()
	end

	-- The procedural move (SwingPose), written after the Animator's step every frame.
	local function runProcedural(kind: SwingPose.Kind, power: number?, onImpact: (() -> ())?)
		local start = os.clock()
		local impact = SwingPose.impactTime(kind)
		local duration = SwingPose.duration(kind, power)
		local fired = impact == nil
		stepConnection = RunService.PreSimulation:Connect(function()
			local t = os.clock() - start
			applyPose(SwingPose.sample(kind, t, power))
			if not fired and impact and t >= impact then
				fired = true
				if onImpact then
					task.spawn(onImpact)
				end
			end
			if not LOOPED[kind] and t >= duration then
				-- One-shot finished: hold the final (idle) pose until the next move.
				if stepConnection then
					stepConnection:Disconnect()
					stepConnection = nil
				end
				clearPose()
			end
		end)
	end

	-- Plays an uploaded animation; returns false when none is configured/loadable.
	local function playAsset(kind: SwingPose.Kind, onImpact: (() -> ())?, override: string?): boolean
		if isBot then
			return false -- the bot's body parts don't match R15 / R6 animations
		end
		local id = if override and Assets.isSet(override) then override else Assets.animation(ASSET_KIND[kind] or "", rigType)
		local a = animator()
		if id == nil or a == nil then
			return false
		end
		local animation = Instance.new("Animation")
		animation.AnimationId = id :: string
		local ok, loaded = pcall(function(): any
			return (a :: Animator):LoadAnimation(animation)
		end)
		if not ok or typeof(loaded) ~= "Instance" then
			return false
		end
		local newTrack = loaded :: AnimationTrack
		newTrack.Looped = LOOPED[kind] == true
		newTrack.Priority = Enum.AnimationPriority.Action4
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
		-- An asset that fails to load (moderated, wrong rig, not owned) never
		-- reaches a length: after a short wait, play the procedural move from the
		-- start instead (it fires the impact itself if the shot hasn't gone yet).
		task.spawn(function()
			local waited = 0
			while waited < 0.6 do
				task.wait(0.1)
				waited += 0.1
				if myGeneration ~= generation or track ~= newTrack or newTrack.Length > 0 then
					return -- replaced, stopped, or loaded fine
				end
			end
			newTrack:Stop(0)
			track = nil
			generation += 1 -- cancels the marker / timer impact of the failed track
			runProcedural(kind, nil, if fired then nil else function()
				fired = true
				if onImpact then
					onImpact()
				end
			end)
		end)
		return true
	end

	local function play(kind: SwingPose.Kind, power: number?, onImpact: (() -> ())?, animationId: string?)
		if kind ~= "Address" and kind ~= "PuttAddress" then
			addressKey = "" -- any other move ends the address
		end
		halt()
		if kind == "Idle" then
			resumeDefault()
			return
		end
		pauseDefault()
		if playAsset(kind, onImpact, animationId) then
			return
		end
		runProcedural(kind, power, onImpact)
	end

	-- Height of the root above the feet.
	local function rootHeight(): number
		if isBot then
			return 2.5
		end
		if humanoid and rootPart and humanoid.RigType == Enum.HumanoidRigType.R15 then
			return humanoid.HipHeight + rootPart.Size.Y / 2
		end
		return 3
	end

	local function standAt(cframe: CFrame)
		model:PivotTo(cframe + Vector3.new(0, rootHeight(), 0))
	end

	-- The club's sole point (an Attachment "Sole" made by CosmeticBuilder).
	local function soleOf(c: Model): Attachment?
		local sole = c:FindFirstChild("Sole", true)
		return if sole and sole:IsA("Attachment") then sole else nil
	end

	-- Aim the club from the hands to the ground behind the ball and slide the
	-- golfer so the sole touches it (see ClubSeat).
	local function seatClub(ball: Vector3, forward: Vector3, toward: Vector3)
		local c, hand = club, rightHand
		local grip = if c then c.PrimaryPart else nil
		local sole = if c then soleOf(c) else nil
		if c == nil or hand == nil or grip == nil or sole == nil then
			return
		end
		local gripPos = grip.Position
		local length = (sole.WorldPosition - gripPos).Magnitude
		local target = groundBelow(ball - forward * BALL_CLEARANCE, { model, c })
		local seat = ClubSeat.solve(vec(gripPos), vec(target), vec(toward), length)
		if math.abs(seat.Shift) > 0.01 then
			model:PivotTo(model:GetPivot() + toward * seat.Shift)
		end
		local newGrip = gripPos + toward * seat.Shift
		local weld = clubWeld
		if weld then
			weld:Destroy() -- free the club from the hand before resizing / re-posing it
			clubWeld = nil
		end
		if seat.Scale > 1.001 then
			c:ScaleTo(c:GetScale() * seat.Scale)
		end
		-- Club frame: +Y from the sole up to the grip, +X along the target line.
		local up = (newGrip - target)
		up = if up.Magnitude > 1e-4 then up.Unit else Vector3.yAxis
		local xAxis = forward - up * forward:Dot(up)
		xAxis = if xAxis.Magnitude > 1e-4 then xAxis.Unit else toward:Cross(up).Unit
		-- Re-pivot so the grip sits at the hand and the sole on the target point.
		local frame = CFrame.fromMatrix(newGrip, xAxis, up)
		local soleLocal = grip.CFrame:PointToObjectSpace(sole.WorldPosition)
		local soleAfter = frame:PointToWorldSpace(soleLocal)
		-- Rotate about the grip so the sole lands exactly on the target.
		local wantDir = (target - newGrip).Unit
		local haveDir = (soleAfter - newGrip).Unit
		local axis = haveDir:Cross(wantDir)
		if axis.Magnitude > 1e-5 then
			local angle = math.acos(math.clamp(haveDir:Dot(wantDir), -1, 1))
			frame = CFrame.new(newGrip) * CFrame.fromAxisAngle(axis.Unit, angle) * (frame - frame.Position)
		end
		c:PivotTo(frame)
		local newWeld = Instance.new("WeldConstraint")
		newWeld.Part0 = hand
		newWeld.Part1 = grip
		newWeld.Parent = grip
		clubWeld = newWeld
	end

	-- Stand side-on to the ball, target on the golfer's left (see header).
	local function address(ball: Vector3, aimDir: Vector3, isPutt: boolean)
		local forward = Vector3.new(aimDir.X, 0, aimDir.Z)
		if forward.Magnitude < 1e-6 then
			forward = Vector3.new(1, 0, 0)
		end
		forward = forward.Unit
		-- Snapshots arrive several times a second while aiming: don't re-place a
		-- golfer who is already addressing this ball the same way.
		local key = string.format("%.2f|%.2f|%.2f|%.3f|%.3f|%s|%s", ball.X, ball.Y, ball.Z, forward.X, forward.Z, tostring(isPutt), if club then club.Name .. tostring(club:GetAttribute("Look")) else "")
		if key == addressKey and (stepConnection ~= nil or track ~= nil) then
			return
		end
		addressKey = key
		local right = Vector3.new(-forward.Z, 0, forward.X)
		local gap = if isPutt then 2.4 else 3.0
		local spot = ball - right * gap - forward * 0.4
		local feet = groundBelow(spot, { model })
		standAt(CFrame.lookAt(feet, feet + right))
		play(if isPutt then "PuttAddress" else "Address", nil, nil)
		-- Seat the club once the address pose has been applied (a few frames).
		seatGeneration += 1
		local mine = seatGeneration
		task.delay(0.12, function()
			if mine == seatGeneration then
				seatClub(ball, forward, right)
			end
		end)
	end

	local function removeClub()
		if club then
			club:Destroy()
			club = nil
			clubWeld = nil
		end
	end

	-- A club in the right hand (CosmeticBuilder: template / mesh / procedural),
	-- its grip at the bottom of the hand; address() then aims it at the ground.
	local function setClub(look: CosmeticsData.ClubLook, isPutter: boolean?)
		-- Same club already in hand: keep it (and its seat on the ground).
		local lookKey = `{look.Shape}|{look.HeadMeshId}|{table.concat(look.TemplateNames, ",")}|{look.HeadColor[1]},{look.HeadColor[2]},{look.HeadColor[3]}`
		if club and club.Parent and club:GetAttribute("Look") == lookKey then
			return
		end
		addressKey = ""
		removeClub()
		local hand = rightHand
		if hand == nil then
			return
		end
		local newClub = CosmeticBuilder.club(look, isPutter == true)
		newClub.Name = "GolfClub"
		newClub:SetAttribute("Look", lookKey)
		local gripOffset = CFrame.new(0, -hand.Size.Y / 2 + 0.1, 0) * CFrame.Angles(math.rad(25), 0, 0)
		newClub:PivotTo(hand.CFrame * gripOffset)
		local grip = newClub.PrimaryPart
		if grip then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = hand
			weld.Part1 = grip
			weld.Parent = grip
			clubWeld = weld
		end
		newClub.Parent = model
		club = newClub
	end

	return {
		Model = model,
		IsBot = isBot,
		RigType = rigType,
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
