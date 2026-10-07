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
	back toward the tee side.

	ELEVATION: holes built from CourseData carry a `Relief` (tee / green
	elevations, the profile along the line of play, raised tees and banked greens,
	rolling mounds). CourseRelief turns it into a 3D height field that the physics,
	the bots, the terrain sculptor and the client all share. A hole without Relief
	is flat (height 0) with only the green tilted - handy for tests.

	OUT OF BOUNDS: outside Bounds, plus any extra OutOfBounds rectangles (a road).

	The hole data itself lives in CourseData (yards / metres, easy to edit); this
	module converts it into HoleDefs in metres.
]]

local Config = require(script.Parent.Config)
local CourseData = require(script.Parent.CourseData)

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
	OutOfBounds: { Bounds }?, -- extra OB zones inside Bounds
	Relief: Relief?, -- nil = flat
	Course: string?, -- "Beginner" | "Intermediate" | "Expert"
}

-- 3D shape of a hole (metres). See CourseData for the meaning of each field.
export type Relief = {
	Profile: { number }, -- ground elevation tee -> green along the line of play (>= 2)
	TeeRaise: number,
	GreenRaise: number,
	Undulation: number,
	Wavelength: number,
	Seed: number,
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

-- CourseData spec (yards / metres, readable) -> HoleDef (metres).
local function fromSpec(spec: CourseData.HoleSpec): HoleDef
	local function circles(list: { { number } }): { Circle }
		local out: { Circle } = {}
		for _, c in list do
			table.insert(out, circle(c[1], c[2], c[3]))
		end
		return out
	end
	local fairways: { Capsule } = {}
	for _, f in spec.Fairway do
		table.insert(fairways, capsule(f[1], f[2], f[3], f[4], f[5]))
	end
	local oob: { Bounds } = {}
	local zones: { { number } } = spec.OutOfBounds or {}
	for _, z in zones do
		table.insert(oob, bounds(z[1], z[2], z[3], z[4]))
	end
	return {
		Id = spec.Id,
		Name = spec.Name,
		Par = spec.Par,
		Course = spec.Course,
		Tee = { X = yd(spec.Tee[1]), Z = yd(spec.Tee[2]) },
		Pin = { X = yd(spec.Pin[1]), Z = yd(spec.Pin[2]) },
		Fairway = fairways,
		Greens = circles(spec.Greens),
		Bunkers = circles(spec.Bunkers),
		Water = circles(spec.Water),
		GreenSlope = { X = spec.GreenSlope[1], Z = spec.GreenSlope[2] },
		Bounds = bounds(spec.Bounds[1], spec.Bounds[2], spec.Bounds[3], spec.Bounds[4]),
		OutOfBounds = if #oob > 0 then oob else nil,
		Relief = {
			Profile = CourseData.profileOf(spec),
			TeeRaise = spec.TeeRaise,
			GreenRaise = spec.GreenRaise,
			Undulation = spec.Undulation,
			Wavelength = spec.Wavelength,
			Seed = spec.Id * 7.31,
		},
	}
end

local holes: { HoleDef } = {}
for _, spec in CourseData.Holes do
	table.insert(holes, fromSpec(spec))
end

CourseDatabase.Holes = holes

-- The hole at `index`, wrapping around so any index is valid.
function CourseDatabase.hole(index: number): HoleDef
	return holes[(index - 1) % #holes + 1]
end

-- Elevation change tee -> green in metres (+ = uphill), 0 for flat holes.
function CourseDatabase.elevationChange(hole: HoleDef): number
	local relief = hole.Relief
	if relief == nil then
		return 0
	end
	return (relief.Profile[#relief.Profile] + relief.GreenRaise) - (relief.Profile[1] + relief.TeeRaise)
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

-- The holes of a named 3-hole course ("Beginner", "Intermediate", "Expert").
function CourseDatabase.course(name: string): { HoleDef }?
	local ids = CourseData.Courses[name]
	if ids == nil then
		return nil
	end
	local result: { HoleDef } = {}
	for _, id in ids do
		for _, hole in holes do
			if hole.Id == id then
				table.insert(result, hole)
			end
		end
	end
	return result
end

return CourseDatabase
