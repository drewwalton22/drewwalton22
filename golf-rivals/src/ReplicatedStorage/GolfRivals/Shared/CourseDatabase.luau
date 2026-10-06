--!strict
--[[
	CourseDatabase.luau  (ReplicatedStorage.GolfRivals.Shared)

	The golf course as PURE DATA. Each hole is described by simple 2D shapes in a
	hole frame (metres): the tee sits at (X, Z) = (0, 0) and the hole runs
	roughly toward +X, with +Z to the golfer's right when facing +X.

	Shapes (checked in priority order by CourseTerrain):
	    Water    circles      - hazard: ball is lost, 1 penalty stroke, replay
	    Green    circles      - putting surface; carries the green's slope
	    Bunkers  circles      - sand
	    Tee      a small circle at the tee box (beats fairway)
	    Fairway  capsules     - a line segment with a half-width (a "stadium")
	    (anything else)       - rough, inside Bounds; outside Bounds = out of bounds

	Because lies come from geometry (not raycasts), the server can simulate any
	shot without a 3D map, results are deterministic, and a later visual course
	builder can simply read these same shapes to place parts.

	Slopes: GreenSlope = (dh/dx, dh/dz) on the green, dimensionless
	(0.02 = 2%). Positive dh/dx means the green rises toward +X, so balls roll
	back toward the tee side. Height is otherwise flat.

	Distances here are authored in YARDS for readability via `yd()` and stored in
	metres.
]]

local Config = require(script.Parent.Config)

export type Point = { X: number, Z: number }
export type Circle = { X: number, Z: number, R: number }
export type Capsule = { AX: number, AZ: number, BX: number, BZ: number, HalfWidth: number }
export type Bounds = { MinX: number, MaxX: number, MinZ: number, MaxZ: number }

export type HoleDef = {
	Id: number,
	Name: string,
	Par: number,
	Tee: Point,
	Pin: Point,
	Fairway: { Capsule },
	Greens: { Circle },
	Bunkers: { Circle },
	Water: { Circle },
	GreenSlope: Point, -- X = dh/dx, Z = dh/dz
	Bounds: Bounds,
}

local CourseDatabase = {}

local YD = Config.Physics.YardsToMeters
local function yd(yards: number): number
	return yards * YD
end

local function circle(x: number, z: number, r: number): Circle
	return { X = yd(x), Z = yd(z), R = yd(r) }
end

local function capsule(ax: number, az: number, bx: number, bz: number, halfWidth: number): Capsule
	return { AX = yd(ax), AZ = yd(az), BX = yd(bx), BZ = yd(bz), HalfWidth = yd(halfWidth) }
end

local function bounds(minX: number, maxX: number, minZ: number, maxZ: number): Bounds
	return { MinX = yd(minX), MaxX = yd(maxX), MinZ = yd(minZ), MaxZ = yd(maxZ) }
end

local holes: { HoleDef } = {
	{
		Id = 1, Name = "Opening Drive", Par = 4,
		Tee = { X = 0, Z = 0 }, Pin = { X = yd(380), Z = 0 },
		Fairway = { capsule(35, 0, 335, 0, 19) },
		Greens = { circle(380, 0, 15) },
		Bunkers = { circle(255, -24, 9), circle(372, -22, 7) },
		Water = {},
		GreenSlope = { X = 0.02, Z = 0.012 },
		Bounds = bounds(-25, 430, -70, 70),
	},
	{
		Id = 2, Name = "Over the Pond", Par = 3,
		Tee = { X = 0, Z = 0 }, Pin = { X = yd(165), Z = yd(4) },
		Fairway = { capsule(0, 0, 10, 0, 8) },
		Greens = { circle(165, 4, 14) },
		Bunkers = { circle(150, -18, 7), circle(182, 22, 7) },
		Water = { circle(95, 0, 42) },
		GreenSlope = { X = 0, Z = -0.025 },
		Bounds = bounds(-20, 215, -70, 70),
	},
	{
		Id = 3, Name = "Dogleg Right", Par = 5,
		Tee = { X = 0, Z = 0 }, Pin = { X = yd(480), Z = yd(190) },
		Fairway = { capsule(35, 0, 300, 0, 20), capsule(300, 0, 450, 170, 20) },
		Greens = { circle(480, 190, 15) },
		Bunkers = { circle(290, -26, 9), circle(470, 172, 7) },
		Water = { circle(420, 90, 12) },
		GreenSlope = { X = -0.015, Z = 0.02 },
		Bounds = bounds(-25, 540, -70, 260),
	},
	{
		Id = 4, Name = "Dogleg Left", Par = 4,
		Tee = { X = 0, Z = 0 }, Pin = { X = yd(360), Z = yd(-180) },
		Fairway = { capsule(35, 0, 230, 0, 19), capsule(230, 0, 340, -165, 19) },
		Greens = { circle(360, -180, 14) },
		Bunkers = { circle(250, 18, 9), circle(345, -197, 7) },
		Water = {},
		GreenSlope = { X = 0.018, Z = -0.01 },
		Bounds = bounds(-25, 430, -250, 70),
	},
	{
		Id = 5, Name = "Pitch Perfect", Par = 3,
		Tee = { X = 0, Z = 0 }, Pin = { X = yd(140), Z = 0 },
		Fairway = { capsule(0, 0, 8, 0, 8) },
		Greens = { circle(140, 0, 12) },
		Bunkers = { circle(125, -15, 7), circle(155, 15, 7), circle(140, -25, 6) },
		Water = {},
		GreenSlope = { X = 0.02, Z = 0.02 },
		Bounds = bounds(-20, 190, -60, 60),
	},
	{
		Id = 6, Name = "Water Down the Left", Par = 4,
		Tee = { X = 0, Z = 0 }, Pin = { X = yd(350), Z = 0 },
		Fairway = { capsule(35, 0, 300, 0, 17) },
		Greens = { circle(350, 0, 14) },
		Bunkers = { circle(342, 22, 7) },
		Water = { circle(140, -38, 20), circle(200, -40, 22), circle(260, -38, 20) },
		GreenSlope = { X = 0, Z = -0.02 },
		Bounds = bounds(-25, 400, -90, 70),
	},
}

CourseDatabase.Holes = holes

-- The hole at `index`, wrapping around so any index is valid.
function CourseDatabase.hole(index: number): HoleDef
	return holes[(index - 1) % #holes + 1]
end

-- Straight-line tee-to-pin distance in yards (the number printed on the scorecard).
function CourseDatabase.yards(hole: HoleDef): number
	local dx, dz = hole.Pin.X - hole.Tee.X, hole.Pin.Z - hole.Tee.Z
	return math.sqrt(dx * dx + dz * dz) / YD
end

-- `count` consecutive holes starting at `startIndex` (wrapping).
function CourseDatabase.sequence(startIndex: number, count: number): { HoleDef }
	local result: { HoleDef } = {}
	for i = 0, count - 1 do
		table.insert(result, CourseDatabase.hole(startIndex + i))
	end
	return result
end

return CourseDatabase
