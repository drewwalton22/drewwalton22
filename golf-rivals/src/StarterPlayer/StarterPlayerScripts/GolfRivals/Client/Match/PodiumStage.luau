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

	ANIMATIONS: the winner plays their equipped VICTORY EMOTE (a cosmetic; see
	CosmeticsData.animation): their own / published animation, else Roblox's
	built-in cheer / dance / wave emote for their body type, else the procedural
	Victory pose if the asset can't load (GolferRig handles that fallback). The
	loser plays the published Defeat animation or the procedural Defeat pose.

	LIGHTING: the stage sits inside a closed studio room (walls behind the camera
	too) lit by its own key / fill / rim lights; PodiumLighting sets the neutral
	Lighting values while it shows and restores them after. The camera framing is
	returned so the caller can point CameraController at it while MatchHud docks
	the scoreboard on the left.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local CosmeticsData = require(Shared.CosmeticsData)
local PodiumView = require(Shared.PodiumView)

local GolferRig = require(script.Parent.Parent.Golf.GolferRig)

export type Stage = {
	CameraPosition: Vector3,
	CameraLook: Vector3,
	Origin: Vector3,
	Lights: { Light }, -- the stage's own (soft) lights; PodiumLighting keeps these on
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

-- Light helpers (all hosted on invisible, non-colliding anchor parts).
local function anchorAt(name: string, position: Vector3, look: Vector3?, parent: Instance): Part
	local cframe = if look then CFrame.lookAt(position, look) else CFrame.new(position)
	local anchor = part(name, Vector3.new(0.5, 0.5, 0.5), cframe, Color3.new(1, 1, 1), Enum.Material.SmoothPlastic, parent)
	anchor.Transparency = 1
	anchor.CastShadow = false
	return anchor
end

local function spotLight(host: Part, brightness: number, range: number, angle: number, color: Color3, shadows: boolean): SpotLight
	local light = Instance.new("SpotLight")
	light.Face = Enum.NormalId.Front -- the anchor's look direction
	light.Brightness = brightness
	light.Range = range
	light.Angle = angle
	light.Color = color
	light.Shadows = shadows
	light.Parent = host
	return light
end

local function pointLight(host: Part, brightness: number, range: number, color: Color3): PointLight
	local light = Instance.new("PointLight")
	light.Brightness = brightness
	light.Range = range
	light.Color = color
	light.Shadows = false
	light.Parent = host
	return light
end

-- The studio: a CLOSED room around the stage and the camera, so the course's sun,
-- sky haze and glare can't reach in. Everything inside is lit by the stage's own
-- lights plus PodiumLighting's neutral ambient. Returns the lights to keep on.
local function buildStudio(origin: Vector3, folder: Instance): { Light }
	local wallColor = Color3.fromRGB(30, 34, 64)
	local function slab(name: string, size: Vector3, offset: Vector3, color: Color3, material: Enum.Material): Part
		return part(name, size, CFrame.new(origin + offset), color, material, folder)
	end
	-- Room: x -46..50, y 0..30, z -36..13 (the camera sits at z -24).
	slab("Floor", Vector3.new(96, 1, 50), Vector3.new(2, -0.5, -11.5), Color3.fromRGB(36, 40, 70), Enum.Material.SmoothPlastic)
	slab("Ceiling", Vector3.new(96, 1, 50), Vector3.new(2, 30.5, -11.5), wallColor, Enum.Material.SmoothPlastic)
	local back = slab("Backdrop", Vector3.new(96, 31, 1), Vector3.new(2, 15, 13), wallColor, Enum.Material.SmoothPlastic)
	slab("FrontWall", Vector3.new(96, 31, 1), Vector3.new(2, 15, -36), wallColor, Enum.Material.SmoothPlastic)
	slab("LeftWall", Vector3.new(1, 31, 50), Vector3.new(-46, 15, -11.5), wallColor, Enum.Material.SmoothPlastic)
	slab("RightWall", Vector3.new(1, 31, 50), Vector3.new(50, 15, -11.5), wallColor, Enum.Material.SmoothPlastic)

	-- Backdrop dressing: a softly glowing gradient panel framed by neon strips.
	local panel = slab("Panel", Vector3.new(40, 18, 0.4), Vector3.new(-3.5, 11, 12.4), Color3.fromRGB(70, 60, 150), Enum.Material.SmoothPlastic)
	local gui = Instance.new("SurfaceGui") -- vertical colour fade, no image upload needed
	gui.Face = Enum.NormalId.Front
	gui.LightInfluence = 0.35
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 8
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BorderSizePixel = 0
	fill.BackgroundColor3 = Color3.new(1, 1, 1)
	fill.Parent = gui
	local fade = Instance.new("UIGradient")
	fade.Rotation = 90
	fade.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 90, 230)),
		ColorSequenceKeypoint.new(0.6, Color3.fromRGB(60, 50, 140)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(28, 26, 70)),
	})
	fade.Parent = fill
	gui.Parent = panel
	for _, strip in { { y = 20.2, color = Color3.fromRGB(80, 220, 255) }, { y = 1.8, color = Color3.fromRGB(255, 90, 190) } } do
		slab("NeonStrip", Vector3.new(40, 0.35, 0.3), Vector3.new(-3.5, strip.y, 12.1), strip.color, Enum.Material.Neon)
	end
	for _, x in { -23.5, 16.5 } do
		slab("NeonPost", Vector3.new(0.35, 18.4, 0.3), Vector3.new(x, 11, 12.1), Color3.fromRGB(255, 200, 70), Enum.Material.Neon)
	end
	local glow = slab("FloorGlow", Vector3.new(26, 0.1, 12), Vector3.new(-3.5, 0.05, 0), Color3.fromRGB(110, 140, 255), Enum.Material.Neon)
	glow.Transparency = 0.86

	-- KEY: warm spotlight from above the camera onto both steps (casts the shadows).
	local key = spotLight(anchorAt("KeyLight", origin + Vector3.new(3, 22, -18), origin + Vector3.new(-3.5, 3, 0), folder), 1.6, 48, 55, Color3.fromRGB(255, 244, 228), true)
	-- FILLS: soft and cool from both front corners, so no face is left in shadow.
	local fillRight = pointLight(anchorAt("FillRight", origin + Vector3.new(-20, 9, -12), nil, folder), 0.7, 32, Color3.fromRGB(215, 228, 255))
	local fillLeft = pointLight(anchorAt("FillLeft", origin + Vector3.new(14, 9, -12), nil, folder), 0.7, 32, Color3.fromRGB(215, 228, 255))
	-- RIM: from behind and above, outlining shoulders and hair against the backdrop.
	local rim = spotLight(anchorAt("RimLight", origin + Vector3.new(-3.5, 24, 9), origin + Vector3.new(-3.5, 4, -2), folder), 1.1, 34, 70, Color3.fromRGB(205, 180, 255), false)
	-- WASH: a gentle glow on the backdrop itself.
	local wash = Instance.new("SurfaceLight")
	wash.Face = Enum.NormalId.Front
	wash.Range = 14
	wash.Brightness = 0.35
	wash.Angle = 80
	wash.Color = Color3.fromRGB(140, 150, 255)
	wash.Parent = back
	return { key, fillRight, fillLeft, rim, wash }
