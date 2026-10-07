--!strict
--[[
	CourseLayout.luau  (ReplicatedStorage.GolfRivals.Shared)

	Turns a HoleDef (pure 2D shapes in metres) into a list of 3D part specs (studs)
	that the client's CourseBuilder instantiates. Pure data in, pure data out, so the
	geometry is testable offline and the builder is a dumb loop.

	FRAME   hole (x, z) metres -> world (X, Z) studs, world Y = height.
	        Both frames are right-handed with +Z to the golfer's right when facing +X,
	        so a hole renders exactly as the physics sees it.

	SHAPES  Block : axis-aligned box rotated by YawDeg about Y. For CFrame.Angles(0,
	                yaw, 0) the box's local +X maps to (cos yaw, -sin yaw) in (X, Z);
	                the capsule code sets yaw = atan2(-dz, dx) so the long side runs
	                along the segment.
	        Disc  : flat cylinder, vertical axis. SX = thickness, SY = SZ = diameter
	                (a Roblox cylinder's axis is its local X; the builder rolls it 90
	                degrees so it lies flat).
	        Ball  : sphere, SX = SY = SZ = diameter.

	LAYERS  Each surface sits a hair above the one under it so overlaps render in the
	        same priority CourseTerrain uses: rough < fairway < tee < sand < green < water.
	        Big areas are split into tiles <= MaxPartSize (Roblox parts cap at 2048).
]]

local Types = require(script.Parent.Types)
local CourseDatabase = require(script.Parent.CourseDatabase)
local CourseTerrain = require(script.Parent.CourseTerrain)
local Prng = require(script.Parent.Prng)

export type PartSpec = {
	Name: string,
	Shape: "Block" | "Disc" | "Ball",
	X: number, Y: number, Z: number, -- centre, studs
	SX: number, SY: number, SZ: number, -- size, studs
	YawDeg: number,
	Color: Types.RGB,
	Material: string,
	Transparency: number,
	CanCollide: boolean,
}

export type Layout = {
	Parts: { PartSpec },
	Tee: { X: number, Y: number, Z: number },
	Pin: { X: number, Y: number, Z: number },
}

local CourseLayout = {}

CourseLayout.STUDS_PER_METER = 3.5
CourseLayout.MAX_PART_SIZE = 2000
CourseLayout.PIN_HEIGHT = 9 -- studs
-- Visual sizes (studs). The ball is drawn a little bigger than a real one so it
-- reads on screen; the cup is drawn big (arcade style) and the physics capture
-- radius (Config.Physics.CupCaptureRadius) is sized so a ball that drops always
-- visibly overlaps the black hole.
CourseLayout.BALL_DIAMETER = 1.25
CourseLayout.CUP_DIAMETER = 2.2

local SPM = CourseLayout.STUDS_PER_METER

-- Surface heights (top of each layer), studs.
local TOP = { Rough = 0, Fairway = 0.06, Tee = 0.1, Sand = 0.12, Green = 0.14, Water = 0.16 }

local COLORS: { [string]: Types.RGB } = {
	Rough = { 72, 120, 56 },
	OutOfBounds = { 52, 86, 44 },
	Fairway = { 104, 170, 78 },
	Tee = { 120, 184, 92 },
	Sand = { 226, 208, 150 },
	Green = { 128, 200, 98 },
	Water = { 58, 128, 214 },
}

function CourseLayout.toStuds(metres: number): number
	return metres * SPM
end

local function disc(name: string, x: number, z: number, radius: number, top: number, thickness: number, color: Types.RGB, material: string, transparency: number?): PartSpec
	return {
		Name = name, Shape = "Disc", X = x, Y = top - thickness / 2, Z = z,
		SX = thickness, SY = radius * 2, SZ = radius * 2, YawDeg = 0,
		Color = color, Material = material, Transparency = transparency or 0, CanCollide = true,
	}
end

local function block(name: string, x: number, z: number, sx: number, sz: number, top: number, thickness: number, yawDeg: number, color: Types.RGB, material: string): PartSpec
	return {
		Name = name, Shape = "Block", X = x, Y = top - thickness / 2, Z = z,
		SX = sx, SY = thickness, SZ = sz, YawDeg = yawDeg,
		Color = color, Material = material, Transparency = 0, CanCollide = true,
	}
end

-- Axis-aligned rectangle split into tiles no bigger than MAX_PART_SIZE.
local function tiles(parts: { PartSpec }, name: string, minX: number, maxX: number, minZ: number, maxZ: number, top: number, thickness: number, color: Types.RGB, material: string)
	local nx = math.ceil((maxX - minX) / CourseLayout.MAX_PART_SIZE)
	local nz = math.ceil((maxZ - minZ) / CourseLayout.MAX_PART_SIZE)
	local w, d = (maxX - minX) / nx, (maxZ - minZ) / nz
	for i = 0, nx - 1 do
		for j = 0, nz - 1 do
			table.insert(parts, block(`{name}_{i}_{j}`, minX + w * (i + 0.5), minZ + d * (j + 0.5), w, d, top, thickness, 0, color, material))
		end
	end
end

