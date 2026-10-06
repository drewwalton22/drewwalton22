--!strict
-- ROBLOX-ONLY: clones models, loads meshes and writes terrain. WHERE things go is
-- the pure, tested DecorPlanner.
--[[
	MapDecorator.luau  (ServerScriptService.GolfRivals.Server)

	Auto-populates a hole's borders with decorative foliage, rocks and grass
	patches. Positions come from DecorPlanner (deterministic per hole, never on a
	playing surface); this module turns each planned item into a real object,
	sitting on the actual ground (raycast against the terrain):

	  for each item kind (Tree / Bush / Rock / GrassPatch), the first that exists:
	    1. TEMPLATES  ServerStorage.GolfRivalsAssets.Decor.<Kind>  - any MeshParts or
	                  Models you drop in (one is picked per item, scaled and rotated)
	    2. MESH IDS   Config.Decor.MeshIds[<Kind>]  - MeshPart asset ids, loaded once
	                  with AssetService:CreateMeshPartAsync and cached as templates
	    3. FALLBACK   a procedural stand-in: Rock / GrassPatch are painted INTO the
	                  Smooth Terrain (Rock boulders, LeafyGrass tufts); Tree / Bush
	                  are simple part trees so the course is never bare

	Decorations never collide and are excluded from ball raycasts (only course
	surfaces count), so they can't change a shot.
]]

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Config = require(Shared.Config)
local CourseDatabase = require(Shared.CourseDatabase)
local CourseLayout = require(Shared.CourseLayout)
local DecorPlanner = require(Shared.DecorPlanner)
local Logger = require(Shared.Logger)
local Prng = require(Shared.Prng)

local MapDecorator = {}

local SPM = CourseLayout.STUDS_PER_METER

local meshTemplates: { [string]: BasePart } = {} -- mesh id -> loaded template
local failedMeshes: { [string]: boolean } = {} -- ids that failed to load (not retried)

local function templatesFor(kind: string): { Instance }
	local list: { Instance } = {}
	local root = ServerStorage:FindFirstChild("GolfRivalsAssets")
	local decor = if root then root:FindFirstChild("Decor") else nil
	local folder = if decor then decor:FindFirstChild(kind) else nil
	if folder then
		for _, child in folder:GetChildren() do
			if child:IsA("BasePart") or child:IsA("Model") then
				table.insert(list, child)
			end
		end
	end
	if #list > 0 then
		return list
	end
	local ids: { string } = Config.Decor.MeshIds[kind] or {}
	for _, id in ids do
		if failedMeshes[id] then
			continue
		end
		local cached: BasePart? = meshTemplates[id]
		if not cached then
			local ok, part = pcall(function(): any
				return AssetService:CreateMeshPartAsync(Content.fromUri(id), {
					CollisionFidelity = Enum.CollisionFidelity.Box,
					RenderFidelity = Enum.RenderFidelity.Automatic,
				})
			end)
			if ok and typeof(part) == "Instance" and part:IsA("BasePart") then
				meshTemplates[id] = part
				cached = part
			else
				failedMeshes[id] = true
				Logger.info("Decor", `could not load mesh {id} for {kind}: {tostring(part)}`)
			end
		end
		if cached then
			table.insert(list, cached)
		end
	end
	return list
end

local function quiet(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
end

-- Place a template on the ground at `ground`, scaled and turned.
local function placeTemplate(template: Instance, ground: Vector3, scale: number, yawDeg: number, parent: Instance)
	local copy = template:Clone()
	local turn = CFrame.Angles(0, math.rad(yawDeg), 0)
	if copy:IsA("Model") then
		for _, d in copy:GetDescendants() do
			if d:IsA("BasePart") then
				quiet(d)
			end
		end
		copy:ScaleTo(copy:GetScale() * scale)
		local _, size = copy:GetBoundingBox()
		copy:PivotTo(CFrame.new(ground + Vector3.new(0, size.Y / 2, 0)) * turn)
	elseif copy:IsA("BasePart") then
		quiet(copy)
		copy.Size *= scale
		copy.CFrame = CFrame.new(ground + Vector3.new(0, copy.Size.Y / 2 - 0.2, 0)) * turn
	end
	copy.Parent = parent
end

local function block(parent: Instance, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?)
	local part = Instance.new("Part")
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Shape = shape or Enum.PartType.Block
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	quiet(part)
	part.Parent = parent
end

-- Procedural stand-ins (no templates, no mesh ids).
local function fallback(kind: string, ground: Vector3, scale: number, yawDeg: number, prng: Prng.Prng, parent: Instance)
	local terrain = workspace.Terrain
	if kind == "Rock" then
		terrain:FillBall(ground + Vector3.new(0, 1.2 * scale, 0), 3.2 * scale, Enum.Material.Rock)
	elseif kind == "GrassPatch" then
		terrain:FillCylinder(CFrame.new(ground + Vector3.new(0, 0.6, 0)), 1.6, 9 * scale, Enum.Material.LeafyGrass)
	elseif kind == "Bush" then
		for i = 1, 3 do
			local angle = math.rad(yawDeg + i * 120)
			local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * 1.6 * scale
			local size = (3 + prng.next() * 1.5) * scale
			block(parent, Vector3.new(size, size, size), CFrame.new(ground + offset + Vector3.new(0, size * 0.4, 0)), Color3.fromRGB(46, 110 + math.floor(prng.next() * 40), 50), Enum.Material.Grass, Enum.PartType.Ball)
		end
	else -- Tree
		local height = (16 + prng.next() * 10) * scale
		block(parent, Vector3.new(1.6 * scale, height, 1.6 * scale), CFrame.new(ground + Vector3.new(0, height / 2, 0)), Color3.fromRGB(94, 66, 42), Enum.Material.Wood)
		local crown = (11 + prng.next() * 6) * scale
		block(parent, Vector3.new(crown, crown, crown), CFrame.new(ground + Vector3.new(0, height + crown * 0.25, 0)), Color3.fromRGB(44 + math.floor(prng.next() * 30), 112 + math.floor(prng.next() * 40), 52), Enum.Material.Grass, Enum.PartType.Ball)
	end
end

-- Decorates around a hole whose frame is anchored at `origin`. Returns the folder
-- holding the new parts (terrain edits live in the terrain itself).
function MapDecorator.decorate(hole: CourseDatabase.HoleDef, origin: Vector3, seed: number, parent: Instance): Folder
	local folder = Instance.new("Folder")
	folder.Name = "Decor"
	folder.Parent = parent
	local items = DecorPlanner.forHole(hole, seed)
	local prng = Prng.new(seed + 1)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	params.IgnoreWater = false

	local placed = 0
	for _, item in items do
		local top = origin + Vector3.new(item.X * SPM, 300, item.Z * SPM)
		local hit = workspace:Raycast(top, Vector3.new(0, -700, 0), params)
		if hit and hit.Material ~= Enum.Material.Water then
			local templates = templatesFor(item.Kind)
			if #templates > 0 then
				placeTemplate(templates[prng.nextInt(#templates)], hit.Position, item.Scale, item.YawDeg, folder)
			else
				fallback(item.Kind, hit.Position, item.Scale, item.YawDeg, prng, folder)
			end
			placed += 1
		end
	end
	Logger.info("Decor", `{hole.Name}: placed {placed} decorations`)
	return folder
end

return MapDecorator
