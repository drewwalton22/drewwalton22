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
	        2. an uploaded head mesh (CosmeticsData.ItemMeshes for that exact skin,
	           else ClubMeshes for the category) on a code-built shaft
	        3. a CODE-BUILT head from Shared/CosmeticModels: a distinct shape per
	           category (driver, fairway wood, long / short iron, wedge, putter)
	           in the skin's colours and material, with more detail per rarity:
	           accent stripes, chrome / gold trims, neon inlays, and for Legendary
	           and Mythical a glow light, sparkles and a swing trail; Mythical
	           heads pulse.
	  dressBall(part, look)  -> colour, material, optional SpecialMesh skin, glow,
	                            and the ball's PATTERN (bands, swirls, glowing
	                            cracks, an orbiting accretion disc, sparkles)
	  setBallVisible(part, on) hides / shows the ball with its pattern and effects
	  trail(part, look)      -> Trail | Trail + sparkles | lagging Beam ribbon +
	                            sparkles; returns setEnabled / step / destroy
	  holeEffect(position, look) -> one-shot particle burst in the effect's style
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CosmeticModels = require(ReplicatedStorage.GolfRivals.Shared.CosmeticModels)
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

-- Every club gets an Attachment "Sole" at the bottom of its head - the point
-- GolferRig rests on the ground. Templates without one get it at their lowest
-- point along the grip's -Y axis.
local function ensureSole(model: Model, grip: BasePart)
	if model:FindFirstChild("Sole", true) then
		return
	end
	local lowest: BasePart = grip
	local lowestY = math.huge
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			local y = grip.CFrame:PointToObjectSpace(d.Position).Y - d.Size.Y / 2
			if y < lowestY then
				lowest, lowestY = d, y
			end
		end
	end
	local sole = Instance.new("Attachment")
	sole.Name = "Sole"
	sole.Parent = lowest -- parent first: WorldPosition is only world-space once attached
	sole.WorldPosition = lowest.Position - grip.CFrame.UpVector * (lowest.Size.Y / 2)
end

-- ---- animated bits (one shared loop) ------------------------------------------
-- Welds whose C0 spins (accretion discs) and lights / neon that pulse (Mythical).
type Spinner = { Weld: Weld, Base: CFrame, Rate: number }
type Pulser = { Light: PointLight?, Part: BasePart?, Base: number, Phase: number }
local spinners: { Spinner } = {}
local pulsers: { Pulser } = {}
local loopConnection: RBXScriptConnection? = nil

local function ensureLoop()
	if loopConnection then
		return
	end
	loopConnection = RunService.Heartbeat:Connect(function()
		local now = os.clock()
		for i = #spinners, 1, -1 do
			local s = spinners[i]
			if s.Weld.Parent == nil then
				table.remove(spinners, i)
			else
				s.Weld.C0 = s.Base * CFrame.Angles(0, math.rad(now * s.Rate) % (2 * math.pi), 0)
			end
		end
		for i = #pulsers, 1, -1 do
			local p = pulsers[i]
			local host: Instance? = p.Light or p.Part
			if host == nil or host.Parent == nil then
				table.remove(pulsers, i)
			else
				local wave = 0.5 + 0.5 * math.sin(now * 3 + p.Phase)
				if p.Light then
					p.Light.Brightness = p.Base * (0.55 + 0.9 * wave)
				end
				if p.Part then
					p.Part.Transparency = 0.35 * (1 - wave)
				end
			end
		end
	end)
end

-- ---- clubs --------------------------------------------------------------------------------
local function vec(v: CosmeticModels.Vec): Vector3
	return Vector3.new(v.X, v.Y, v.Z)
end

local TRIM_GOLD = Color3.fromRGB(255, 205, 80)
local TRIM_CHROME = Color3.fromRGB(215, 220, 230)

local function shapedPart(spec: CosmeticModels.Piece): Part
	local part = cosmeticPart(spec.Name, vec(spec.Size), Color3.new(1, 1, 1), Enum.Material.SmoothPlastic)
	if spec.Shape == "Cylinder" then
		part.Shape = Enum.PartType.Cylinder
	elseif spec.Shape == "Ellipsoid" then
		-- A Ball part is always a sphere; a Sphere SpecialMesh stretches to the size.
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = part
	end
	return part
end