function CourseLayout.build(hole: CourseDatabase.HoleDef): Layout
	local parts: { PartSpec } = {}
	local b = hole.Bounds
	local minX, maxX, minZ, maxZ = b.MinX * SPM, b.MaxX * SPM, b.MinZ * SPM, b.MaxZ * SPM

	-- Out-of-bounds apron (darker), then the playable rough on top of it.
	local margin = 700
	tiles(parts, "OutOfBounds", minX - margin, maxX + margin, minZ - margin, maxZ + margin, -0.3, 4, COLORS.OutOfBounds, "Grass")
	tiles(parts, "Rough", minX, maxX, minZ, maxZ, TOP.Rough, 4, COLORS.Rough, "Grass")

	-- Fairway: a box along each segment plus a disc at each end (rounded caps).
	for i, fairway in hole.Fairway do
		local ax, az, bx, bz = fairway.AX * SPM, fairway.AZ * SPM, fairway.BX * SPM, fairway.BZ * SPM
		local hw = fairway.HalfWidth * SPM
		local dx, dz = bx - ax, bz - az
		local length = math.sqrt(dx * dx + dz * dz)
		if length > 1e-6 then
			table.insert(parts, block(`Fairway_{i}`, (ax + bx) / 2, (az + bz) / 2, length, hw * 2, TOP.Fairway, 1, math.deg(math.atan2(-dz, dx)), COLORS.Fairway, "Grass"))
		end
		table.insert(parts, disc(`FairwayCapA_{i}`, ax, az, hw, TOP.Fairway, 1, COLORS.Fairway, "Grass"))
		table.insert(parts, disc(`FairwayCapB_{i}`, bx, bz, hw, TOP.Fairway, 1, COLORS.Fairway, "Grass"))
	end

	-- Tee box.
	local teeX, teeZ = hole.Tee.X * SPM, hole.Tee.Z * SPM
	table.insert(parts, disc("TeeBox", teeX, teeZ, 3.6 * SPM, TOP.Tee, 1, COLORS.Tee, "Grass"))

	for i, bunker in hole.Bunkers do
		table.insert(parts, disc(`Bunker_{i}`, bunker.X * SPM, bunker.Z * SPM, bunker.R * SPM, TOP.Sand, 1, COLORS.Sand, "Sand"))
	end
	for i, green in hole.Greens do
		table.insert(parts, disc(`Green_{i}`, green.X * SPM, green.Z * SPM, green.R * SPM, TOP.Green, 1, COLORS.Green, "Grass"))
	end
	for i, water in hole.Water do
		table.insert(parts, disc(`Water_{i}`, water.X * SPM, water.Z * SPM, water.R * SPM, TOP.Water, 1, COLORS.Water, "Glass", 0.25))
	end

	-- Pin: cup, pole, flag.
	local pinX, pinZ = hole.Pin.X * SPM, hole.Pin.Z * SPM
	local H = CourseLayout.PIN_HEIGHT
	table.insert(parts, disc("Cup", pinX, pinZ, CourseLayout.CUP_DIAMETER / 2, TOP.Green + 0.02, 0.2, { 12, 12, 14 }, "SmoothPlastic"))
	local pole = block("PinPole", pinX, pinZ, 0.25, 0.25, TOP.Green + H, H, 0, { 240, 240, 240 }, "SmoothPlastic")
	pole.CanCollide = false
	table.insert(parts, pole)
	local flag = block("PinFlag", pinX + 1.4, pinZ, 2.8, 0.1, TOP.Green + H, 1.8, 0, { 230, 50, 60 }, "SmoothPlastic")
	flag.CanCollide = false
	table.insert(parts, flag)

	-- Trees: deterministic per hole; never on the playing surfaces.
	local prng = Prng.new(hole.Id * 977 + 13)
	local planted = 0
	local reach = 100 * 0.9144 * SPM -- how far beyond the bounds the forest extends (studs)
	for _ = 1, 600 do
		if planted >= 140 then
			break
		end
		local x = minX - reach + prng.next() * (maxX - minX + 2 * reach)
		local z = minZ - reach + prng.next() * (maxZ - minZ + 2 * reach)
		local mx, mz = x / SPM, z / SPM
		local inside = CourseTerrain.inBounds(hole, mx, mz)
		local lie = CourseTerrain.lieAt(hole, mx, mz)
		-- Outside the bounds anywhere; inside only in rough and clear of the tee-pin line.
		local ok = not inside
		if inside and lie == "Rough" then
			local lx, lz = pinX - teeX, pinZ - teeZ
			local len = math.sqrt(lx * lx + lz * lz)
			local cross = math.abs((x - teeX) * lz - (z - teeZ) * lx) / len
			ok = cross > 55 * SPM * 0.9144
		end
		if ok then
			planted += 1
			local height = 14 + prng.next() * 12
			local crown = 10 + prng.next() * 8
			local trunk = block(`TreeTrunk_{planted}`, x, z, 1.6, 1.6, height * 0.6, height * 0.6, 0, { 94, 66, 42 }, "Wood")
			local leaves: PartSpec = {
				Name = `TreeCrown_{planted}`, Shape = "Ball", X = x, Y = height * 0.6 + crown * 0.35, Z = z,
				SX = crown, SY = crown, SZ = crown, YawDeg = 0, Color = { 46 + math.floor(prng.next() * 30), 112 + math.floor(prng.next() * 40), 52 }, Material = "Grass",
				Transparency = 0, CanCollide = false,
			}
			table.insert(parts, trunk)
			table.insert(parts, leaves)
		end
	end

	return {
		Parts = parts,
		Tee = { X = teeX, Y = TOP.Tee, Z = teeZ },
		Pin = { X = pinX, Y = TOP.Green, Z = pinZ },
	}
end

return CourseLayout
