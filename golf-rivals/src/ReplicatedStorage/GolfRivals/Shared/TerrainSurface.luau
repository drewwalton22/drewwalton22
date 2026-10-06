--!strict
-- ROBLOX-ONLY: raycasts into the Workspace. The material -> lie / physics rules it
-- applies are the pure, tested SurfaceMaterials module.
--[[
	TerrainSurface.luau  (ReplicatedStorage.GolfRivals.Shared)

	The real 3D world as the Terrain interface ShotPhysics simulates on. Every
	question the physics asks - "how high is the ground here?", "what is the ball
	sitting on?", "which way does it slope?", "how bouncy is it?" - is answered by
	a downward RAYCAST at that point:

	    ray from (x, ProbeTop, z) straight down  ->  hit position, normal, material,
	                                                 and the hit part's GolfLie attribute

	  height   hit.Y, converted to the course frame
	  lie      SurfaceMaterials.lieFor(material, part.GolfLie)  (Smooth Terrain
	           Grass = Fairway, LeafyGrass = Rough, Sand = bunker, Water = water)
	  slope    from the surface normal n:  dh/dx = -n.X / n.Y,  dh/dz = -n.Z / n.Y
	  physics  SurfaceMaterials.physicsFor(material, lie)  (per-material bounce,
	           tangent retention and roll friction)

	Works on generated Smooth Terrain holes (TerrainCourse) AND hand-built maps
	(terrain + MeshParts). Only Terrain and parts inside `Include` are hit, so
	players, balls and decorations never interfere. Water is detected (rays do not
	ignore water). Results are cached on a 0.25 m grid - a shot asks the same cells
	thousands of times while bots plan.

	FRAME: course coordinates are metres from `Origin`, like the hole frame:
	    world = Origin + Vector3.new(x, y, z) * StudsPerMeter
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Config = require(Shared.Config)
local CourseLayout = require(Shared.CourseLayout)
local ShotPhysics = require(Shared.ShotPhysics)
local SurfaceMaterials = require(Shared.SurfaceMaterials)
local Types = require(Shared.Types)

export type Probe = {
	Hit: boolean,
	Height: number, -- metres, course frame
	Lie: Types.LieId,
	Material: string,
	NormalX: number,
	NormalY: number,
	NormalZ: number,
}

export type Surface = ShotPhysics.Terrain & {
	probe: (x: number, z: number) -> Probe,
	worldHeight: (x: number, z: number) -> number, -- studs (world Y) at course (x, z)
	clearCache: () -> (),
}

export type Options = {
	Origin: Vector3,
	StudsPerMeter: number?,
	Include: { Instance }?, -- extra instances to hit besides workspace.Terrain
	ProbeTop: number?, -- studs above Origin.Y where rays start (default 400)
	ProbeDepth: number?, -- ray length (default 900)
	Fallback: ShotPhysics.Terrain?, -- used where a ray hits nothing
}

local TerrainSurface = {}

local CELL = 0.25 -- metres
local MAX_CACHE = 40000

function TerrainSurface.new(options: Options): Surface
	local origin = options.Origin
	local spm = options.StudsPerMeter or CourseLayout.STUDS_PER_METER
	local top = options.ProbeTop or 400
	local depth = options.ProbeDepth or 900
	local fallback = options.Fallback

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	local include: { Instance } = { workspace.Terrain }
	local extra: { Instance } = options.Include or {}
	for _, instance in extra do
		table.insert(include, instance)
	end
	params.FilterDescendantsInstances = include
	params.IgnoreWater = false

	local cache: { [number]: Probe } = {}
	local cacheSize = 0

	local function key(x: number, z: number): number
		local ix = math.floor(x / CELL + 0.5)
		local iz = math.floor(z / CELL + 0.5)
		return ix * 1048576 + iz
	end

	local function cast(x: number, z: number): Probe
		local start = origin + Vector3.new(x * spm, top, z * spm)
		local result = workspace:Raycast(start, Vector3.new(0, -depth, 0), params)
		if result == nil then
			if fallback then
				local gx, gz = fallback.slopeAt(x, z)
				local inv = 1 / math.sqrt(gx * gx + 1 + gz * gz)
				return {
					Hit = false, Height = fallback.heightAt(x, z), Lie = fallback.lieAt(x, z), Material = "None",
					NormalX = -gx * inv, NormalY = inv, NormalZ = -gz * inv,
				}
			end
			return { Hit = false, Height = 0, Lie = "Rough", Material = "None", NormalX = 0, NormalY = 1, NormalZ = 0 }
		end
		local material = result.Material.Name
		local attribute = if result.Instance:IsA("BasePart") then result.Instance:GetAttribute(SurfaceMaterials.ATTRIBUTE) else nil
		local normal = result.Normal
		local ny = math.max(normal.Y, 0.05) -- vertical walls count as very steep, never flipped
		return {
			Hit = true,
			Height = (result.Position.Y - origin.Y) / spm,
			Lie = SurfaceMaterials.lieFor(material, attribute),
			Material = material,
			NormalX = normal.X,
			NormalY = ny,
			NormalZ = normal.Z,
		}
	end

	local function probe(x: number, z: number): Probe
		local k = key(x, z)
		local hit = cache[k]
		if hit then
			return hit
		end
		if cacheSize >= MAX_CACHE then
			cache, cacheSize = {}, 0
		end
		local fresh = cast(x, z)
		cache[k] = fresh
		cacheSize += 1
		return fresh
	end

	local surface: Surface = {
		heightAt = function(x: number, z: number): number
			return probe(x, z).Height
		end,
		lieAt = function(x: number, z: number): Types.LieId
			return probe(x, z).Lie
		end,
		slopeAt = function(x: number, z: number): (number, number)
			local p = probe(x, z)
			return -p.NormalX / p.NormalY, -p.NormalZ / p.NormalY
		end,
		physicsAt = function(x: number, z: number): Config.LieDef?
			local p = probe(x, z)
			return SurfaceMaterials.physicsFor(p.Material, p.Lie)
		end,
		probe = probe,
		worldHeight = function(x: number, z: number): number
			return origin.Y + probe(x, z).Height * spm
		end,
		clearCache = function()
			cache, cacheSize = {}, 0
		end,
	}
	return surface
end

return TerrainSurface
