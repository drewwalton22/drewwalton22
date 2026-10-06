--!strict
--[[
	AimVisual.luau  (Client/Golf)

	Draws the AimGuide in the 3D world, in front of the golfer:

	  full shots  a dotted arc of glowing beads tracing the predicted flight, and a
	              landing ring where the ball will first touch down
	  putts       a solid line projected ON THE GROUND along the predicted roll
	              (it bends with the green's slope), with a ring where it stops

	Parts are pooled and re-positioned every update (the arc is redrawn live while
	the power bar rises), never re-created. All parts are local to this client,
	anchored, and ignore collisions / raycasts.
]]

export type Visual = {
	show: (points: { Vector3 }, isPutt: boolean, color: Color3?) -> (),
	hide: () -> (),
	destroy: () -> (),
}

local AimVisual = {}

local DOT_SIZE = 0.55
local LINE_WIDTH = 0.32
local LINE_LIFT = 0.24 -- studs above the ground so the line never z-fights the green

local function basePart(name: string, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Transparency = 1
	part.Parent = parent
	return part
end

function AimVisual.new(parent: Instance): Visual
	local folder = Instance.new("Folder")
	folder.Name = "AimGuide"
	folder.Parent = parent

	local dots: { Part } = {}
	local segments: { Part } = {}
	local ring = basePart("LandingRing", folder)
	ring.Shape = Enum.PartType.Cylinder
	ring.Size = Vector3.new(0.12, 5, 5) -- cylinder axis = X; rotated to lie flat
	local ringCenter = basePart("LandingDot", folder)
	ringCenter.Shape = Enum.PartType.Cylinder
	ringCenter.Size = Vector3.new(0.14, 1.4, 1.4)

	local function pooled(list: { Part }, index: number, factory: () -> Part): Part
		if index > #list then
			table.insert(list, factory())
		end
		return list[index]
	end

	local function hideFrom(list: { Part }, first: number)
		for i = first, #list do
			list[i].Transparency = 1
		end
	end

	local function hide()
		hideFrom(dots, 1)
		hideFrom(segments, 1)
		ring.Transparency = 1
		ringCenter.Transparency = 1
	end

	local function placeRing(at: Vector3, color: Color3, radius: number)
		local flat = CFrame.new(at + Vector3.new(0, LINE_LIFT, 0)) * CFrame.Angles(0, 0, math.rad(90))
		ring.Size = Vector3.new(0.1, radius * 2, radius * 2)
		ring.CFrame = flat
		ring.Color = color
		ring.Transparency = 0.55
		ringCenter.CFrame = flat * CFrame.new(0.02, 0, 0)
		ringCenter.Color = Color3.new(1, 1, 1)
		ringCenter.Transparency = 0.15
	end

	local function show(points: { Vector3 }, isPutt: boolean, color: Color3?)
		local tint = color or Color3.fromRGB(255, 255, 255)
		if #points < 2 then
			hide()
			return
		end
		if isPutt then
			hideFrom(dots, 1)
			-- Ground line: one flat segment between each pair of points.
			local count = 0
			for i = 1, #points - 1 do
				local a, b = points[i], points[i + 1]
				local length = (b - a).Magnitude
				if length > 0.05 then
					count += 1
					local segment = pooled(segments, count, function(): Part
						return basePart("PuttLine", folder)
					end)
					local mid = (a + b) / 2 + Vector3.new(0, LINE_LIFT, 0)
					segment.Size = Vector3.new(LINE_WIDTH, 0.08, length + LINE_WIDTH * 0.5)
					segment.CFrame = CFrame.lookAt(mid, mid + (b - a))
					segment.Color = tint
					-- Fade toward the end so the start of the line reads strongest.
					segment.Transparency = 0.1 + 0.5 * (i / #points)
				end
			end
			hideFrom(segments, count + 1)
			placeRing(points[#points], tint, 1.4)
		else
			hideFrom(segments, 1)
			-- Arc: a bead per point (skip the first, it sits inside the ball).
			local count = 0
			for i = 2, #points do
				count += 1
				local dot = pooled(dots, count, function(): Part
					local part = basePart("ArcDot", folder)
					part.Shape = Enum.PartType.Ball
					return part
				end)
				local alpha = i / #points
				dot.Size = Vector3.new(DOT_SIZE, DOT_SIZE, DOT_SIZE) * (1.15 - 0.45 * alpha)
				dot.CFrame = CFrame.new(points[i])
				dot.Color = tint
				dot.Transparency = 0.05 + 0.45 * alpha
			end
			hideFrom(dots, count + 1)
			placeRing(points[#points], tint, 3)
		end
	end

	return {
		show = show,
		hide = hide,
		destroy = function()
			folder:Destroy()
		end,
	}
end

return AimVisual