-- Colour + material for a piece's role.
local function paint(part: BasePart, role: CosmeticModels.Role, look: CosmeticsData.ClubLook, tier: CosmeticModels.Tier)
	local primary, secondary = rgb(look.HeadColor), rgb(look.AccentColor)
	local skin = material(look.Material)
	if role == "Body" then
		part.Color, part.Material = primary, skin
	elseif role == "Face" then
		part.Color, part.Material = Color3.fromRGB(58, 60, 68), Enum.Material.Metal
	elseif role == "Sole" then
		part.Color, part.Material = if tier.Trim then TRIM_CHROME else secondary, Enum.Material.Metal
	elseif role == "Accent" then
		part.Color, part.Material = secondary, if skin == Enum.Material.Neon then Enum.Material.Neon else Enum.Material.SmoothPlastic
	elseif role == "Trim" then
		part.Color, part.Material = if tier.Level >= 5 then TRIM_GOLD else TRIM_CHROME, Enum.Material.Metal
		if tier.Level >= 5 then
			part.Material = Enum.Material.Foil
		end
	elseif role == "Neon" then
		part.Color, part.Material = secondary:Lerp(Color3.new(1, 1, 1), 0.15), Enum.Material.Neon
	elseif role == "Line" then
		part.Color, part.Material = Color3.new(1, 1, 1), Enum.Material.SmoothPlastic
	else -- Hosel
		part.Color, part.Material = Color3.fromRGB(40, 42, 48), Enum.Material.Metal
	end
end

-- Rarity flair on a head part: glow, sparkles, swing trail, pulse.
local function addFlair(head: BasePart, look: CosmeticsData.ClubLook, tier: CosmeticModels.Tier, glowParts: { BasePart })
	local accent = rgb(look.AccentColor)
	if tier.Glow then
		local light = Instance.new("PointLight")
		light.Name = "RarityGlow"
		light.Color = accent:Lerp(rgb(look.HeadColor), 0.4)
		light.Range = 6
		light.Brightness = if tier.Pulse then 1.4 else 0.9
		light.Shadows = false
		light.Parent = head
		if tier.Pulse then
			table.insert(pulsers, { Light = light, Part = nil, Base = light.Brightness, Phase = 0 })
			for i, part in glowParts do
				table.insert(pulsers, { Light = nil, Part = part, Base = 0, Phase = i * 0.7 })
			end
			ensureLoop()
		end
	end
	if tier.Sparkles then
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "RaritySparkles"
		emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		emitter.Color = ColorSequence.new(accent, Color3.new(1, 1, 1))
		emitter.LightEmission = 0.9
		emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.22), NumberSequenceKeypoint.new(1, 0) })
		emitter.Lifetime = NumberRange.new(0.5, 0.9)
		emitter.Speed = NumberRange.new(0.2, 0.8)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Rate = if tier.Pulse then 14 else 7
		emitter.Parent = head
	end
	if tier.SwingTrail then
		-- A streak behind the head: only visible while the club moves (the swing).
		local size = head.Size
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, size.Y / 2, 0)
		a0.Parent = head
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, -size.Y / 2, 0)
		a1.Parent = head
		local streak = Instance.new("Trail")
		streak.Name = "SwingTrail"
		streak.Attachment0 = a0
		streak.Attachment1 = a1
		streak.Color = ColorSequence.new(accent, rgb(look.HeadColor))
		streak.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
		streak.Lifetime = 0.25
		streak.MinLength = 0.1
		streak.LightEmission = 0.8
		streak.FaceCamera = true
		streak.Parent = head
	end
end

local function meshHead(look: CosmeticsData.ClubLook, spec: CosmeticModels.ClubSpec): Part
	local head = cosmeticPart("Head", Vector3.new(0.8, 0.5, 1), rgb(look.HeadColor), material(look.Material))
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.FileMesh
	mesh.MeshId = look.HeadMeshId
	mesh.TextureId = look.HeadTextureId
	mesh.Scale = Vector3.one * look.HeadScale
	mesh.Parent = head
	head.CFrame = CFrame.new(spec.Sole.X - 0.3, spec.Sole.Y + 0.25, spec.Sole.Z)
	return head
end

