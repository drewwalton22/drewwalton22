--!strict
--[[
	CourseData.luau  (ReplicatedStorage.GolfRivals.Shared)

	THE 9-HOLE COURSE as plain, readable data - modelled on the classic Wii Sports /
	NES Open style 9: three 3-hole courses of rising difficulty
	(Beginner 1-3, Intermediate 4-6, Expert 7-9), par 36, with the signature holes
	of that layout: a straight opener, a par 3 over a pond, a long dogleg par 5, a
	drive off an elevated cliff-top tee, an uphill pitch to a banked green, a long
	hole with water down the left, a valley hole, an island green and a
	double-dogleg finale with a road out of bounds.

	The layouts and elevations are an original approximation in that style (par,
	length, shape and up/down profile), not a measured copy - tune any value here
	and every system follows: CourseDatabase builds the HoleDefs, CourseRelief the
	3D height field, TerrainPlan / TerrainBuilder sculpt Smooth Terrain from it,
	ShotPhysics rolls the ball on it, MiniMap draws it.

	UNITS
	  Positions / sizes: YARDS in the hole frame - the tee at (0, 0), the hole
	  playing toward +X, +Z to the golfer's right.
	  Elevations: METRES above the course datum (0).

	PER HOLE
	  Par, Tee, Pin                    (Distance is derived: tee -> pin, yards)
	  TeeElevation                     ground height under the tee box
	  GreenElevation                   ground height around the green
	  Profile                          optional elevations IN BETWEEN, evenly
	                                   spaced along the line of play (valleys,
	                                   ridges); the full profile is
	                                   { TeeElevation, ...Profile, GreenElevation }
	  TeeRaise / GreenRaise            how far the tee box / green plateau sit above
	                                   their surroundings (elevated tee, banked green)
	  Undulation / Wavelength          rolling fairway mounds (amplitude m, length m)
	  Fairway  { {ax, az, bx, bz, halfWidth} }   capsules, in order of play
	  Greens   { {x, z, r} }           the putting surface (GreenSlope = its tilt)
	  Bunkers  { {x, z, r} }           sunken sand
	  Water    { {x, z, r} }           sunken water (a ball in it is lost: +1 stroke)
	  OutOfBounds { {minX, maxX, minZ, maxZ} }   extra OB zones inside the bounds
	  Bounds   {minX, maxX, minZ, maxZ}           outside = out of bounds
]]

export type HoleSpec = {
	Id: number,
	Name: string,
	Course: "Beginner" | "Intermediate" | "Expert",
	Par: number,
	Tee: { number },
	Pin: { number },
	TeeElevation: number,
	GreenElevation: number,
	Profile: { number }?,
	TeeRaise: number,
	GreenRaise: number,
	Undulation: number,
	Wavelength: number,
	Fairway: { { number } },
	Greens: { { number } },
	GreenSlope: { number },
	Bunkers: { { number } },
	Water: { { number } },
	OutOfBounds: { { number } }?,
	Bounds: { number },
}

local CourseData = {}

