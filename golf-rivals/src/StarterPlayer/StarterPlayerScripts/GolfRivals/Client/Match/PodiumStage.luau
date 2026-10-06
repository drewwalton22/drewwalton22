--!strict
--[[
	PodiumStage.luau  (Client/Match)

	The post-game showcase. When a match finishes, each client builds a small stage
	(above its own arena, so it never overlaps a course) and stands the golfers on
	it, as PodiumView decides:

	  winner  top step, gold, playing the VICTORY animation, with confetti
	  loser   lower step, silver, playing the DEFEAT animation
	  draw    two equal blue steps, both at ease

	AVATARS are real: each human's current character is cloned (made Archivable for
	the copy, scripts stripped, anchored) so the podium shows their actual outfit;
	bots get the GolferRig bot. If a character can't be copied (player left, still
	loading), a bot-style stand-in with their name is used instead.

	Animations come from GolferRig (uploaded Victory/Defeat assets when set,
	procedural SwingPose otherwise). The camera framing is returned so the caller
	can point CameraController at it while MatchHud docks the scoreboard on the left.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local PodiumView = require(Shared.PodiumView)

local GolferRig = require(script.Parent.Parent.Golf.GolferRig)

export type Stage = {
	CameraPosition: Vector3,
	CameraLook: Vector3,
	destroy: () -> (),
}

local PodiumStage = {}

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function part(name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- A copy of a player's character for display (nil if it can't be copied).
local function cloneCharacter(userId: number): Model?
	local player = Players:GetPlayerByUserId(userId)
	local character = if player then player.Character else nil
	if character == nil then
		return nil
	end
	local wasArchivable = character.Archivable
	character.Archivable = true
	local ok, copy = pcall(function(): any
		return character:Clone()
	end)
	character.Archivable = wasArchivable
	if not ok or typeof(copy) ~= "Instance" then
		return nil
	end
	local model = copy :: Model
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BaseScript") or descendant:IsA("ForceField") or descendant.Name == "GolfClub" then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Anchored = false
		end
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.PlatformStand = true
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.Anchored = true
	end
	return model
end

local function nameTag(model: Model, text: string, color: Color3)
	local head = model:FindFirstChild("Head")
	if head == nil or not head:IsA("BasePart") then
		return
	end
	local tag = Instance.new("BillboardGui")
	tag.Size = UDim2.fromOffset(200, 36)
	tag.StudsOffset = Vector3.new(0, 2.6, 0)
	tag.AlwaysOnTop = true
	tag.Adornee = head
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.Font = Enum.Font.BuilderSansExtraBold
	label.TextSize = 20
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.3
	label.Parent = tag
	tag.Parent = head
end

local function confetti(at: Vector3, parent: Instance)
	local anchor = part("Confetti", Vector3.new(1, 1, 1), CFrame.new(at), Color3.new(1, 1, 1), Enum.Material.SmoothPlastic, parent)
	anchor.Transparency = 1
	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 210, 60)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(80, 200, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 90, 160)),
	})
	emitter.Size = NumberSequence.new(0.35)
	emitter.Lifetime = NumberRange.new(2.5, 4)
	emitter.Speed = NumberRange.new(10, 22)
	emitter.SpreadAngle = Vector2.new(40, 40)
	emitter.Acceleration = Vector3.new(0, -14, 0)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-200, 200)
	emitter.Rate = 30
	emitter.Parent = anchor
	emitter:Emit(120)
	task.delay(6, function()
		emitter.Enabled = false
	end)
	Debris:AddItem(anchor, 14)
end

