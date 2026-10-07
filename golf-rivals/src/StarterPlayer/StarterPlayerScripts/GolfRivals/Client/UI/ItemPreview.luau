--!strict
--[[
	ItemPreview.luau  (Client/UI)

	Rotating 3D previews of cosmetics in a ViewportFrame, built by the SAME
	CosmeticBuilder code the game uses (so a preview is exactly what you get):

	  club skins   the code-built head for its category, close up, slowly orbiting
	  balls        the ball with its pattern (bands, swirls, accretion disc ...)
	  trails       a ball with a comet tail of fading spheres in the trail colours
	               (Trails / particles don't render inside ViewportFrames)
	  hole effects a burst of neon shards in the effect's colour and style
	  animations   no model: the card keeps its glyph

	One shared loop turns every preview's camera ~30 times a second, and only for
	previews that are actually on screen, so a long inventory grid stays cheap.
	Previews clean themselves up when their card is destroyed.

	attach(host, itemId) puts a preview inside any GuiObject (returns nil when the
	item has no model, so the caller keeps its fallback glyph).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.GolfRivals.Shared
local CosmeticsData = require(Shared.CosmeticsData)
local ItemDatabase = require(Shared.ItemDatabase)

local CosmeticBuilder = require(script.Parent.Parent.Golf.CosmeticBuilder)

local ItemPreview = {}

type Live = { Viewport: ViewportFrame, Camera: Camera, Focus: Vector3, Distance: number, Angle: number, Speed: number }

local live: { Live } = {}
local loop: RBXScriptConnection? = nil
local STEP = 1 / 30
local accumulator = 0.0

local CLUB_CLASSES: { [string]: boolean } = { Driver = true, FairwayWood = true, LongIron = true, ShortIron = true, Wedge = true, Putter = true }

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function anchorAll(model: Instance)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	if model:IsA("BasePart") then
		model.Anchored = true
	end
end

local function neonBall(name: string, size: number, position: Vector3, color: Color3, transparency: number, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.new(size, size, size)
	p.CFrame = CFrame.new(position)
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Transparency = transparency
	p.Anchored = true
	p.Parent = parent
	return p
end

-- The model for an item and the point / radius the camera should frame.
function ItemPreview.build(itemId: string): (Instance?, Vector3, number)
	local item = ItemDatabase.get(itemId)
	if item == nil then
		return nil, Vector3.zero, 1
	end
	local slot = item.Slot
	if CLUB_CLASSES[slot] then
		local model = CosmeticBuilder.club(CosmeticsData.club(item.Id, slot), slot == "Putter")
		anchorAll(model)
		-- Frame the HEAD (everything but the grip and the upper shaft).
		local low, high = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") and d.Name ~= "Shaft" and d.Name ~= "Grip" and d.Name ~= "GripRing" then
				local half = d.Size / 2
				low = low:Min(d.Position - half)
				high = high:Max(d.Position + half)
			end
		end
		if low.X == math.huge then
			return model, Vector3.zero, 2
		end
		local centre = (low + high) / 2
		return model, centre + Vector3.new(0, 0.15, 0), math.max((high - low).Magnitude * 0.62, 0.6)
	elseif slot == "BallModel" then
		return CosmeticBuilder.ball(CosmeticsData.ball(item.Id), 2), Vector3.zero, if item.Id == "ball_blackhole" then 2.4 else 1.35
	elseif slot == "BallTrail" then
		local look = CosmeticsData.trail(item.Id)
		local model = Instance.new("Model")
		local head = CosmeticBuilder.ball(CosmeticsData.ball(nil), 1.4)
		head.Parent = model
		for i = 1, 8 do
			local t = i / 8
			local color = rgb(look.Color):Lerp(rgb(look.Color2), t)
			neonBall("Puff", 1.3 * (1 - t * 0.7), Vector3.new(-t * 5, math.sin(t * math.pi) * 0.4, 0), color, 0.1 + t * 0.75, model)
		end
		return model, Vector3.new(-2, 0, 0), 3.2
	elseif slot == "HoleEffect" then
		local look = CosmeticsData.holeEffect(item.Id)
		local color = rgb(look.Color)
		local model = Instance.new("Model")
		-- A little cup with the burst rising out of it.
		local cup = Instance.new("Part")
		cup.Shape = Enum.PartType.Cylinder
		cup.Size = Vector3.new(0.3, 2.2, 2.2)
		cup.CFrame = CFrame.new(0, -1.2, 0) * CFrame.Angles(0, 0, math.rad(90))
		cup.Color = Color3.fromRGB(40, 140, 60)
		cup.Anchored = true
		cup.Parent = model
		local shards = math.clamp(math.floor(look.Count / 10), 6, 16)
		for i = 1, shards do
			local angle = i / shards * math.pi * 2
			local spread = 0.6 + (i % 3) * 0.35
			local shard = Instance.new("Part")
			shard.Size = Vector3.new(0.18, 0.7 + (i % 2) * 0.4, 0.18)
			shard.Material = Enum.Material.Neon
			shard.Color = color:Lerp(Color3.new(1, 1, 1), (i % 3) * 0.2)
			shard.Anchored = true
			local tip = Vector3.new(math.cos(angle) * spread, 0.6 + (i % 4) * 0.35, math.sin(angle) * spread)
			shard.CFrame = CFrame.lookAt(tip * 0.5, tip) * CFrame.Angles(math.rad(90), 0, 0)
			shard.Parent = model
		end
		if look.Style == "Crown" then
			for i = 1, 5 do
				local angle = i / 5 * math.pi * 2
				neonBall("Jewel", 0.32, Vector3.new(math.cos(angle) * 1.1, 1.9, math.sin(angle) * 1.1), Color3.fromRGB(255, 220, 90), 0, model)
			end
		end
		return model, Vector3.new(0, 0.3, 0), 2.6
	end
	return nil, Vector3.zero, 1
end

local function ensureLoop()
	if loop then
		return
	end
	loop = RunService.RenderStepped:Connect(function(dt: number)
		accumulator += dt
		if accumulator < STEP then
			return
		end
		local step = accumulator
		accumulator = 0
		local camera = workspace.CurrentCamera
		local screen = if camera then camera.ViewportSize else Vector2.new(1920, 1080)
		for i = #live, 1, -1 do
			local entry = live[i]
			local viewport = entry.Viewport
			if viewport.Parent == nil then
				table.remove(live, i)
			else
				local position, size = viewport.AbsolutePosition, viewport.AbsoluteSize
				local onScreen = size.X > 1 and position.X < screen.X and position.Y < screen.Y and position.X + size.X > 0 and position.Y + size.Y > 0
				if onScreen then
					entry.Angle += step * entry.Speed
					local offset = Vector3.new(math.cos(entry.Angle), 0.42, math.sin(entry.Angle)).Unit * entry.Distance
					entry.Camera.CFrame = CFrame.lookAt(entry.Focus + offset, entry.Focus)
				end
			end
		end
		if #live == 0 and loop then
			loop:Disconnect()
			loop = nil
		end
	end)
end

export type Options = { Spin: boolean?, ZIndex: number?, Speed: number? }

-- Fills `host` with a rotating preview of `itemId`. Returns nil (and adds
-- nothing) when the item has no 3D model.
function ItemPreview.attach(host: GuiObject, itemId: string, options: Options?): ViewportFrame?
	local model, focus, radius = ItemPreview.build(itemId)
	if model == nil then
		return nil
	end
	local opts: Options = options or {}
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Preview"
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.BackgroundTransparency = 1
	viewport.Ambient = Color3.fromRGB(165, 165, 185)
	viewport.LightColor = Color3.new(1, 1, 1)
	viewport.LightDirection = Vector3.new(-1, -1.4, -0.6)
	viewport.ZIndex = opts.ZIndex or host.ZIndex + 1
	local camera = Instance.new("Camera")
	camera.FieldOfView = 36
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	model.Parent = viewport
	local distance = radius / math.tan(math.rad(18))
	local angle = math.rad(35)
	camera.CFrame = CFrame.lookAt(focus + Vector3.new(math.cos(angle), 0.42, math.sin(angle)).Unit * distance, focus)
	viewport.Parent = host
	if opts.Spin ~= false then
		table.insert(live, { Viewport = viewport, Camera = camera, Focus = focus, Distance = distance, Angle = angle, Speed = opts.Speed or 0.9 })
		ensureLoop()
	end
	return viewport
end

return ItemPreview
