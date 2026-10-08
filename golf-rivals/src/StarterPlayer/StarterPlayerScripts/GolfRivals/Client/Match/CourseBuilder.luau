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
local PartFactory = require(Shared.PartFactory)

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

function CourseBuilder.build(hole: CourseDatabase.HoleDef, origin: Vector3): Course
	local layout = CourseLayout.build(hole)
	local folder = Instance.new("Folder")
	folder.Name = `Hole{hole.Id}`

	for _, spec in layout.Parts do
		local part = PartFactory.create(spec, origin)
		part.CanQuery = false
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
