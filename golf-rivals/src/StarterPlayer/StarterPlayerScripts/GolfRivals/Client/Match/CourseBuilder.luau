--!strict
--[[
	CourseBuilder.luau  (Client/Match)

	Instantiates one hole in the Workspace from the pure CourseLayout part specs.
	It is deliberately dumb: all geometry decisions live in CourseLayout (tested
	offline); this just creates anchored Parts.

	The hole is built around `origin` (a world position): hole-frame metres map to
	world studs with `toWorld`, the same transform every other match module uses to
	place balls, players and cameras on the course.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local CourseLayout = require(Shared.CourseLayout)
local CourseDatabase = require(Shared.CourseDatabase)

export type Course = {
	Folder: Folder,
	Origin: Vector3,
	Tee: Vector3, -- world position of the tee box surface
	Pin: Vector3, -- world position of the cup
	toWorld: (xMeters: number, yMeters: number, zMeters: number) -> Vector3,
	destroy: () -> (),
}

local CourseBuilder = {}

local SPM = CourseLayout.STUDS_PER_METER

local function materialFor(name: string): Enum.Material
	local material = (Enum.Material :: any)[name]
	return material or Enum.Material.SmoothPlastic
end

function CourseBuilder.build(hole: CourseDatabase.HoleDef, origin: Vector3): Course
	local layout = CourseLayout.build(hole)
	local folder = Instance.new("Folder")
	folder.Name = `Hole{hole.Id}`

	for _, spec in layout.Parts do
		local part = Instance.new("Part")
		part.Name = spec.Name
		part.Anchored = true
		part.CanCollide = spec.CanCollide
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = spec.Shape ~= "Disc"
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Color = Color3.fromRGB(spec.Color[1], spec.Color[2], spec.Color[3])
		part.Material = materialFor(spec.Material)
		part.Transparency = spec.Transparency
		part.Size = Vector3.new(spec.SX, spec.SY, spec.SZ)

		local position = origin + Vector3.new(spec.X, spec.Y, spec.Z)
		if spec.Shape == "Disc" then
			-- A Roblox cylinder's axis is its local X; roll it so the axis points up.
			part.Shape = Enum.PartType.Cylinder
			part.CFrame = CFrame.new(position) * CFrame.Angles(0, math.rad(spec.YawDeg), math.pi / 2)
		elseif spec.Shape == "Ball" then
			part.Shape = Enum.PartType.Ball
			part.CFrame = CFrame.new(position)
		else
			part.CFrame = CFrame.new(position) * CFrame.Angles(0, math.rad(spec.YawDeg), 0)
		end
		part.Parent = folder
	end
	folder.Parent = workspace

	local function toWorld(xMeters: number, yMeters: number, zMeters: number): Vector3
		return origin + Vector3.new(xMeters * SPM, yMeters * SPM, zMeters * SPM)
	end

	return {
		Folder = folder,
		Origin = origin,
		Tee = origin + Vector3.new(layout.Tee.X, layout.Tee.Y, layout.Tee.Z),
		Pin = origin + Vector3.new(layout.Pin.X, layout.Pin.Y, layout.Pin.Z),
		toWorld = toWorld,
		destroy = function()
			folder:Destroy()
		end,
	}
end

return CourseBuilder
