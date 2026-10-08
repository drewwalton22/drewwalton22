--!strict
-- ROBLOX-ONLY: reads hand-built holes from the Workspace.
--[[
	CourseRegistry.luau  (ServerScriptService.GolfRivals.Server)

	Hand-built, high-detail holes (Smooth Terrain + MeshParts you sculpt in Studio)
	are registered here and played instead of the generated ones.

	HOW TO AUTHOR A HOLE (see docs/STUDIO_SETUP.md)
	  Workspace
	  └── GolfCourses                  (Folder - name from Config.Course.MappedFolder)
	      └── Hole1                    (Model or Folder; attributes: Par = 4, HoleName = "...")
	          ├── Tee      (Part)      where the ball is teed up (its top surface)
	          ├── Pin      (Part)      the cup position (its centre). The game builds the
	          │                        visible cup there (CupBuilder): carved into
	          │                        Smooth Terrain greens, drawn on part greens
	          ├── Bounds   (Part)      OPTIONAL: an invisible box covering the playable
	          │                        area; outside it = out of bounds
	          └── ...      greens / tees / paths as MeshParts with a GolfLie attribute
	                       ("Green", "Tee", "Fairway", "Rough", "Sand", "Water")
	  Paint the ground with Smooth Terrain: Grass = fairway, LeafyGrass = rough,
	  Sand = bunkers, Water = water (SurfaceMaterials has the full table).

	Each hole becomes a HoleDef whose frame is anchored at its Tee (origin), so the
	match engine, bots and clients work unchanged; lies and heights come from
	raycasts (TerrainSurface), the analytic shapes are only a minimal fallback.
	Holes are ordered by name.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Config = require(Shared.Config)
local CourseDatabase = require(Shared.CourseDatabase)
local CourseLayout = require(Shared.CourseLayout)
local Logger = require(Shared.Logger)

local CupBuilder = require(script.Parent.CupBuilder)

export type Mapped = {
	Hole: CourseDatabase.HoleDef,
	Origin: Vector3,
	Container: Instance, -- raycasts include it (green / tee MeshParts)
}

local CourseRegistry = {}

local SPM = CourseLayout.STUDS_PER_METER
local MAPPED_ID_BASE = 1000

local mapped: { Mapped } = {}
local byId: { [number]: Mapped } = {}

local function partNamed(container: Instance, name: string): BasePart?
	local found = container:FindFirstChild(name, true)
	return if found and found:IsA("BasePart") then found else nil
end

function CourseRegistry.load()
	mapped, byId = {}, {}
	if not Config.Course.UseMappedCourses then
		return
	end
	local folder = workspace:FindFirstChild(Config.Course.MappedFolder)
	if folder == nil then
		return
	end
	local containers = folder:GetChildren()
	table.sort(containers, function(a: Instance, b: Instance): boolean
		return a.Name < b.Name
	end)
	for _, container in containers do
		local tee, pin = partNamed(container, "Tee"), partNamed(container, "Pin")
		if tee == nil or pin == nil then
			Logger.info("Courses", `{container.Name}: needs a Tee part and a Pin part - skipped`)
			continue
		end
		local origin = tee.Position + Vector3.new(0, tee.Size.Y / 2, 0)
		local pinOffset = (pin.Position - origin) / SPM
		local id = MAPPED_ID_BASE + #mapped + 1
		local bounds: CourseDatabase.Bounds
		local boundsPart = partNamed(container, "Bounds")
		if boundsPart then
			local min = (boundsPart.Position - boundsPart.Size / 2 - origin) / SPM
			local max = (boundsPart.Position + boundsPart.Size / 2 - origin) / SPM
			bounds = { MinX = min.X, MaxX = max.X, MinZ = min.Z, MaxZ = max.Z }
			boundsPart.CanQuery = false
		else
			local margin = 45
			bounds = {
				MinX = math.min(0, pinOffset.X) - margin, MaxX = math.max(0, pinOffset.X) + margin,
				MinZ = math.min(0, pinOffset.Z) - margin, MaxZ = math.max(0, pinOffset.Z) + margin,
			}
		end
		local par = container:GetAttribute("Par")
		local holeName = container:GetAttribute("HoleName")
		local hole: CourseDatabase.HoleDef = {
			Id = id,
			Name = if type(holeName) == "string" then holeName else container.Name,
			Par = if type(par) == "number" then math.clamp(math.floor(par), 3, 6) else 4,
			Tee = { X = 0, Z = 0 },
			Pin = { X = pinOffset.X, Z = pinOffset.Z },
			Fairway = {},
			Greens = { { X = pinOffset.X, Z = pinOffset.Z, R = 12 } }, -- minimap / fallback only
			Bunkers = {},
			Water = {},
			GreenSlope = { X = 0, Z = 0 },
			Bounds = bounds,
		}
		pin.CanQuery = false -- the ball must land on the green, not on the pin part
		-- The cup: raycast the green under the pin and build the pocket + rim there
		-- (Smooth Terrain greens are carved; solid part greens get a dark cup drawn on top).
		local cupOk, cupErr = pcall(function()
			local exclude: { Instance } = { pin }
			CupBuilder.build({ Parent = container, Centre = pin.Position, Exclude = exclude, Label = container.Name })
		end)
		if not cupOk then
			warn(`[GolfRivals][Cup] {container.Name}: building the cup failed: {tostring(cupErr)}`)
		end
		local entry: Mapped = { Hole = hole, Origin = origin, Container = container }
		table.insert(mapped, entry)
		byId[id] = entry
	end
	if #mapped > 0 then
		Logger.info("Courses", `{#mapped} hand-built hole(s) registered from Workspace.{Config.Course.MappedFolder}.`)
	end
end

function CourseRegistry.count(): number
	return #mapped
end

function CourseRegistry.get(holeId: number): Mapped?
	return byId[holeId]
end

-- `count` consecutive hand-built holes from `startIndex` (wrapping); nil if none.
function CourseRegistry.sequence(startIndex: number, count: number): { CourseDatabase.HoleDef }?
	if #mapped == 0 then
		return nil
	end
	local result: { CourseDatabase.HoleDef } = {}
	for i = 0, count - 1 do
		table.insert(result, mapped[(startIndex - 1 + i) % #mapped + 1].Hole)
	end
	return result
end

return CourseRegistry