-- A club as a Model whose PrimaryPart ("Grip") sits in the hand; the shaft runs
-- down the grip's -Y axis with the head at the bottom (club frame: see
-- CosmeticModels). Built at the origin; callers PivotTo it.
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
			ensureSole(model, grip)
			return model
		end
		model:Destroy() -- unusable template (no grip): fall through to code-built
	end

	local class = if isPutter then "Putter" else look.Class
	local spec = CosmeticModels.club(class, look.Rarity)
	local model = Instance.new("Model")
	model.Name = "GolfClub"
	local grip = cosmeticPart("Grip", Vector3.new(0.24, 0.7, 0.24), Color3.fromRGB(24, 24, 28), Enum.Material.Fabric)
	grip.CFrame = CFrame.new() -- the hand; the club frame's origin
	grip.Parent = model
	model.PrimaryPart = grip
	-- Grip wrap rings in the accent colour (rarer clubs: more of them).
	for i = 1, math.max(1, spec.Tier.Accents) do
		local ring = cosmeticPart("GripRing", Vector3.new(0.04, 0.26, 0.26), rgb(look.AccentColor), Enum.Material.SmoothPlastic)
		ring.Shape = Enum.PartType.Cylinder
		ring.CFrame = CFrame.new(0, -0.3 + i * 0.12, 0) * CFrame.Angles(0, 0, math.rad(90))
		ring.Parent = model
		weld(grip, ring)
	end
	local shaftLength = spec.Length -- from the hand down to the hosel (hidden inside the grip at the top)
	local shaft = cosmeticPart("Shaft", Vector3.new(shaftLength, 0.09, 0.09), if spec.Tier.Level >= 5 then TRIM_GOLD else TRIM_CHROME, Enum.Material.Metal)
	shaft.Shape = Enum.PartType.Cylinder
	shaft.CFrame = CFrame.new(0, -shaftLength / 2, 0) * CFrame.Angles(0, 0, math.rad(90))
	shaft.Parent = model
	weld(grip, shaft)

	local head: BasePart
	local glowParts: { BasePart } = {}
	if look.HeadMeshId ~= "" then
		head = meshHead(look, spec)
		head.Parent = model
		weld(grip, head)
	else
		local body: BasePart? = nil
		for _, piece in spec.Pieces do
			local part = shapedPart(piece)
			paint(part, piece.Role, look, spec.Tier)
			part.CFrame = CFrame.new(vec(piece.Offset)) * CFrame.Angles(math.rad(piece.Rotation.X), math.rad(piece.Rotation.Y), math.rad(piece.Rotation.Z))
			part.Parent = model
			weld(grip, part)
			if piece.Role == "Body" and body == nil then
				body = part
			elseif piece.Role == "Neon" then
				table.insert(glowParts, part)
			end
		end
		head = body or shaft
		head.Name = "Head"
	end
	addFlair(head, look, spec.Tier, glowParts)

	-- The resting point (GolferRig puts it on the ground behind the ball).
	local sole = Instance.new("Attachment")
	sole.Name = "Sole"
	sole.Parent = head
	sole.WorldPosition = vec(spec.Sole)
	return model
end

-- ---- balls --------------------------------------------------------------------------------
local PATTERN = "BallPattern"

local function patternPart(name: string, size: Vector3, color: Color3, mat: Enum.Material): Part
	local part = cosmeticPart(name, size, color, mat)
	part:SetAttribute(PATTERN, true)
	return part
end

-- Glued to the ball with a Weld (its C0 can spin) so it follows every CFrame move.
local function glue(ball: BasePart, part: BasePart, offset: CFrame): Weld
	local w = Instance.new("Weld")
	w.Part0 = ball
	w.Part1 = part
	w.C0 = offset
	w.Parent = part
	part.CFrame = ball.CFrame * offset
	part.Parent = ball
	return w
end

local function clearPattern(ball: BasePart)
	for _, child in ball:GetChildren() do
		if child:GetAttribute(PATTERN) then
			child:Destroy()
		end
	end
end

