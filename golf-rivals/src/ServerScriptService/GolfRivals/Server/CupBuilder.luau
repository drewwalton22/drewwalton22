--!strict
-- ROBLOX-ONLY: raycasts the world and creates parts. The cup's sizes are the pure,
-- tested Shared/CupGeometry.
--[[
	CupBuilder.luau  (ServerScriptService.GolfRivals.Server)

	Builds the visible cup at a pin WITHOUT CSG, for generated holes (TerrainBuilder)
	and hand-built holes in Workspace.GolfCourses (CourseRegistry):

	  1. RAYCASTS the real green around the pin (6 rays just outside the cup) to
	     find the turf's height and tilt there. The rays skip the pin itself, so it
	     works whatever the green is made of (turf parts, MeshParts or Terrain).
	  2. If that green is Smooth Terrain, carves the pocket with
	     Terrain:FillCylinder(..., Enum.Material.Air).
	  3. Builds the pocket (all non-colliding, raycasts ignore them):
	       CupBottom  dark disc at the bottom
	       CupWall    dark planks lining the pocket's sides
	       CupRim     thin white liner ring whose top sits just ABOVE the turf, so
	                  the cup reads from the tee even on a solid green
	       CupPlug    invisible disc at turf level that raycasts DO hit (lie
	                  Green): the physics rolls over a flat green, as before
	  4. Checks the hole is open (a ray down the middle reaches the pocket floor).
	     If the green is still solid there (a MeshPart green, or terrain the carve
	     couldn't open), it adds a dark CupShade disc on top so the cup is still
	     plainly visible, and logs a warning.

	Every step that can fail logs a warning ("[GolfRivals][Cup] ...") instead of
	failing silently.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local CupGeometry = require(Shared.CupGeometry)
local SurfaceMaterials = require(Shared.SurfaceMaterials)

export type Options = {
	Parent: Instance,
	Centre: Vector3, -- the pin in world space; Y is a fallback turf height
	Up: Vector3?, -- fallback turf normal
	Exclude: { Instance }?, -- ignored by the ground rays (pin, flag, decorations)
	Label: string, -- for log messages
}

export type Cup = {
	Model: Model,
	Surface: Vector3, -- turf point at the cup centre
	Up: Vector3,
	Open: boolean, -- the ball can be seen inside the pocket
}

local CupBuilder = {}

local DARK = Color3.fromRGB(16, 16, 18)
local WHITE = Color3.fromRGB(245, 245, 245)
local PROBES = 6

local function warnCup(label: string, message: string)
	warn(`[GolfRivals][Cup] {label}: {message}`)
end

local function piece(name: string, size: Vector3, cframe: CFrame, color: Color3, parent: Instance, cylinder: boolean?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Color = color
	p.Size = size
	if cylinder then
		p.Shape = Enum.PartType.Cylinder
		p.CFrame = cframe * CFrame.Angles(0, 0, math.pi / 2) -- cylinder axis (X) along the frame's up
	else
		p.CFrame = cframe
	end
	p.Parent = parent
	return p
end

local function rayParams(exclude: { Instance }): RaycastParams
	local list: { Instance } = table.clone(exclude)
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(list, player.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = list
	params.IgnoreWater = true
	return params
end

-- The turf's height and normal at the pin, from rays just outside the cup.
local function probe(options: Options, params: RaycastParams): (Vector3?, Vector3?, boolean)
	local c = options.Centre
	local radius = CupGeometry.RADIUS + 0.4
	local sumY, sumN, hits = 0, Vector3.zero, 0
	local terrain = false
	for k = 1, PROBES do
		local a = k / PROBES * math.pi * 2
		local from = Vector3.new(c.X + math.cos(a) * radius, c.Y + 12, c.Z + math.sin(a) * radius)
		local result = workspace:Raycast(from, Vector3.new(0, -40, 0), params)
		if result then
			hits += 1
			sumY += result.Position.Y
			sumN += result.Normal
			if result.Instance == workspace.Terrain then
				terrain = true
			end
		end
	end
	if hits < PROBES then
		warnCup(options.Label, `only {hits} of {PROBES} ground rays around the pin hit the green`)
	end
	if hits == 0 then
		return nil, nil, false
	end
	-- Symmetric probes: their mean height is the plane's height at the centre.
	return Vector3.new(c.X, sumY / hits, c.Z), sumN.Unit, terrain
end

local function frameAt(point: Vector3, up: Vector3): CFrame
	local right = Vector3.xAxis - up * up.X
	right = if right.Magnitude > 1e-4 then right.Unit else Vector3.zAxis
	return CFrame.fromMatrix(point, right, up)
end

function CupBuilder.build(options: Options): Cup
	local exclude: { Instance } = options.Exclude or {}
	local params = rayParams(exclude)
	local surface, up, onTerrain = probe(options, params)
	if surface == nil then
		warnCup(options.Label, "no green found under the pin - using the planned height")
	end
	local point = surface or options.Centre
	local normal = up or options.Up or Vector3.yAxis
	if normal.Y < 0.5 then
		normal = Vector3.yAxis -- a probe hit a wall: keep the cup level
	end
	local frame = frameAt(point, normal)
	local R, D = CupGeometry.RADIUS, CupGeometry.DEPTH

	-- Smooth Terrain green: carve the pocket out of it.
	if onTerrain then
		local ok, err = pcall(function()
			workspace.Terrain:FillCylinder(frame * CFrame.new(0, -D / 2 + 0.1, 0), D + 0.2, R, Enum.Material.Air)
		end)
		if not ok then
			warnCup(options.Label, `carving the terrain green failed: {tostring(err)}`)
		end
	end

	local model = Instance.new("Model")
	model.Name = "Cup"
	-- Bottom, walls, rim.
	piece("CupBottom", Vector3.new(0.05, 2 * R - 0.02, 2 * R - 0.02), frame * CFrame.new(0, -D + CupGeometry.FLOOR - 0.025, 0), DARK, model, true)
	local n = CupGeometry.SEGMENTS
	local chord = 2 * R * math.sin(math.pi / n) * 1.12
	for i = 1, n do
		local a = (i - 0.5) / n * math.pi * 2
		local spin = CFrame.Angles(0, -a, 0) -- plank i faces the centre
		local wallHeight = D - 0.08
		piece("CupWall", Vector3.new(0.04, wallHeight, chord), frame * spin * CFrame.new(R - 0.02, -0.08 - wallHeight / 2, 0), DARK, model)
		local rimH = CupGeometry.RIM_HEIGHT
		piece("CupRim", Vector3.new(CupGeometry.RIM_WIDTH, rimH, chord), frame * spin * CFrame.new(R - CupGeometry.RIM_WIDTH / 2, CupGeometry.RIM_RAISE - rimH / 2, 0), WHITE, model)
	end
	model.Parent = options.Parent

	-- Is the hole open? A ray down the middle should reach the pocket floor.
	local openParams = rayParams({ model, table.unpack(exclude) })
	local down = workspace:Raycast(point + normal * 3, -normal * (D + 4), openParams)
	local open = down == nil or (point - down.Position):Dot(normal) > D - 0.15
	if not open then
		local hitName = if down then down.Instance:GetFullName() else "?"
		warnCup(options.Label, `the green is solid at the pin ({hitName}): drawing a dark cup on top of it instead of a real hole`)
		local shade = piece("CupShade", Vector3.new(0.02, 2 * R - 0.04, 2 * R - 0.04), frame * CFrame.new(0, 0.008, 0), DARK, model, true)
		shade.Material = Enum.Material.SmoothPlastic
	end

	-- The plug: raycasts read a flat green across the cup (lie Green).
	local plug = piece("CupPlug", Vector3.new(0.2, 2 * R, 2 * R), frame * CFrame.new(0, -0.1, 0), DARK, model, true)
	plug.Transparency = 1
	plug.CanQuery = true
	plug:SetAttribute(SurfaceMaterials.ATTRIBUTE, "Green")

	return { Model = model, Surface = point, Up = normal, Open = open }
end

return CupBuilder