end

-- Extra flair for rarer victory emotes ("Sparkle" / "Aura").
local function emoteEffect(effect: string, at: Vector3, folder: Instance)
	if effect ~= "Sparkle" and effect ~= "Aura" then
		return
	end
	local anchor = anchorAt("EmoteFX", at + Vector3.new(0, 3, 0), nil, folder)
	local sparkle = Instance.new("ParticleEmitter")
	sparkle.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparkle.Color = ColorSequence.new(Color3.fromRGB(255, 220, 90), Color3.fromRGB(255, 255, 220))
	sparkle.LightEmission = 0.8
	sparkle.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0) })
	sparkle.Lifetime = NumberRange.new(1, 1.8)
	sparkle.Speed = NumberRange.new(1, 3)
	sparkle.SpreadAngle = Vector2.new(180, 180)
	sparkle.Rate = if effect == "Aura" then 40 else 18
	sparkle.Parent = anchor
	if effect == "Aura" then
		sparkle.Acceleration = Vector3.new(0, 4, 0) -- rising golden motes
		pointLight(anchor, 0.9, 10, Color3.fromRGB(255, 210, 110))
		local ring = part("AuraRing", Vector3.new(0.2, 5, 5), CFrame.new(at + Vector3.new(0, 0.12, 0)) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(255, 205, 80), Enum.Material.Neon, folder)
		ring.Shape = Enum.PartType.Cylinder
		ring.Transparency = 0.55
		ring.CastShadow = false
	end
end

-- Builds the stage at `origin` (golfers face -Z, toward the camera).
-- `emotes`: player id -> their equipped victory emote item id (CosmeticsData); a
-- winner without one gets CosmeticsData.DEFAULT_EMOTE (Fist Pump, owned by all).
function PodiumStage.build(podium: PodiumView.Podium, origin: Vector3, emotes: { [string]: string }?): Stage
	local folder = Instance.new("Folder")
	folder.Name = "Podium"
	folder.Parent = workspace

	local lights = buildStudio(origin, folder)

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
		if entry.Outcome == "Winner" then
			-- The equipped victory emote: a published / built-in Roblox animation for
			-- this body type; GolferRig falls back to the procedural pose if it fails.
			local look = CosmeticsData.animation((if emotes then emotes[entry.Id] else nil) or CosmeticsData.DEFAULT_EMOTE, golfer.RigType)
			golfer.play("Victory", nil, nil, if look.AnimationId ~= "" then look.AnimationId else nil)
			emoteEffect(look.Effect, top, folder)
		else
			golfer.play(entry.Animation) -- Defeat: published Defeat animation, else procedural
		end
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
		Origin = origin,
		Lights = lights,
		destroy = function()
			for _, rig in rigs do
				rig.destroy()
			end
			folder:Destroy()
		end,
	}
end

return PodiumStage