CourseData.Holes = {
	-- ===== BEGINNER =======================================================================
	{
		Id = 1, Name = "Opening Drive", Course = "Beginner", Par = 4,
		Tee = { 0, 0 }, Pin = { 380, 0 },
		-- Gentle downhill opener: tee 4 m up, green 1.5 m.
		TeeElevation = 4, GreenElevation = 1.5, Profile = { 3.2, 2.4 },
		TeeRaise = 0.8, GreenRaise = 0.6, Undulation = 0.9, Wavelength = 55,
		Fairway = { { 35, 0, 335, 0, 19 } },
		Greens = { { 380, 0, 15 } }, GreenSlope = { 0.02, 0.012 },
		Bunkers = { { 255, -24, 9 }, { 372, -22, 7 } },
		Water = {},
		Bounds = { -25, 430, -70, 70 },
	},
	{
		Id = 2, Name = "Over the Pond", Course = "Beginner", Par = 3,
		Tee = { 0, 0 }, Pin = { 165, 4 },
		-- Short iron from a raised tee, over a sunken pond, to a banked green.
		TeeElevation = 5, GreenElevation = 3, Profile = { 3.6 },
		TeeRaise = 1.0, GreenRaise = 0.9, Undulation = 0.3, Wavelength = 40,
		Fairway = { { 0, 0, 10, 0, 8 } },
		Greens = { { 165, 4, 14 } }, GreenSlope = { 0, -0.025 },
		Bunkers = { { 150, -18, 7 }, { 182, 22, 7 } },
		Water = { { 95, 0, 42 } },
		Bounds = { -20, 215, -70, 70 },
	},
	{
		Id = 3, Name = "Dogleg Right", Course = "Beginner", Par = 5,
		Tee = { 0, 0 }, Pin = { 480, 190 },
		-- Long par 5 that climbs 7 m to a green on the hill after the corner.
		TeeElevation = 0, GreenElevation = 7, Profile = { 1.2, 2.6, 4.8 },
		TeeRaise = 0.6, GreenRaise = 0.7, Undulation = 1.4, Wavelength = 60,
		Fairway = { { 35, 0, 300, 0, 20 }, { 300, 0, 450, 170, 20 } },
		Greens = { { 480, 190, 15 } }, GreenSlope = { -0.015, 0.02 },
		Bunkers = { { 290, -26, 9 }, { 470, 172, 7 } },
		Water = { { 420, 90, 12 } },
		Bounds = { -25, 540, -70, 260 },
	},
	-- ===== INTERMEDIATE ===================================================================
	{
		Id = 4, Name = "Cliff Top", Course = "Intermediate", Par = 4,
		Tee = { 0, 0 }, Pin = { 360, -180 },
		-- Drive off a tee 14 m up, down into a dogleg-left valley.
		TeeElevation = 14, GreenElevation = 2, Profile = { 6, 3 },
		TeeRaise = 1.2, GreenRaise = 0.6, Undulation = 1.0, Wavelength = 50,
		Fairway = { { 35, 0, 230, 0, 19 }, { 230, 0, 340, -165, 19 } },
		Greens = { { 360, -180, 14 } }, GreenSlope = { 0.018, -0.01 },
		Bunkers = { { 250, 18, 9 }, { 345, -197, 7 } },
		Water = {},
		Bounds = { -25, 430, -250, 70 },
	},
	{
		Id = 5, Name = "Pitch Perfect", Course = "Intermediate", Par = 3,
		Tee = { 0, 0 }, Pin = { 140, 0 },
		-- Uphill wedge to a green raised 1 m on its banks, ringed with sand.
		TeeElevation = 1, GreenElevation = 6, Profile = { 3 },
		TeeRaise = 0.5, GreenRaise = 1.0, Undulation = 0.4, Wavelength = 35,
		Fairway = { { 0, 0, 8, 0, 8 } },
		Greens = { { 140, 0, 12 } }, GreenSlope = { 0.02, 0.02 },
		Bunkers = { { 125, -15, 7 }, { 155, 15, 7 }, { 140, -25, 6 } },
		Water = {},
		Bounds = { -20, 190, -60, 60 },
	},
	{
		Id = 6, Name = "The Long Haul", Course = "Intermediate", Par = 5,
		Tee = { 0, 0 }, Pin = { 475, 0 },
		-- Rolling three-shotter with a chain of ponds down the left.
		TeeElevation = 3, GreenElevation = 4.5, Profile = { 2, 3.5, 2.5 },
		TeeRaise = 0.6, GreenRaise = 0.6, Undulation = 1.6, Wavelength = 65,
		Fairway = { { 35, 0, 420, 0, 17 } },
		Greens = { { 475, 0, 14 } }, GreenSlope = { 0, -0.02 },
		Bunkers = { { 300, 24, 8 }, { 462, 22, 7 } },
		Water = { { 140, -38, 20 }, { 200, -40, 22 }, { 260, -38, 20 }, { 330, -40, 20 } },
		Bounds = { -25, 520, -90, 70 },
	},
	-- ===== EXPERT =========================================================================
	{
		Id = 7, Name = "Valley Run", Course = "Expert", Par = 4,
		Tee = { 0, 0 }, Pin = { 405, -20 },
		-- Down off a 9 m tee into a deep valley, then back up to an 8 m green.
		TeeElevation = 9, GreenElevation = 8, Profile = { 2, 0, 4 },
		TeeRaise = 0.8, GreenRaise = 0.7, Undulation = 0.8, Wavelength = 50,
		Fairway = { { 40, 0, 370, -15, 18 } },
		Greens = { { 405, -20, 14 } }, GreenSlope = { -0.02, 0.01 },
		Bunkers = { { 230, 22, 9 }, { 395, -38, 7 }, { 420, 2, 6 } },
		Water = {},
		Bounds = { -25, 460, -80, 70 },
	},
	{
		Id = 8, Name = "Island Green", Course = "Expert", Par = 3,
		Tee = { 0, 0 }, Pin = { 170, 0 },
		-- All carry: the green is an island in a lake, 4.5 m below the tee.
		TeeElevation = 6, GreenElevation = 1.5,
		TeeRaise = 1.0, GreenRaise = 0.8, Undulation = 0.3, Wavelength = 40,
		Fairway = { { 0, 0, 10, 0, 8 } },
		Greens = { { 170, 0, 13 } }, GreenSlope = { 0.015, -0.015 },
		Bunkers = {},
		Water = { { 170, 0, 30 }, { 120, 0, 22 } },
		Bounds = { -20, 220, -60, 60 },
	},
	{
		Id = 9, Name = "Grand Finale", Course = "Expert", Par = 5,
		Tee = { 0, 0 }, Pin = { 530, -95 },
		-- Double dogleg left round a pond, a road (out of bounds) down the right.
		TeeElevation = 3, GreenElevation = 6, Profile = { 5, 2, 4 },
		TeeRaise = 0.8, GreenRaise = 0.8, Undulation = 1.2, Wavelength = 55,
		Fairway = { { 35, 0, 240, 0, 20 }, { 240, 0, 400, -90, 19 }, { 400, -90, 500, -95, 18 } },
		Greens = { { 530, -95, 15 } }, GreenSlope = { 0.015, 0.018 },
		Bunkers = { { 250, 26, 9 }, { 515, -115, 7 }, { 540, -75, 6 } },
		Water = { { 330, -10, 18 } },
		OutOfBounds = { { 0, 300, 52, 75 } },
		Bounds = { -25, 580, -170, 75 },
	},
} :: { HoleSpec }

CourseData.Courses = {
	Beginner = { 1, 2, 3 },
	Intermediate = { 4, 5, 6 },
	Expert = { 7, 8, 9 },
} :: { [string]: { number } }

function CourseData.totalPar(): number
	local total = 0
	for _, hole in CourseData.Holes do
		total += hole.Par
	end
	return total
end

-- The full elevation profile tee -> green (metres).
function CourseData.profileOf(spec: HoleSpec): { number }
	local profile = { spec.TeeElevation }
	local middle: { number } = spec.Profile or {}
	for _, value in middle do
		table.insert(profile, value)
	end
	table.insert(profile, spec.GreenElevation)
	return profile
end

return CourseData
