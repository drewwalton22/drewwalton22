--!strict
-- ROBLOX-ONLY: writes Smooth Terrain and creates parts. WHAT it builds is the
-- pure, tested TerrainPlan.
--[[
	TerrainCourse.luau  (ServerScriptService.GolfRivals.Server)

	Builds one hole as real Smooth Terrain at a world origin (each match gets its
	own arena), and tears it down again:

	  build(plan, origin, name)  -> Built
	      Terrain:FillBlock / FillCylinder for every fill in plan order (Air carves),
	      big blocks split into <= 512-stud tiles so no single write is huge;
	      tee box / green surface / pin parts with their GolfLie attribute.
	  built.destroy()           -> clears the hole's region back to Air (tiled) and
	                               removes its parts and decorations

	Terrain replicates to every client automatically, so the course players see is
	exactly the one the server raycasts against (TerrainSurface).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local SurfaceMaterials = require(Shared.SurfaceMaterials)
local TerrainPlan = require(Shared.TerrainPlan)

export type Built = {
	Folder: Folder, -- course parts (tee, green, pin) + decorations
	Origin: Vector3,
	Plan: TerrainPlan.Plan,
	destroy: () -> (),
}

local TerrainCourse = {}

local TILE = 512

local function material(name: string): Enum.Material
	local ok, value = pcall(function(): any
		return (Enum.Material :: any)[name]
	end)
	return if ok and typeof(value) == "EnumItem" then value :: Enum.Material else Enum.Material.Grass
end

-- Position + yaw + optional tilt (up vector (-slopeX, 1, -slopeZ)).
local function frameFor(position: Vector3, yawDeg: number, slopeX: number, slopeZ: number): CFrame
	if slopeX == 0 and slopeZ == 0 then
		return CFrame.new(position) * CFrame.Angles(0, math.rad(yawDeg), 0)
	end
	local up = Vector3.new(-slopeX, 1, -slopeZ).Unit
	local right = (Vector3.new(1, 0, 0) - up * up.X).Unit
	return CFrame.fromMatrix(position, right, up)
end

-- FillBlock, split into tiles when the block is axis-aligned and large.
local function fillBlock(terrain: Terrain, cframe: CFrame, size: Vector3, mat: Enum.Material, axisAligned: boolean)
	if not axisAligned or (size.X <= TILE and size.Z <= TILE) then
		terrain:FillBlock(cframe, size, mat)
		return
	end
	local nx, nz = math.ceil(size.X / TILE), math.ceil(size.Z / TILE)
	local w, d = size.X / nx, size.Z / nz
	local corner = cframe.Position - Vector3.new(size.X / 2, 0, size.Z / 2)
	for i = 0, nx - 1 do
		for j = 0, nz - 1 do
			terrain:FillBlock(CFrame.new(corner + Vector3.new(w * (i + 0.5), 0, d * (j + 0.5))), Vector3.new(w, size.Y, d), mat)
		end
	end
end

function TerrainCourse.build(plan: TerrainPlan.Plan, origin: Vector3, name: string): Built
	local terrain = workspace.Terrain
	-- Tip: tick Terrain > Decoration in Studio for animated grass blades on Grass
	-- (Roblox doesn't let scripts set it).

	for _, f in plan.Fills do
		local mat = material(f.Material)
		local frame = frameFor(origin + Vector3.new(f.X, f.Y, f.Z), f.YawDeg, f.SlopeX, f.SlopeZ)
		if f.Shape == "Block" then
			fillBlock(terrain, frame, Vector3.new(f.SX, f.SY, f.SZ), mat, f.YawDeg == 0 and f.SlopeX == 0 and f.SlopeZ == 0)
		else
			terrain:FillCylinder(frame, f.SY, f.SX / 2, mat)
		end
	end

	local folder = Instance.new("Folder")
	folder.Name = name
	for _, spec in plan.Parts do
		local part = Instance.new("Part")
		part.Name = spec.Name
		part.Anchored = true
		part.CanCollide = spec.CanCollide
		part.CanQuery = spec.CanQuery
		part.CanTouch = false
		part.CastShadow = spec.Shape ~= "Disc"
		part.Color = Color3.fromRGB(spec.Color[1], spec.Color[2], spec.Color[3])
		part.Material = material(spec.Material)
		part.Transparency = spec.Transparency
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Size = Vector3.new(spec.SX, spec.SY, spec.SZ)
		local frame = frameFor(origin + Vector3.new(spec.X, spec.Y, spec.Z), 0, spec.SlopeX, spec.SlopeZ)
		if spec.Shape == "Disc" then
			part.Shape = Enum.PartType.Cylinder
			part.CFrame = frame * CFrame.Angles(0, 0, math.pi / 2) -- cylinder axis (X) -> vertical
		else
			part.CFrame = frame
		end
		if spec.Lie then
			part:SetAttribute(SurfaceMaterials.ATTRIBUTE, spec.Lie)
		end
		part.Parent = folder
	end
	folder.Parent = workspace

	local destroyed = false
	return {
		Folder = folder,
		Origin = origin,
		Plan = plan,
		destroy = function()
			if destroyed then
				return
			end
			destroyed = true
			folder:Destroy()
			local min = origin + Vector3.new(plan.Min.X, plan.Min.Y, plan.Min.Z)
			local max = origin + Vector3.new(plan.Max.X, plan.Max.Y, plan.Max.Z)
			local size = max - min
			fillBlock(terrain, CFrame.new((min + max) / 2), size, Enum.Material.Air, true)
		end,
	}
end

return TerrainCourse
