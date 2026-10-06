--!strict
--[[
	SurfaceMaterials.luau  (ReplicatedStorage.GolfRivals.Shared)

	What a ball touching a surface is ON, from the surface's Roblox material - the
	bridge between a real 3D map (Smooth Terrain, MeshParts) and the golf rules.

	  SMOOTH TERRAIN material      lie        notes
	    Grass                      Fairway    mown grass
	    LeafyGrass                 Rough      long / tall grass
	    Ground, Mud                Rough      heavier, softer (own physics)
	    Rock, Slate, Basalt        Rough      hard: high bounce, fast roll
	    Sand, Sandstone            Sand       bunker
	    Water                      Water      hazard (ball is lost)
	    anything else              Rough

	  PARTS / MESHPARTS (high-detail maps)
	    A part's "GolfLie" attribute always wins: set it to Fairway / Rough / Sand /
	    Green / Tee / Water on putting-green meshes, tee boxes, cart paths... A part
	    without the attribute is mapped by its Material like terrain.

	PHYSICS: each lie has default bounce/roll values (Config.Lies); materials can
	refine them (rock bounces harder than grass, mud swallows the ball). physicsFor
	merges the override over the lie's defaults, so ShotPhysics gets one LieDef.

	The tables are plain data so designers can extend them; everything is pure.
]]

local Config = require(script.Parent.Config)
local Types = require(script.Parent.Types)

local SurfaceMaterials = {}

SurfaceMaterials.TerrainLies = {
	Grass = "Fairway",
	LeafyGrass = "Rough",
	Ground = "Rough",
	Mud = "Rough",
	Rock = "Rough",
	Slate = "Rough",
	Basalt = "Rough",
	Limestone = "Rough",
	Sand = "Sand",
	Sandstone = "Sand",
	Salt = "Sand",
	Water = "Water",
} :: { [string]: Types.LieId }

-- Per-material refinements of the lie's physics (any LieDef field).
SurfaceMaterials.PhysicsOverrides = {
	Rock = { Restitution = 0.62, TangentRetain = 0.82, RollFriction = 0.07 },
	Slate = { Restitution = 0.58, TangentRetain = 0.8, RollFriction = 0.07 },
	Basalt = { Restitution = 0.6, TangentRetain = 0.8, RollFriction = 0.07 },
	Limestone = { Restitution = 0.55, TangentRetain = 0.78, RollFriction = 0.08 },
	Ground = { Restitution = 0.28, TangentRetain = 0.5, RollFriction = 0.3 },
	Mud = { Restitution = 0.06, TangentRetain = 0.1, RollFriction = 1.0 },
	Salt = { Restitution = 0.1, TangentRetain = 0.15, RollFriction = 0.9 },
} :: { [string]: { [string]: number } }

-- The terrain materials a generated course is painted with (TerrainCourse).
SurfaceMaterials.BuildMaterials = {
	Fairway = "Grass",
	Rough = "LeafyGrass",
	Apron = "Ground", -- out of bounds
	Sand = "Sand",
	Water = "Water",
	GreenBase = "Grass", -- under the green surface part
} :: { [string]: string }

SurfaceMaterials.ATTRIBUTE = "GolfLie"

local VALID_LIES: { [string]: boolean } = { Tee = true, Fairway = true, Rough = true, Sand = true, Green = true, Water = true }

function SurfaceMaterials.isLie(value: any): boolean
	return type(value) == "string" and VALID_LIES[value] == true
end

-- Lie for a hit surface: an explicit GolfLie attribute wins, then the material.
function SurfaceMaterials.lieFor(materialName: string, attributeLie: any): Types.LieId
	if SurfaceMaterials.isLie(attributeLie) then
		return attributeLie :: Types.LieId
	end
	return SurfaceMaterials.TerrainLies[materialName] or "Rough"
end

-- The lie's physics with the material's refinements applied (a new table).
function SurfaceMaterials.physicsFor(materialName: string, lie: Types.LieId): Config.LieDef
	local base = Config.Lies[lie]
	local override = SurfaceMaterials.PhysicsOverrides[materialName]
	if override == nil or lie == "Green" or lie == "Water" or lie == "Tee" then
		return base
	end
	local merged = table.clone(base) :: any
	for key, value in override do
		merged[key] = value
	end
	return merged :: Config.LieDef
end

return SurfaceMaterials