local function addPattern(ball: BasePart, look: CosmeticsData.BallLook)
	local spec = CosmeticModels.ball(look.Id)
	local d = ball.Size.X
	local color = rgb(look.Color)
	local glow = if spec.GlowColor then rgb(spec.GlowColor :: { number }) else color
	if spec.BodyColor then
		ball.Color = rgb(spec.BodyColor :: { number })
	end
	if spec.BodyMaterial then
		ball.Material = material(spec.BodyMaterial :: string)
	end
	for i, band in spec.Bands do
		local bandColor: Color3
		local bandMaterial = Enum.Material.SmoothPlastic
		if band.Role == "Neon" then
			bandColor, bandMaterial = glow, Enum.Material.Neon
		elseif band.Role == "Trim" then
			bandColor, bandMaterial = Color3.fromRGB(255, 225, 120), Enum.Material.Foil
		elseif band.Role == "Line" then
			bandColor = Color3.fromRGB(30, 30, 36)
		else
			bandColor = color:Lerp(Color3.new(0, 0, 0), 0.4)
		end
		-- A thin cylinder slightly wider than the ball = a ring hugging its surface.
		local ring = patternPart(`Band{i}`, Vector3.new(d * band.Width, d * 1.015, d * 1.015), bandColor, bandMaterial)
		ring.Shape = Enum.PartType.Cylinder
		glue(ball, ring, CFrame.Angles(math.rad(band.Rotation.X), math.rad(band.Rotation.Y), math.rad(band.Rotation.Z)))
	end
	local disc = spec.Disc
	if disc then
		local ring = patternPart("AccretionDisc", Vector3.new(d * disc.Thickness, d * disc.Diameter, d * disc.Diameter), glow, Enum.Material.Neon)
		ring.Shape = Enum.PartType.Cylinder
		ring.Transparency = 0.25
		-- Cylinder axis is X: stand it up (axis Y) and tilt it.
		local base = CFrame.Angles(math.rad(disc.Tilt), 0, 0) * CFrame.Angles(0, 0, math.rad(90))
		local w = glue(ball, ring, base)
		local inner = patternPart("DiscInner", Vector3.new(d * disc.Thickness * 1.5, d * disc.Diameter * 0.62, d * disc.Diameter * 0.62), Color3.fromRGB(170, 90, 255), Enum.Material.Neon)
		inner.Shape = Enum.PartType.Cylinder
		inner.Transparency = 0.35
		local w2 = glue(ball, inner, base)
		if spec.SpinRate ~= 0 then
			-- The loop sets C0 = tilt * spin(Y); C1 = standUp^-1 keeps the disc flat
			-- in the tilted plane (Part1 = Part0 * C0 * C1^-1).
			local tilt = CFrame.Angles(math.rad(disc.Tilt), 0, 0)
			table.insert(spinners, { Weld = w, Base = tilt, Rate = spec.SpinRate })
			table.insert(spinners, { Weld = w2, Base = tilt, Rate = -spec.SpinRate * 1.6 })
			w.C1 = CFrame.Angles(0, 0, math.rad(-90))
			w2.C1 = CFrame.Angles(0, 0, math.rad(-90))
			-- Bright clumps orbiting on the disc make the spin visible.
			for k = 1, 4 do
				local radius = d * disc.Diameter * (0.3 + 0.04 * k)
				local clump = patternPart(`Clump{k}`, Vector3.new(d * 0.14, d * 0.14, d * 0.14), Color3.new(1, 0.9, 0.7), Enum.Material.Neon)
				clump.Shape = Enum.PartType.Ball
				local cw = glue(ball, clump, tilt * CFrame.Angles(0, k * math.pi / 2, 0) * CFrame.new(radius, 0, 0))
				cw.C1 = CFrame.new(-radius, 0, 0)
				table.insert(spinners, { Weld = cw, Base = tilt * CFrame.Angles(0, k * math.pi / 2, 0), Rate = spec.SpinRate * (1.4 - 0.1 * k) })
			end
			ensureLoop()
		end
	end
	if spec.Core then
		local core = Instance.new("PointLight")
		core.Name = "CoreGlow"
		core:SetAttribute(PATTERN, true)
		core.Color = glow
		core.Range = 5
		core.Brightness = 1.4
		core.Parent = ball
		table.insert(pulsers, { Light = core, Part = nil, Base = 1.4, Phase = 0 })
		ensureLoop()
	end
	if spec.Sparkles or spec.Embers then
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "BallSparkles"
		emitter:SetAttribute(PATTERN, true)
		emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		emitter.Color = ColorSequence.new(glow, Color3.new(1, 1, 1))
		emitter.LightEmission = 1
		emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, d * 0.35), NumberSequenceKeypoint.new(1, 0) })
		emitter.Lifetime = NumberRange.new(0.5, 1)
		emitter.Speed = NumberRange.new(0.3, 1.2)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Acceleration = if spec.Embers then Vector3.new(0, 3, 0) else Vector3.zero
		emitter.Rate = 10
		emitter.Parent = ball
	end
end

function CosmeticBuilder.dressBall(part: BasePart, look: CosmeticsData.BallLook)
	part.Color = rgb(look.Color)
	part.Material = material(look.Material)
	clearPattern(part)
	local oldMesh = part:FindFirstChild("SkinMesh")
	if oldMesh then
		oldMesh:Destroy()
	end
	if look.MeshId ~= "" then
		-- An uploaded ball mesh replaces the code-built pattern.
		local mesh = Instance.new("SpecialMesh")
		mesh.Name = "SkinMesh"
		mesh.MeshType = Enum.MeshType.FileMesh
		mesh.MeshId = look.MeshId
		mesh.TextureId = look.TextureId
		mesh.Parent = part
	else
		addPattern(part, look)
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

-- Hide / show a dressed ball together with its pattern, lights and sparkles.
function CosmeticBuilder.setBallVisible(ball: BasePart, visible: boolean)
	ball.Transparency = if visible then 0 else 1
	for _, d in ball:GetDescendants() do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = if visible then 0 else 1
		elseif d:IsA("Light") then
			d.Enabled = visible
		elseif d:IsA("ParticleEmitter") and d.Name == "BallSparkles" then
			d.Enabled = visible
		end
	end
end

-- A free-standing dressed ball (previews): anchored, at the origin.
function CosmeticBuilder.ball(look: CosmeticsData.BallLook, diameter: number): Part
	local ball = Instance.new("Part")
	ball.Name = "PreviewBall"
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(diameter, diameter, diameter)
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.CFrame = CFrame.new()
	CosmeticBuilder.dressBall(ball, look)
	return ball
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