-- Builds the stage at `origin` (golfers face -Z, toward the camera).
-- `emotes`: player id -> their equipped victory emote AnimationId (CosmeticsData).
function PodiumStage.build(podium: PodiumView.Podium, origin: Vector3, emotes: { [string]: string }?): Stage
	local folder = Instance.new("Folder")
	folder.Name = "Podium"
	folder.Parent = workspace

	-- Floor, backdrop and lights.
	part("Floor", Vector3.new(70, 1, 50), CFrame.new(origin + Vector3.new(0, -0.5, 4)), Color3.fromRGB(20, 26, 44), Enum.Material.SmoothPlastic, folder)
	part("FloorGlow", Vector3.new(30, 0.2, 14), CFrame.new(origin + Vector3.new(0, 0.05, 0)), Color3.fromRGB(60, 90, 160), Enum.Material.Neon, folder).Transparency = 0.6
	local wall = part("Backdrop", Vector3.new(70, 34, 1), CFrame.new(origin + Vector3.new(0, 16, 10)), Color3.fromRGB(14, 20, 38), Enum.Material.SmoothPlastic, folder)
	local light = Instance.new("SurfaceLight")
	light.Face = Enum.NormalId.Front
	light.Range = 30
	light.Brightness = 2
	light.Color = Color3.fromRGB(255, 236, 200)
	light.Parent = wall
	local spot = part("Spot", Vector3.new(1, 1, 1), CFrame.new(origin + Vector3.new(0, 18, -12)), Color3.new(1, 1, 1), Enum.Material.SmoothPlastic, folder)
	spot.Transparency = 1
	local spotlight = Instance.new("PointLight")
	spotlight.Range = 40
	spotlight.Brightness = 3
	spotlight.Parent = spot

	local rigs: { GolferRig.Rig } = {}
	for _, entry in podium.Entries do
		local base = origin + Vector3.new(-entry.SlotX, 0, 0) -- camera looks along +Z: screen right = world -X
		local step = part(`Step_{entry.Place}`, Vector3.new(6, entry.StepHeight, 6), CFrame.new(base + Vector3.new(0, entry.StepHeight / 2, 0)), rgb(entry.StepColor), Enum.Material.SmoothPlastic, folder)
		local gui = Instance.new("SurfaceGui")
		gui.Face = Enum.NormalId.Front -- -Z, toward the camera
		gui.PixelsPerStud = 40
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		local number = Instance.new("TextLabel")
		number.Size = UDim2.fromScale(1, 1)
		number.BackgroundTransparency = 1
		number.Text = if entry.Outcome == "Draw" then "=" else tostring(entry.Place)
		number.Font = Enum.Font.BuilderSansExtraBold
		number.TextScaled = true
		number.TextColor3 = Color3.fromRGB(20, 20, 30)
		number.Parent = gui
		gui.Parent = step

		local model: Model? = nil
		if not entry.IsBot then
			model = cloneCharacter(tonumber(entry.Id) or 0)
		end
		local rig: GolferRig.Rig?
		if model then
			model.Parent = folder
			rig = GolferRig.forCharacter(model)
		end
		if rig == nil then
			rig = GolferRig.newBot(entry.Name, folder, if entry.IsBot then nil else Color3.fromRGB(150, 60, 200))
		end
		local golfer = rig :: GolferRig.Rig
		local top = base + Vector3.new(0, entry.StepHeight, 0)
		golfer.standAt(CFrame.lookAt(top, top + Vector3.new(0, 0, -1)))
		local emote = if entry.Outcome == "Winner" and emotes then emotes[entry.Id] else nil
		golfer.play(entry.Animation, nil, nil, emote)
		if not golfer.IsBot then
			nameTag(golfer.Model, entry.Name, if entry.Outcome == "Winner" then Color3.fromRGB(255, 214, 90) else Color3.new(1, 1, 1))
		end
		table.insert(rigs, golfer)
		if entry.Outcome == "Winner" then
			confetti(top + Vector3.new(0, 12, 0), folder)
		end
	end

	return {
		-- In front of the stage and a little to the side, so the podium sits right of
		-- centre (the scoreboard panel is docked on the left of the screen).
		CameraPosition = origin + Vector3.new(6, 7.5, -24),
		CameraLook = origin + Vector3.new(6, 4.5, 0),
		destroy = function()
			for _, rig in rigs do
				rig.destroy()
			end
			folder:Destroy()
		end,
	}
end

return PodiumStage
