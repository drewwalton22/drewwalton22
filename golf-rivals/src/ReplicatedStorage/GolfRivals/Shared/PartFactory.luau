--!strict
-- ROBLOX-ONLY: creates Instances. The part specs themselves are pure and tested.
--[[
	PartFactory.luau  (ReplicatedStorage.GolfRivals.Shared)

	Turns one CourseLayout.PartSpec into a real anchored Part. Shared by the client's
	CourseBuilder and the server's LobbyBuilder so there is a single place that knows
	how a spec's Shape/Yaw map onto Roblox's part orientation:

	  Block : CFrame.Angles(0, yaw, 0)
	  Disc  : a Roblox cylinder's axis is its local X; rolling it 90 degrees about Z
	          makes the axis vertical, so SX (the axis length) is the thickness.
	  Ball  : Shape = Ball
]]

local CourseLayout = require(script.Parent.CourseLayout)

local PartFactory = {}

local function materialFor(name: string): Enum.Material
	local material = (Enum.Material :: any)[name]
	return material or Enum.Material.SmoothPlastic
end

function PartFactory.create(spec: CourseLayout.PartSpec, origin: Vector3): Part
	local part = Instance.new("Part")
	part.Name = spec.Name
	part.Anchored = true
	part.CanCollide = spec.CanCollide
	part.CanTouch = false
	part.CanQuery = spec.CanCollide
	part.CastShadow = spec.Shape ~= "Disc"
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Color = Color3.fromRGB(spec.Color[1], spec.Color[2], spec.Color[3])
	part.Material = materialFor(spec.Material)
	part.Transparency = spec.Transparency
	part.Size = Vector3.new(spec.SX, spec.SY, spec.SZ)

	local position = origin + Vector3.new(spec.X, spec.Y, spec.Z)
	if spec.Shape == "Disc" then
		part.Shape = Enum.PartType.Cylinder
		part.CFrame = CFrame.new(position) * CFrame.Angles(0, math.rad(spec.YawDeg), math.pi / 2)
	elseif spec.Shape == "Ball" then
		part.Shape = Enum.PartType.Ball
		part.CFrame = CFrame.new(position)
	else
		part.CFrame = CFrame.new(position) * CFrame.Angles(0, math.rad(spec.YawDeg), 0)
	end
	return part
end

return PartFactory
