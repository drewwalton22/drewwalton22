--!strict
--[[
	CosmeticBuilder.luau  (Client/Golf)

	Turns CosmeticsData looks into Instances. Everything degrades gracefully: a
	missing template, a blank mesh id or an asset that fails to load all fall back
	to a procedural version, so a cosmetic is never invisible.

	  club(look, isPutter)   -> Model with a "Grip" attachment point (PrimaryPart).
	        1. a template in ReplicatedStorage.GolfRivalsAssets.Clubs named after the
	           skin id or the category (MeshParts / Models you import; the template's
	           PrimaryPart or a part named "Grip" is the hand position, the shaft
	           should run down its -Y axis)
	        2. a procedural shaft + a head Part wearing a SpecialMesh with the
	           category's HeadMeshId / HeadTextureId
	        3. a procedural shaft + a shaped head (wood / iron / putter)
	  dressBall(part, look)  -> colour, material, optional SpecialMesh skin, glow
	  trail(part, look)      -> Trail | Trail + sparkles | lagging Beam ribbon +
	                            sparkles; returns setEnabled / step / destroy
	  holeEffect(position, look) -> one-shot particle burst in the effect's style
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CosmeticsData = require(ReplicatedStorage.GolfRivals.Shared.CosmeticsData)

export type Trail = {
	setEnabled: (enabled: boolean) -> (),
	step: () -> (), -- call every frame while the ball moves (ribbons lag behind)
	destroy: () -> (),
}

local CosmeticBuilder = {}

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function material(name: string): Enum.Material
	local ok, value = pcall(function(): any
		return (Enum.Material :: any)[name]
	end)
	return if ok and typeof(value) == "EnumItem" then value :: Enum.Material else Enum.Material.SmoothPlastic
end

local function cosmeticPart(name: string, size: Vector3, color: Color3, mat: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = mat
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Anchored = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

local function weld(part0: BasePart, part1: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = part0
	w.Part1 = part1
	w.Parent = part1
end

local function findTemplate(names: { string }): Instance?
	local root = ReplicatedStorage:FindFirstChild("GolfRivalsAssets")
	local clubs = if root then root:FindFirstChild("Clubs") else nil
	if clubs == nil then
		return nil
	end
	for _, name in names do
		local found = clubs:FindFirstChild(name)
		if found and (found:IsA("Model") or found:IsA("BasePart")) then
			return found
		end
	end
	return nil
end

-- A club as a Model whose PrimaryPart ("Grip") sits in the hand; the shaft runs
-- down the grip's -Y axis with the head at the bottom.
function CosmeticBuilder.club(look: CosmeticsData.ClubLook, isPutter: boolean): Model
	local template = findTemplate(look.TemplateNames)
	if template then
		local copy = template:Clone()
		local model: Model
		if copy:IsA("Model") then
			model = copy
		else
			model = Instance.new("Model")
			copy.Parent = model
		end
		local grip = model.PrimaryPart or model:FindFirstChild("Grip", true)
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = false
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
				d.Massless = true
			end
		end
		if grip and grip:IsA("BasePart") then
			model.PrimaryPart = grip
			for _, d in model:GetDescendants() do
				if d:IsA("BasePart") and d ~= grip then
					weld(grip, d)
				end
			end
			return model
		end
		model:Destroy() -- unusable template (no grip): fall through to procedural
	end

	local model = Instance.new("Model")
	model.Name = "GolfClub"
	local length = if isPutter then 3.0 else 4.2
	local grip = cosmeticPart("Grip", Vector3.new(0.22, 0.6, 0.22), Color3.fromRGB(20, 20, 24), Enum.Material.Fabric)
	grip.Parent = model
	model.PrimaryPart = grip
	local shaft = cosmeticPart("Shaft", Vector3.new(length, 0.14, 0.14), rgb(look.AccentColor), Enum.Material.Metal)
	shaft.Shape = Enum.PartType.Cylinder
	shaft.CFrame = grip.CFrame * CFrame.new(0, -length / 2, 0) * CFrame.Angles(0, 0, math.rad(90))
	shaft.Parent = model
	weld(grip, shaft)

	local headColor, headMaterial = rgb(look.HeadColor), material(look.Material)
	local head: Part
	if look.Shape == "Wood" then
		head = cosmeticPart("Head", Vector3.new(0.8, 0.55, 1.0), headColor, headMaterial)
		head.Shape = Enum.PartType.Ball
	elseif look.Shape == "Putter" then
		head = cosmeticPart("Head", Vector3.new(0.3, 0.32, 0.95), headColor, headMaterial)
	else
		head = cosmeticPart("Head", Vector3.new(0.18, 0.5, 0.75), headColor, headMaterial)
	end
	if look.HeadMeshId ~= "" then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.FileMesh
		mesh.MeshId = look.HeadMeshId
		mesh.TextureId = look.HeadTextureId
		mesh.Scale = Vector3.one * look.HeadScale
		mesh.Parent = head
	end
	head.CFrame = grip.CFrame * CFrame.new(0, -length - 0.1, -0.2)
	head.Parent = model
	weld(grip, head)
	return model
end

function CosmeticBuilder.dressBall(part: BasePart, look: CosmeticsData.BallLook)
	part.Color = rgb(look.Color)
	part.Material = material(look.Material)
	local oldMesh = part:FindFirstChild("SkinMesh")
	if oldMesh then
		oldMesh:Destroy()
	end
	if look.MeshId ~= "" then
		local mesh = Instance.new("SpecialMesh")
		mesh.Name = "SkinMesh"
		mesh.MeshType = Enum.MeshType.FileMesh
		mesh.MeshId = look.MeshId
		mesh.TextureId = look.TextureId
		mesh.Parent = part
	end
	local oldGlow = part:FindFirstChild("Glow")
	if oldGlow then
		oldGlow:Destroy()
	end
	if look.Glow then
		local light = Instance.new("PointLight")
		light.Name = "Glow"
		light.Color = rgb(look.Color)
		light.Range = 8
		light.Brightness = 1.6
		light.Parent = part
	end
end

local function sparkles(parent: Instance, look: CosmeticsData.TrailLook): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(rgb(look.Color), rgb(look.Color2))
	emitter.LightEmission = look.LightEmission
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 0) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	emitter.Lifetime = NumberRange.new(look.Lifetime * 0.6, look.Lifetime)
	emitter.Speed = NumberRange.new(0.5, 2)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rate = look.ParticleRate
	emitter.Enabled = false
	emitter.Parent = parent
	return emitter
end

-- Ball trail in the look's style. Disabled until setEnabled(true).
function CosmeticBuilder.trail(ball: BasePart, look: CosmeticsData.TrailLook): Trail
	local size = ball.Size.Y
	local top = Instance.new("Attachment")
	top.Position = Vector3.new(0, size * 0.35 * look.Width, 0)
	top.Parent = ball
	local bottom = Instance.new("Attachment")
	bottom.Position = Vector3.new(0, -size * 0.35 * look.Width, 0)
	bottom.Parent = ball
	local streak = Instance.new("Trail")
	streak.Attachment0 = top
	streak.Attachment1 = bottom
	streak.Color = ColorSequence.new(rgb(look.Color), rgb(look.Color2))
	streak.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	streak.Lifetime = look.Lifetime
	streak.MinLength = 0.05
	streak.LightEmission = look.LightEmission
	if look.TextureId ~= "" then
		streak.Texture = look.TextureId
		streak.TextureMode = Enum.TextureMode.Stretch
	end
	streak.Enabled = false
	streak.Parent = ball

	local emitter: ParticleEmitter? = if look.Style ~= "Trail" then sparkles(ball, look) else nil

	-- Ribbon: a Beam from the ball to an invisible anchor that lags behind it.
	local tail: Part? = nil
	local beam: Beam? = nil
	if look.Style == "Ribbon" then
		local anchor = Instance.new("Part")
		anchor.Name = "RibbonTail"
		anchor.Size = Vector3.new(0.2, 0.2, 0.2)
		anchor.Transparency = 1
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.CanTouch = false
		anchor.CFrame = ball.CFrame
		anchor.Parent = ball.Parent
		local tailAttachment = Instance.new("Attachment")
		tailAttachment.Parent = anchor
		local ballAttachment = Instance.new("Attachment")
		ballAttachment.Parent = ball
		local ribbon = Instance.new("Beam")
		ribbon.Attachment0 = ballAttachment
		ribbon.Attachment1 = tailAttachment
		ribbon.Color = ColorSequence.new(rgb(look.Color), rgb(look.Color2))
		ribbon.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(1, 1) })
		ribbon.Width0 = size * look.Width
		ribbon.Width1 = 0.1
		ribbon.LightEmission = look.LightEmission
		ribbon.FaceCamera = true
		ribbon.Segments = 12
		if look.TextureId ~= "" then
			ribbon.Texture = look.TextureId
		end
		ribbon.Enabled = false
		ribbon.Parent = ball
		tail, beam = anchor, ribbon
	end

	return {
		setEnabled = function(enabled: boolean)
			streak.Enabled = enabled
			if enabled then
				streak:Clear()
			end
			if emitter then
				emitter.Enabled = enabled
			end
			if beam and tail then
				beam.Enabled = enabled
				tail.CFrame = ball.CFrame
			end
		end,
		step = function()
			if tail then
				-- The tail chases the ball: the ribbon stretches with speed.
				local t = tail :: Part
				t.CFrame = CFrame.new(t.Position:Lerp(ball.Position, 0.18))
			end
		end,
		destroy = function()
			if tail then
				tail:Destroy()
			end
		end,
	}
end

-- One-shot burst for a ball dropping in the cup (or any celebration).
function CosmeticBuilder.holeEffect(position: Vector3, look: CosmeticsData.HoleEffectLook)
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Position = position + Vector3.new(0, 1.5, 0)
	anchor.Parent = workspace

	local color = rgb(look.Color)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color, Color3.new(1, 1, 1))
	emitter.LightEmission = 0.6
	emitter.Rate = 0
	emitter.Enabled = false
	local style = look.Style
	if style == "Splash" then
		emitter.Size = NumberSequence.new(0.7, 0)
		emitter.Speed = NumberRange.new(18, 28)
		emitter.SpreadAngle = Vector2.new(25, 25)
		emitter.Acceleration = Vector3.new(0, -60, 0)
		emitter.Lifetime = NumberRange.new(0.6, 1.1)
	elseif style == "Sparks" or style == "Firework" then
		emitter.Size = NumberSequence.new(0.35, 0)
		emitter.Speed = NumberRange.new(20, 40)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Acceleration = Vector3.new(0, -20, 0)
		emitter.Lifetime = NumberRange.new(0.5, 1.2)
		emitter.LightEmission = 1
	elseif style == "Crown" or style == "Supernova" then
		emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.8), NumberSequenceKeypoint.new(1, 0) })
		emitter.Speed = NumberRange.new(10, 34)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Lifetime = NumberRange.new(1, 2)
		emitter.LightEmission = 1
		local light = Instance.new("PointLight")
		light.Color = color
		light.Range = 30
		light.Brightness = 4
		light.Parent = anchor
	else -- Confetti
		emitter.Size = NumberSequence.new(0.5)
		emitter.Speed = NumberRange.new(14, 30)
		emitter.SpreadAngle = Vector2.new(70, 70)
		emitter.Acceleration = Vector3.new(0, -30, 0)
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.RotSpeed = NumberRange.new(-300, 300)
		emitter.Lifetime = NumberRange.new(1, 1.8)
	end
	emitter.Parent = anchor
	emitter:Emit(look.Count)
	if style == "Firework" or style == "Supernova" then
		task.delay(0.35, function()
			emitter:Emit(math.floor(look.Count / 2))
		end)
	end
	Debris:AddItem(anchor, 3)
end

return CosmeticBuilder
