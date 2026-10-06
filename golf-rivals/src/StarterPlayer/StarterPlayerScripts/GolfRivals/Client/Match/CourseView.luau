--!strict
-- ROBLOX-ONLY: builds parts / raycasts the replicated Smooth Terrain.
--[[
	CourseView.luau  (Client/Match)

	One hole as the client sees it, whatever the server built (snapshot.Course.Mode):

	  "Terrain"  the server sculpted the hole in Smooth Terrain (TerrainCourse) and
	             decorated it (MapDecorator); it replicates by itself, so the client
	             builds nothing and reads ground heights by raycast (TerrainSurface)
	  "Mapped"   a hand-built hole from Workspace.GolfCourses - same as Terrain
	  "Parts"    the classic flat-part hole, built locally (CourseBuilder)

	Everything uses the hole frame (metres) the server simulates in:
	    world = Origin + Vector3.new(x, y, z) * STUDS_PER_METER
	so ball samples, rigs and the aim reticle line up with the real ground, hills
	and all.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local CourseDatabase = require(Shared.CourseDatabase)
local CourseLayout = require(Shared.CourseLayout)
local CourseTerrain = require(Shared.CourseTerrain)
local ShotPhysics = require(Shared.ShotPhysics)
local TerrainSurface = require(Shared.TerrainSurface)

local CourseBuilder = require(script.Parent.CourseBuilder)

export type View = {
	Mode: string,
	Hole: CourseDatabase.HoleDef,
	Origin: Vector3,
	Folder: Folder, -- client-side objects (balls, reticle) live here
	Tee: Vector3, -- world, on the ground
	Pin: Vector3,
	Terrain: ShotPhysics.Terrain, -- hole frame, for the aim guide
	Include: { Instance }, -- course parts that rays may hit (besides Terrain)
	toWorld: (x: number, y: number, z: number) -> Vector3,
	toCourse: (world: Vector3) -> (number, number),
	ground: (x: number, z: number) -> Vector3, -- world point on the ground
	refresh: () -> (), -- forget cached heights (terrain still streaming in)
	destroy: () -> (),
}

local CourseView = {}

local SPM = CourseLayout.STUDS_PER_METER

-- The HoleDef for a snapshot: the generated holes are in CourseDatabase; a
-- hand-built hole is described by the snapshot itself.
function CourseView.holeFor(snapshot: any): CourseDatabase.HoleDef
	for _, candidate in CourseDatabase.Holes do
		if candidate.Id == snapshot.Hole.Id then
			return candidate
		end
	end
	local h = snapshot.Hole
	local pin = { X = h.Pin.X, Z = h.Pin.Z }
	local bounds = if snapshot.Course and snapshot.Course.Bounds
		then snapshot.Course.Bounds
		else { MinX = math.min(0, pin.X) - 45, MaxX = math.max(0, pin.X) + 45, MinZ = math.min(0, pin.Z) - 45, MaxZ = math.max(0, pin.Z) + 45 }
	return {
		Id = h.Id,
		Name = h.Name,
		Par = h.Par,
		Tee = { X = h.Tee.X, Z = h.Tee.Z },
		Pin = pin,
		Fairway = {},
		Greens = { { X = pin.X, Z = pin.Z, R = 12 } },
		Bunkers = {},
		Water = {},
		GreenSlope = { X = 0, Z = 0 },
		Bounds = bounds,
	}
end

function CourseView.build(snapshot: any): View
	local hole = CourseView.holeFor(snapshot)
	local info = snapshot.Course or {}
	local mode: string = if type(info.Mode) == "string" then info.Mode else "Parts"
	local o = info.Origin
	local origin = if type(o) == "table" then Vector3.new(o.X, o.Y, o.Z) else Vector3.new(30000 + (snapshot.MatchId or 0) * 6000, 0, 0)

	local function toWorld(x: number, y: number, z: number): Vector3
		return origin + Vector3.new(x * SPM, y * SPM, z * SPM)
	end
	local function toCourse(world: Vector3): (number, number)
		local d = world - origin
		return d.X / SPM, d.Z / SPM
	end

	if mode == "Parts" then
		local built = CourseBuilder.build(hole, origin)
		local terrain = CourseTerrain.forHole(hole)
		return {
			Mode = mode,
			Hole = hole,
			Origin = origin,
			Folder = built.Folder,
			Tee = built.Tee,
			Pin = built.Pin,
			Terrain = terrain,
			Include = {},
			toWorld = toWorld,
			toCourse = toCourse,
			ground = function(x: number, z: number): Vector3
				return toWorld(x, terrain.heightAt(x, z), z)
			end,
			refresh = function() end,
			destroy = built.destroy,
		}
	end

	-- Terrain / Mapped: the server's world is already here; just measure it.
	local include: { Instance } = {}
	if typeof(info.Container) == "Instance" then
		table.insert(include, info.Container :: Instance)
	end
	local surface = TerrainSurface.new({ Origin = origin, Include = include, Fallback = CourseTerrain.forHole(hole) })
	local folder = Instance.new("Folder")
	folder.Name = `Hole{hole.Id}_Client`
	folder.Parent = workspace
	local function ground(x: number, z: number): Vector3
		return Vector3.new(origin.X + x * SPM, surface.worldHeight(x, z), origin.Z + z * SPM)
	end
	return {
		Mode = mode,
		Hole = hole,
		Origin = origin,
		Folder = folder,
		Tee = ground(hole.Tee.X, hole.Tee.Z),
		Pin = ground(hole.Pin.X, hole.Pin.Z),
		Terrain = surface,
		Include = include,
		toWorld = toWorld,
		toCourse = toCourse,
		ground = ground,
		refresh = surface.clearCache,
		destroy = function()
			folder:Destroy()
		end,
	}
end

return CourseView
