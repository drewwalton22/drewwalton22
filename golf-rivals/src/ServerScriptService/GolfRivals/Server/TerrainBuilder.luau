--!strict
-- ROBLOX-ONLY: sculpts Smooth Terrain and creates parts. WHAT it builds is the
-- pure, tested TerrainPlan / CourseRelief.
--[[
	TerrainBuilder.luau  (ServerScriptService.GolfRivals.Server)

	The PROGRAMMATIC TERRAIN SCULPTOR. Builds one hole as real, elevated Smooth
	Terrain at a world origin (each match gets its own arena), and clears it again.

	  build(hole, origin, name) -> Built
	    1. sets the look: Terrain.GrassLength (tall rough), SetMaterialColor for
	       fairway / rough / mud / sand (SurfaceMaterials.MaterialColors)
	    2. SCULPTS the height field with Terrain:WriteVoxels, in 64 x 64-column
	       chunks. For every 4-stud voxel of a column it writes
	           occupancy = clamp((groundTop - voxelBottom) / 4, 0, 1)
	       so the surface is smooth between voxels (elevated tee boxes, rolling
	       fairways, raised / banked greens), with the column's material; above a
	       pond's bed it writes Water up to the pond's level
	    3. places the course parts: smooth-turf green + fringe (tilted), tee box,
	       pin, flag, out-of-bounds stakes (GolfLie attributes on the playable ones)
	    4. cuts the REAL CUP: the green part's Hole is subtracted with
	       SubtractAsync (white liner walls from the cutter's colour, a dark bottom
	       part inside). It runs in the background - until it's done (or if CSG is
	       unavailable) a dark disc marks the cup - so building never waits on it.
	       An invisible CupPlug keeps the physics raycasts reading a flat green.
	  built.destroy()  clears the sculpted region back to Air and removes the parts

	Terrain replicates to every client, so the course players see is exactly the one
	the server raycasts against (TerrainSurface). A typical hole is ~1.5 million
	voxels and sculpts in well under a second, during the hole's fly-over intro.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Config = require(Shared.Config)
local CourseDatabase = require(Shared.CourseDatabase)
local SurfaceMaterials = require(Shared.SurfaceMaterials)
local TerrainPlan = require(Shared.TerrainPlan)

export type Built = {
	Folder: Folder, -- course parts (tee, green, pin, stakes) + decorations
	Origin: Vector3,
	Plan: TerrainPlan.Plan,
	destroy: () -> (),
}

local TerrainBuilder = {}

local VOXEL = 4
local CHUNK = 64 -- columns per chunk side (256 studs)
local CLEAR_TILE = 512

local function material(name: string): Enum.Material
	local ok, value = pcall(function(): any
		return (Enum.Material :: any)[name]
	end)
	return if ok and typeof(value) == "EnumItem" then value :: Enum.Material else Enum.Material.Grass
end

-- Position + optional tilt (up vector (-slopeX, 1, -slopeZ)).
local function frameFor(position: Vector3, slopeX: number, slopeZ: number): CFrame
	if slopeX == 0 and slopeZ == 0 then
		return CFrame.new(position)
	end
	local up = Vector3.new(-slopeX, 1, -slopeZ).Unit
	local right = (Vector3.new(1, 0, 0) - up * up.X).Unit
	return CFrame.fromMatrix(position, right, up)
end

local function snapDown(v: number): number
	return math.floor(v / VOXEL) * VOXEL
end

local function snapUp(v: number): number
	return math.ceil(v / VOXEL) * VOXEL
end

-- Terrain look shared by every generated hole.
function TerrainBuilder.applyLook()
	local terrain = workspace.Terrain
	pcall(function()
		terrain.GrassLength = math.clamp(Config.Course.GrassLength, 0.1, 1)
	end)
	for name, rgb in SurfaceMaterials.MaterialColors do
		pcall(function()
			terrain:SetMaterialColor(material(name), Color3.fromRGB(rgb[1], rgb[2], rgb[3]))
		end)
	end
end

-- Sculpt the hole's height field into the region (world, voxel-aligned).
local function sculpt(hole: CourseDatabase.HoleDef, origin: Vector3, minW: Vector3, maxW: Vector3)
	local terrain = workspace.Terrain
	local waterMat, airMat = Enum.Material.Water, Enum.Material.Air
	local materialCache: { [string]: Enum.Material } = {}
	local ny = math.floor((maxW.Y - minW.Y) / VOXEL + 0.5)
	local cx0 = minW.X
	while cx0 < maxW.X do
		local cx1 = math.min(cx0 + CHUNK * VOXEL, maxW.X)
		local cz0 = minW.Z
		while cz0 < maxW.Z do
			local cz1 = math.min(cz0 + CHUNK * VOXEL, maxW.Z)
			local nx = math.floor((cx1 - cx0) / VOXEL + 0.5)
			local nz = math.floor((cz1 - cz0) / VOXEL + 0.5)
			local materials: { { { Enum.Material } } } = table.create(nx)
			local occupancy: { { { number } } } = table.create(nx)
			for ix = 1, nx do
				local matX: { { Enum.Material } } = table.create(ny)
				local occX: { { number } } = table.create(ny)
				for iy = 1, ny do
					matX[iy] = table.create(nz, airMat)
					occX[iy] = table.create(nz, 0)
				end
				materials[ix], occupancy[ix] = matX, occX
				local wx = cx0 + (ix - 0.5) * VOXEL
				for iz = 1, nz do
					local wz = cz0 + (iz - 0.5) * VOXEL
					local column = TerrainPlan.column(hole, wx - origin.X, wz - origin.Z)
					local top = origin.Y + column.Top
					local waterTop = if column.WaterTop then origin.Y + (column.WaterTop :: number) else -math.huge
					local mat = materialCache[column.Material]
					if mat == nil then
						mat = material(column.Material)
						materialCache[column.Material] = mat
					end
					for iy = 1, ny do
						local y0 = minW.Y + (iy - 1) * VOXEL
						local solid = (top - y0) / VOXEL
						if solid > 0 then
							matX[iy][iz] = mat :: Enum.Material
							occX[iy][iz] = math.min(solid, 1)
						elseif y0 < waterTop then
							matX[iy][iz] = waterMat
							occX[iy][iz] = math.clamp((waterTop - y0) / VOXEL, 0, 1)
						else
							break -- air above: already the default
						end
					end
				end
			end
			local region = Region3.new(Vector3.new(cx0, minW.Y, cz0), Vector3.new(cx1, maxW.Y, cz1))
			terrain:WriteVoxels(region, VOXEL, materials, occupancy)
			cz0 = cz1
		end
		cx0 = cx1
	end
end

-- Clear a world box back to air (tiled so no single write is huge).
local function clear(minW: Vector3, maxW: Vector3)
	local terrain = workspace.Terrain
	local size = maxW - minW
	local nx, nz = math.ceil(size.X / CLEAR_TILE), math.ceil(size.Z / CLEAR_TILE)
	local w, d = size.X / nx, size.Z / nz
	for i = 0, nx - 1 do
		for j = 0, nz - 1 do
			local centre = Vector3.new(minW.X + w * (i + 0.5), (minW.Y + maxW.Y) / 2, minW.Z + d * (j + 0.5))
			terrain:FillBlock(CFrame.new(centre), Vector3.new(w, size.Y, d), Enum.Material.Air)
		end
	end
end

-- Cut the cup pocket out of the green (background). `marker` is the temporary
-- dark disc shown until the cut is in place.
local function cutCup(green: Part, spec: TerrainPlan.SurfacePart, pinTop: number, origin: Vector3, marker: BasePart)
	local hole = spec.Hole
	if hole == nil then
		return
	end
	task.spawn(function()
		local cutter = Instance.new("Part")
		cutter.Shape = Enum.PartType.Cylinder
		cutter.Anchored = true
		cutter.Color = Color3.fromRGB(240, 240, 240) -- the cup liner (white walls)
		cutter.Material = Enum.Material.SmoothPlastic
		local height = hole.Depth + 0.6
		cutter.Size = Vector3.new(height, hole.Diameter, hole.Diameter)
		local centre = origin + Vector3.new(hole.X, pinTop - hole.Depth + height / 2, hole.Z)
		cutter.CFrame = frameFor(centre, spec.SlopeX, spec.SlopeZ) * CFrame.Angles(0, 0, math.pi / 2)
		local ok, result = pcall(function(): any
			return green:SubtractAsync({ cutter }, Enum.CollisionFidelity.PreciseConvexDecomposition)
		end)
		cutter:Destroy()
		if not ok or typeof(result) ~= "Instance" or green.Parent == nil then
			return -- keep the solid green + the dark disc marker
		end
		local union = result :: UnionOperation
		union.Name = green.Name
		union.UsePartColor = false -- turf faces stay green, the pocket walls white
		union.Anchored = true
		union.CanCollide = green.CanCollide
		union.CanQuery = green.CanQuery
		union.CanTouch = false
		union.CastShadow = false
		union:SetAttribute(SurfaceMaterials.ATTRIBUTE, green:GetAttribute(SurfaceMaterials.ATTRIBUTE))
		union.Parent = green.Parent
		green:Destroy()
		marker:Destroy()
	end)
end

function TerrainBuilder.build(hole: CourseDatabase.HoleDef, origin: Vector3, name: string): Built
	TerrainBuilder.applyLook()
	local plan = TerrainPlan.build(hole)
	local minW = Vector3.new(snapDown(origin.X + plan.Min.X), snapDown(origin.Y + plan.Min.Y), snapDown(origin.Z + plan.Min.Z))
	local maxW = Vector3.new(snapUp(origin.X + plan.Max.X), snapUp(origin.Y + plan.Max.Y), snapUp(origin.Z + plan.Max.Z))
	clear(minW, maxW) -- anything left from a previous hole in this arena
	sculpt(hole, origin, minW, maxW)

	local folder = Instance.new("Folder")
	folder.Name = name
	local holeSpecs: { [Part]: TerrainPlan.SurfacePart } = {}
	for _, spec in plan.Parts do
		local part = Instance.new("Part")
		part.Name = spec.Name
		part.Anchored = true
		part.CanCollide = spec.CanCollide
		part.CanQuery = spec.CanQuery
		part.CanTouch = false
		part.CastShadow = spec.Shape ~= "Disc"
		part.Color = Color3.fromRGB(spec.Color[1], spec.Color[2], spec.Color[3])
		part.Material = material(spec.Material)
		part.Transparency = spec.Transparency
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Size = Vector3.new(spec.SX, spec.SY, spec.SZ)
		local frame = frameFor(origin + Vector3.new(spec.X, spec.Y, spec.Z), spec.SlopeX, spec.SlopeZ)
		if spec.Shape == "Disc" then
			part.Shape = Enum.PartType.Cylinder
			part.CFrame = frame * CFrame.Angles(0, 0, math.pi / 2) -- cylinder axis (X) -> vertical
		else
			part.CFrame = frame
		end
		if spec.Lie then
			part:SetAttribute(SurfaceMaterials.ATTRIBUTE, spec.Lie)
		end
		part.Parent = folder
		if spec.Hole then
			holeSpecs[part] = spec
		end
	end
	folder.Parent = workspace
	-- Real cups: a dark disc marks each cup until its pocket is cut.
	for green, spec in holeSpecs do
		local hole = spec.Hole :: { X: number, Z: number, Diameter: number, Depth: number }
		local marker = Instance.new("Part")
		marker.Name = "CupMarker"
		marker.Shape = Enum.PartType.Cylinder
		marker.Anchored = true
		marker.CanCollide = false
		marker.CanQuery = false
		marker.CanTouch = false
		marker.CastShadow = false
		marker.Color = Color3.fromRGB(14, 14, 16)
		marker.Size = Vector3.new(0.04, hole.Diameter, hole.Diameter)
		marker.CFrame = frameFor(origin + Vector3.new(hole.X, plan.Pin.Y + 0.02, hole.Z), spec.SlopeX, spec.SlopeZ) * CFrame.Angles(0, 0, math.pi / 2)
		marker.Parent = folder
		cutCup(green, spec, plan.Pin.Y, origin, marker)
	end

	local destroyed = false
	return {
		Folder = folder,
		Origin = origin,
		Plan = plan,
		destroy = function()
			if destroyed then
				return
			end
			destroyed = true
			folder:Destroy()
			clear(minW, maxW)
		end,
	}
end

return TerrainBuilder
