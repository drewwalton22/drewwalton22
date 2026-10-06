--!strict
--[[
	TerrainPlan.luau  (ReplicatedStorage.GolfRivals.Shared)

	Turns a hole (pure 2D shapes, CourseDatabase) into a SMOOTH TERRAIN build plan:
	an ordered list of terrain fills plus the few real parts a course needs. The
	server's TerrainCourse executes it with Terrain:FillBlock / FillCylinder; this
	module only decides WHAT goes WHERE, so it is pure and tested offline.

	ORDER (later fills overwrite earlier ones)
	  1. apron      Ground, a margin around the playable area (out of bounds)
	  2. rough      LeafyGrass over the hole's Bounds          (top at y = 0)
	  3. fairways   Grass capsules (box + two round caps)       (top at y = 0)
	  4. bunkers    carved Air, then Sand sunk BunkerDepth below the surface
	  5. greens     carved Air + Grass base, TILTED by the hole's GreenSlope so the
	                real terrain carries the break; a thin green Part (GolfLie =
	                "Green") lies flush on top - raycasts read the green from it
	  6. water      carved Air, then Water WaterDepth below the surface

	PARTS: the tee box (GolfLie = "Tee"), the green surface, and the pin/flag/cup
	(non-collidable, CanQuery false so raycasts ignore them).

	UNITS: studs, relative to the course origin (hole frame metres x STUDS_PER_METER),
	same frame as CourseLayout, so a ball at hole (x, z) sits over world
	origin + (x, ?, z) * STUDS_PER_METER.
]]

local CourseDatabase = require(script.Parent.CourseDatabase)
local CourseLayout = require(script.Parent.CourseLayout)
local SurfaceMaterials = require(script.Parent.SurfaceMaterials)
local Types = require(script.Parent.Types)

export type Fill = {
	Name: string,
	Shape: "Block" | "Cylinder",
	Material: string, -- Enum.Material name ("Air" carves)
	X: number, Y: number, Z: number, -- centre
	SX: number, SY: number, SZ: number, -- Block size (Cylinder: SX = SZ = diameter, SY = height)
	YawDeg: number,
	-- Tilt: the fill's up vector is (-SlopeX, 1, -SlopeZ) normalised (greens).
	SlopeX: number,
	SlopeZ: number,
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
}

export type Plan = {
	Fills: { Fill },
	Parts: { SurfacePart },
	-- Region to clear when the hole is torn down (studs, relative to origin).
	Min: { X: number, Y: number, Z: number },
	Max: { X: number, Y: number, Z: number },
	Tee: { X: number, Y: number, Z: number },
	Pin: { X: number, Y: number, Z: number },
}

local TerrainPlan = {}

local SPM = CourseLayout.STUDS_PER_METER
local M = SurfaceMaterials.BuildMaterials

TerrainPlan.GROUND_THICKNESS = 12 -- studs of soil under the surface
TerrainPlan.APRON = 160 -- studs of out-of-bounds ground around the bounds
TerrainPlan.BUNKER_DEPTH = 1.6 -- studs the sand sits below the surrounding grass
TerrainPlan.WATER_DEPTH = 1.2
TerrainPlan.CARVE_HEIGHT = 8 -- studs of air carved above sunken features
TerrainPlan.GREEN_PART_THICKNESS = 0.4
TerrainPlan.TEE_RADIUS = 3.6 -- metres

local function fill(name: string, shape: "Block" | "Cylinder", material: string, x: number, y: number, z: number, sx: number, sy: number, sz: number, yaw: number?, slopeX: number?, slopeZ: number?): Fill
	return {
		Name = name, Shape = shape, Material = material, X = x, Y = y, Z = z, SX = sx, SY = sy, SZ = sz,
		YawDeg = yaw or 0, SlopeX = slopeX or 0, SlopeZ = slopeZ or 0,
	}
end

-- Ground layer whose TOP is at `top`.
local function slab(name: string, material: string, minX: number, maxX: number, minZ: number, maxZ: number, top: number): Fill
	local t = TerrainPlan.GROUND_THICKNESS
	return fill(name, "Block", material, (minX + maxX) / 2, top - t / 2, (minZ + maxZ) / 2, maxX - minX, t, maxZ - minZ)
end

-- Cylinder (vertical axis) whose top is at `top`.
local function disc(name: string, material: string, x: number, z: number, radius: number, top: number, height: number, slopeX: number?, slopeZ: number?): Fill
	return fill(name, "Cylinder", material, x, top - height / 2, z, radius * 2, height, radius * 2, 0, slopeX, slopeZ)
end

local function surfacePart(name: string, shape: "Disc" | "Block", lie: Types.LieId?, x: number, y: number, z: number, sx: number, sy: number, sz: number, slopeX: number, slopeZ: number, color: Types.RGB, material: string, solid: boolean): SurfacePart
	return {
		Name = name, Shape = shape, Lie = lie, X = x, Y = y, Z = z, SX = sx, SY = sy, SZ = sz, SlopeX = slopeX, SlopeZ = slopeZ,
		Color = color, Material = material, CanCollide = solid, CanQuery = solid, Transparency = 0,
	}
end

