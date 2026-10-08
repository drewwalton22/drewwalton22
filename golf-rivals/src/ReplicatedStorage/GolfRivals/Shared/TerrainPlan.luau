--!strict
--[[
	TerrainPlan.luau  (ReplicatedStorage.GolfRivals.Shared)

	Turns a hole into a SMOOTH TERRAIN SCULPTING PLAN. The server's TerrainBuilder
	executes it with Terrain:WriteVoxels; this module only decides WHAT goes WHERE,
	so it is pure and tested offline.

	  column(hole, x, z)   for one vertical column of terrain (studs, relative to the
	                       course origin): the ground top (CourseRelief's height
	                       field), its material, and the water surface above it
	                       (ponds) - TerrainBuilder fills each 4-stud voxel from that
	  build(hole)          the region to sculpt / clear, plus the PARTS a course
	                       needs: smooth-turf green (tilted to the green's slope) on
	                       a fringe ring, the tee box, a REAL CUP (the green part
	                       carries a `Hole` that TerrainBuilder cuts out of it with
	                       SubtractAsync: white liner walls, a dark bottom, an
	                       invisible "CupPlug" so raycasts still read a flat green),
	                       a thin flagstick centred in the cup (no collision), and
	                       white OUT-OF-BOUNDS stakes along the bounds and OB zones

	UNDER THE GREEN the terrain is carved GREEN_CARVE studs below the green's plane,
	so the smooth turf part is the only surface there (no grass poking through it
	and room for the cup's pocket).

	MATERIALS (SurfaceMaterials.BuildMaterials)
	  fairway / tee / under the green  LeafyGrass   short turf, no grass blades
	  rough + beyond the bounds        Grass        tall animated blades
	  bunkers                          Sand
	  ponds                            Mud bed under Water voxels
	  OB zones inside the bounds       Ground       (a dirt road)

	UNITS: studs relative to the origin (hole metres x STUDS_PER_METER), the same
	frame as CourseLayout / CourseView.
]]

local CourseDatabase = require(script.Parent.CourseDatabase)
local CourseLayout = require(script.Parent.CourseLayout)
local CourseRelief = require(script.Parent.CourseRelief)
local CourseTerrain = require(script.Parent.CourseTerrain)
local SurfaceMaterials = require(script.Parent.SurfaceMaterials)
local Types = require(script.Parent.Types)

export type Column = {
	Top: number, -- studs: ground surface
	Material: string, -- Enum.Material name of the ground
	WaterTop: number?, -- studs: water surface (nil = dry)
}

export type SurfacePart = {
	Name: string,
	Shape: "Disc" | "Block",
	Lie: Types.LieId?, -- GolfLie attribute (nil for decoration like the flag)
	X: number, Y: number, Z: number,
	SX: number, SY: number, SZ: number, -- Disc: SX = thickness, SY = SZ = diameter
	SlopeX: number,
	SlopeZ: number,
	Color: Types.RGB,
	Material: string,
	CanCollide: boolean,
	CanQuery: boolean,
	Transparency: number,
	-- A cup pocket to cut out of this part (studs, same frame as X / Z).
	Hole: { X: number, Z: number, Diameter: number, Depth: number }?,
}

export type Plan = {
	Parts: { SurfacePart },
	-- Region to sculpt / clear (studs, relative to origin).
	Min: { X: number, Y: number, Z: number },
	Max: { X: number, Y: number, Z: number },
	Tee: { X: number, Y: number, Z: number },
	Pin: { X: number, Y: number, Z: number },
}

local TerrainPlan = {}

local SPM = CourseLayout.STUDS_PER_METER
local M = SurfaceMaterials.BuildMaterials

TerrainPlan.GROUND_THICKNESS = 12 -- studs of soil under the lowest surface
TerrainPlan.APRON = 140 -- studs sculpted beyond the bounds
TerrainPlan.HEADROOM = 16 -- studs of air cleared above the highest surface
TerrainPlan.GREEN_PART_THICKNESS = 2.2 -- the turf part (deep enough for the cup pocket)
TerrainPlan.GREEN_CARVE = 1.8 -- studs the terrain under a green sits below its plane
TerrainPlan.CUP_DEPTH = 0.9 -- studs: depth of the cup pocket (> the ball's diameter)
TerrainPlan.GREEN_LIFT = 0.12 -- studs the turf's top sits above the green plane
TerrainPlan.FRINGE = 1.2 -- metres of fringe ring around the green
TerrainPlan.CUP_DIAMETER = CourseLayout.CUP_DIAMETER -- studs: the VISUAL cup
TerrainPlan.STAKE_SPACING = 48 -- studs between out-of-bounds stakes
TerrainPlan.TEE_RADIUS = CourseRelief.TEE_RADIUS -- metres

local function surfacePart(name: string, shape: "Disc" | "Block", lie: Types.LieId?, x: number, y: number, z: number, sx: number, sy: number, sz: number, slopeX: number, slopeZ: number, color: Types.RGB, material: string, solid: boolean): SurfacePart
	return {
		Name = name, Shape = shape, Lie = lie, X = x, Y = y, Z = z, SX = sx, SY = sy, SZ = sz, SlopeX = slopeX, SlopeZ = slopeZ,
		Color = color, Material = material, CanCollide = solid, CanQuery = solid, Transparency = 0,
	}
end

local function inZone(zone: CourseDatabase.Bounds, x: number, z: number): boolean
	return x >= zone.MinX and x <= zone.MaxX and z >= zone.MinZ and z <= zone.MaxZ
end

-- One column at (x, z) studs.
function TerrainPlan.column(hole: CourseDatabase.HoleDef, x: number, z: number): Column
	local xm, zm = x / SPM, z / SPM
	local ground = CourseRelief.ground(hole, xm, zm)
	local water = CourseRelief.waterAt(hole, xm, zm)
	local material: string
	local b = hole.Bounds
	local outside = xm < b.MinX or xm > b.MaxX or zm < b.MinZ or zm > b.MaxZ
	local zones: { CourseDatabase.Bounds } = hole.OutOfBounds or {}
	local road = false
	for _, zone in zones do
		if inZone(zone, xm, zm) then
			road = true
		end
	end
	if water and water > ground then
		material = M.WaterBed
	elseif outside then
		material = M.Apron
	elseif road then
		material = M.OutOfBounds
	else
		local lie = CourseTerrain.lieAt(hole, xm, zm)
		material = if lie == "Fairway" then M.Fairway
			elseif lie == "Green" then M.GreenBase
			elseif lie == "Tee" then M.TeeBase
			elseif lie == "Sand" then M.Sand
			elseif lie == "Water" then M.WaterBed
			else M.Rough
		-- A short-turf collar just outside the green (the fringe) so the bank
		-- around it isn't tall grass right at the putting surface.
		if lie == "Rough" then
			for _, green in hole.Greens do
				if (xm - green.X) ^ 2 + (zm - green.Z) ^ 2 <= (green.R + TerrainPlan.FRINGE + 1) ^ 2 then
					material = M.Fairway
				end
			end
		end
	end
	local top = ground * SPM
	-- Under a green: carve below the turf part so only the smooth part shows.
	if not (water and water > ground) then
		for i, green in hole.Greens do
			if (xm - green.X) ^ 2 + (zm - green.Z) ^ 2 <= green.R * green.R then
				top = math.min(top, CourseRelief.greenPlane(hole, i, xm, zm) * SPM - TerrainPlan.GREEN_CARVE)
			end
		end
	end
	return {
		Top = top,
		Material = material,
		WaterTop = if water and water > ground then water * SPM else nil,
	}
end

function TerrainPlan.build(hole: CourseDatabase.HoleDef): Plan
	local parts: { SurfacePart } = {}
	local b = hole.Bounds
	local apron = TerrainPlan.APRON
	local minX, maxX, minZ, maxZ = b.MinX * SPM - apron, b.MaxX * SPM + apron, b.MinZ * SPM - apron, b.MaxZ * SPM + apron

	-- Height range of the whole sculpt (coarse scan).
	local lo, hi = CourseRelief.range(hole, minX / SPM, maxX / SPM, minZ / SPM, maxZ / SPM, 6)
	lo, hi = lo * SPM, hi * SPM

	-- Greens: a tilted smooth-turf disc on a slightly larger fringe ring.
	local gx, gz = hole.GreenSlope.X, hole.GreenSlope.Z
	local thickness = TerrainPlan.GREEN_PART_THICKNESS
	for i, green in hole.Greens do
		local x, z, r = green.X * SPM, green.Z * SPM, green.R * SPM
		local plane = CourseRelief.greenPlane(hole, i, green.X, green.Z) * SPM
		local fringe = r + TerrainPlan.FRINGE * SPM
		table.insert(parts, surfacePart(`Fringe_{i}`, "Disc", nil, x, plane + TerrainPlan.GREEN_LIFT - 0.05 - thickness / 2, z, thickness, fringe * 2, fringe * 2, gx, gz, SurfaceMaterials.Turf.Fringe.Color, SurfaceMaterials.Turf.Fringe.Material, false))
		table.insert(parts, surfacePart(`Green_{i}`, "Disc", "Green", x, plane + TerrainPlan.GREEN_LIFT - thickness / 2, z, thickness, r * 2, r * 2, gx, gz, SurfaceMaterials.Turf.Green.Color, SurfaceMaterials.Turf.Green.Material, true))
	end

	-- Tee box: a flat turf disc on the raised tee plateau.
	local teeX, teeZ = hole.Tee.X * SPM, hole.Tee.Z * SPM
	local teeTop = CourseRelief.teeTop(hole) * SPM + 0.2
	local teeDiameter = TerrainPlan.TEE_RADIUS * SPM * 2
	table.insert(parts, surfacePart("TeeBox", "Disc", "Tee", teeX, teeTop - 0.3, teeZ, 0.6, teeDiameter, teeDiameter, 0, 0, SurfaceMaterials.Turf.Tee.Color, SurfaceMaterials.Turf.Tee.Material, true))

	-- Pin: cup (with a white rim), pole, flag - ignored by raycasts.
	local pinX, pinZ = hole.Pin.X * SPM, hole.Pin.Z * SPM
	local pinTop = TerrainPlan.GREEN_LIFT
	if hole.Greens[1] then
		pinTop += CourseRelief.greenPlane(hole, 1, hole.Pin.X, hole.Pin.Z) * SPM
	else
		pinTop += CourseRelief.ground(hole, hole.Pin.X, hole.Pin.Z) * SPM
	end
	local H = CourseLayout.PIN_HEIGHT
	local function decor(name: string, shape: "Disc" | "Block", x: number, y: number, z: number, sx: number, sy: number, sz: number, slopeX: number, slopeZ: number, color: Types.RGB, material: string)
		table.insert(parts, surfacePart(name, shape, nil, x, y, z, sx, sy, sz, slopeX, slopeZ, color, material, false))
	end
	local cup = TerrainPlan.CUP_DIAMETER
	-- The cup: cut into the green part (its Hole), a dark bottom inside the pocket,
	-- and an invisible plug at the surface so the physics raycasts still see green.
	for _, part in parts do
		if part.Name == "Green_1" then
			part.Hole = { X = pinX, Z = pinZ, Diameter = cup, Depth = TerrainPlan.CUP_DEPTH }
		end
	end
	decor("CupBottom", "Disc", pinX, pinTop - TerrainPlan.CUP_DEPTH + 0.06, pinZ, 0.05, cup - 0.04, cup - 0.04, gx, gz, { 14, 14, 16 }, "SmoothPlastic")
	local plug = surfacePart("CupPlug", "Disc", "Green", pinX, pinTop - 0.1, pinZ, 0.2, cup, cup, gx, gz, SurfaceMaterials.Turf.Green.Color, SurfaceMaterials.Turf.Green.Material, false)
	plug.CanQuery = true -- raycasts hit it (flat green); nothing collides with it
	plug.Transparency = 1
	table.insert(parts, plug)
	-- Flagstick: thin, centred in the cup, standing on the cup's bottom.
	decor("PinPole", "Block", pinX, pinTop - TerrainPlan.CUP_DEPTH + H / 2, pinZ, 0.14, H + TerrainPlan.CUP_DEPTH, 0.14, 0, 0, { 245, 245, 245 }, "SmoothPlastic")
	decor("PinFlag", "Block", pinX + 0.85, pinTop + H - 0.7, pinZ, 1.6, 1.1, 0.06, 0, 0, { 230, 50, 60 }, "Fabric")

	-- Out-of-bounds stakes: around the bounds and around each OB zone.
	local stakeCount = 0
	local function stakesAround(zone: CourseDatabase.Bounds)
		local x0, x1, z0, z1 = zone.MinX * SPM, zone.MaxX * SPM, zone.MinZ * SPM, zone.MaxZ * SPM
		local corners = { { x0, z0 }, { x1, z0 }, { x1, z1 }, { x0, z1 } }
		for c = 1, 4 do
			local a, e = corners[c], corners[c % 4 + 1]
			local length = math.sqrt((e[1] - a[1]) ^ 2 + (e[2] - a[2]) ^ 2)
			local n = math.max(1, math.floor(length / TerrainPlan.STAKE_SPACING))
			for k = 0, n - 1 do
				local t = k / n
				local sx, sz = a[1] + (e[1] - a[1]) * t, a[2] + (e[2] - a[2]) * t
				local ground = TerrainPlan.column(hole, sx, sz)
				local top = if ground.WaterTop then ground.WaterTop :: number else ground.Top
				stakeCount += 1
				decor(`OBStake_{stakeCount}`, "Block", sx, top + 1.6, sz, 0.45, 3.6, 0.45, 0, 0, { 245, 245, 245 }, "SmoothPlastic")
			end
		end
	end
	stakesAround(b)
	local zones: { CourseDatabase.Bounds } = hole.OutOfBounds or {}
	for _, zone in zones do
		stakesAround(zone)
	end

	return {
		Parts = parts,
		Min = { X = minX, Y = lo - TerrainPlan.GROUND_THICKNESS, Z = minZ },
		Max = { X = maxX, Y = hi + TerrainPlan.HEADROOM, Z = maxZ },
		Tee = { X = teeX, Y = teeTop, Z = teeZ },
		Pin = { X = pinX, Y = pinTop, Z = pinZ },
	}
end

return TerrainPlan