function TerrainPlan.build(hole: CourseDatabase.HoleDef): Plan
	local fills: { Fill } = {}
	local parts: { SurfacePart } = {}
	local b = hole.Bounds
	local minX, maxX, minZ, maxZ = b.MinX * SPM, b.MaxX * SPM, b.MinZ * SPM, b.MaxZ * SPM
	local apron = TerrainPlan.APRON

	-- 1-2. Ground: apron, then the playable rough.
	table.insert(fills, slab("Apron", M.Apron, minX - apron, maxX + apron, minZ - apron, maxZ + apron, 0))
	table.insert(fills, slab("Rough", M.Rough, minX, maxX, minZ, maxZ, 0))

	-- 3. Fairways: a box along each segment + round caps (a capsule).
	local t = TerrainPlan.GROUND_THICKNESS
	for i, fairway in hole.Fairway do
		local ax, az, bx, bz = fairway.AX * SPM, fairway.AZ * SPM, fairway.BX * SPM, fairway.BZ * SPM
		local hw = fairway.HalfWidth * SPM
		local dx, dz = bx - ax, bz - az
		local length = math.sqrt(dx * dx + dz * dz)
		if length > 1e-6 then
			table.insert(fills, fill(`Fairway_{i}`, "Block", M.Fairway, (ax + bx) / 2, -t / 2, (az + bz) / 2, length, t, hw * 2, math.deg(math.atan2(-dz, dx))))
		end
		table.insert(fills, disc(`FairwayCapA_{i}`, M.Fairway, ax, az, hw, 0, t))
		table.insert(fills, disc(`FairwayCapB_{i}`, M.Fairway, bx, bz, hw, 0, t))
	end

	-- 4. Bunkers: carve, then sand below the surface.
	local carve = TerrainPlan.CARVE_HEIGHT
	for i, bunker in hole.Bunkers do
		local x, z, r = bunker.X * SPM, bunker.Z * SPM, bunker.R * SPM
		table.insert(fills, disc(`BunkerCarve_{i}`, "Air", x, z, r, carve, carve + TerrainPlan.BUNKER_DEPTH))
		table.insert(fills, disc(`Bunker_{i}`, M.Sand, x, z, r, -TerrainPlan.BUNKER_DEPTH, t))
	end

	-- 5. Greens: tilted base + a flush green surface part.
	local gx, gz = hole.GreenSlope.X, hole.GreenSlope.Z
	for i, green in hole.Greens do
		local x, z, r = green.X * SPM, green.Z * SPM, green.R * SPM
		-- Carve generously above (the high side of the tilt rises r * |slope|).
		local rise = r * math.sqrt(gx * gx + gz * gz)
		table.insert(fills, disc(`GreenCarve_{i}`, "Air", x, z, r * 1.05, carve + rise, carve + rise * 2, gx, gz))
		table.insert(fills, disc(`GreenBase_{i}`, M.GreenBase, x, z, r * 1.05, 0, t, gx, gz))
		local thickness = TerrainPlan.GREEN_PART_THICKNESS
		table.insert(parts, surfacePart(`Green_{i}`, "Disc", "Green", x, 0.15 - thickness / 2, z, thickness, r * 2, r * 2, gx, gz, { 112, 196, 92 }, "Grass", true))
	end

	-- 6. Water: carve, then water below the surface.
	for i, water in hole.Water do
		local x, z, r = water.X * SPM, water.Z * SPM, water.R * SPM
		table.insert(fills, disc(`WaterCarve_{i}`, "Air", x, z, r, carve, carve + TerrainPlan.WATER_DEPTH))
		table.insert(fills, disc(`Water_{i}`, M.Water, x, z, r, -TerrainPlan.WATER_DEPTH, t * 0.5))
	end

	-- Tee box part.
	local teeX, teeZ = hole.Tee.X * SPM, hole.Tee.Z * SPM
	local teeDiameter = TerrainPlan.TEE_RADIUS * SPM * 2
	table.insert(parts, surfacePart("TeeBox", "Disc", "Tee", teeX, 0, teeZ, 0.4, teeDiameter, teeDiameter, 0, 0, { 120, 184, 92 }, "Grass", true)) -- top at 0.2

	-- Pin: cup, pole, flag (ignored by raycasts).
	local pinX, pinZ = hole.Pin.X * SPM, hole.Pin.Z * SPM
	-- The cup sits on the (tilted) green surface: h = 0.15 + g . (pin - green centre).
	local pinTop = 0.15
	local firstGreen = hole.Greens[1]
	if firstGreen then
		pinTop += gx * (pinX - firstGreen.X * SPM) + gz * (pinZ - firstGreen.Z * SPM)
	end
	local H = CourseLayout.PIN_HEIGHT
	local function decor(name: string, shape: "Disc" | "Block", x: number, y: number, z: number, sx: number, sy: number, sz: number, color: Types.RGB, material: string)
		table.insert(parts, surfacePart(name, shape, nil, x, y, z, sx, sy, sz, 0, 0, color, material, false))
	end
	decor("Cup", "Disc", pinX, pinTop + 0.02, pinZ, 0.06, 0.054 * SPM * 2.2, 0.054 * SPM * 2.2, { 20, 20, 20 }, "SmoothPlastic")
	decor("PinPole", "Block", pinX, pinTop + H / 2, pinZ, 0.25, H, 0.25, { 240, 240, 240 }, "SmoothPlastic")
	decor("PinFlag", "Block", pinX + 1.4, pinTop + H - 0.9, pinZ, 2.8, 1.8, 0.1, { 230, 50, 60 }, "Fabric")

	return {
		Fills = fills,
		Parts = parts,
		Min = { X = minX - apron, Y = -TerrainPlan.GROUND_THICKNESS - 4, Z = minZ - apron },
		Max = { X = maxX + apron, Y = TerrainPlan.CARVE_HEIGHT + 24, Z = maxZ + apron },
		Tee = { X = teeX, Y = 0.2, Z = teeZ },
		Pin = { X = pinX, Y = pinTop, Z = pinZ },
	}
end

return TerrainPlan
