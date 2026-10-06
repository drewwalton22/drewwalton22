--!strict
-- ROBLOX-ONLY: builds GuiObjects. The segment layout it draws is WheelRules'.
--[[
	WheelArt.luau  (ReplicatedStorage.GolfRivals.Shared)

	Draws the daily wheel's face into any GuiObject (a square Frame on screen, or a
	SurfaceGui on the 3D lobby wheel) so both always look identical:

	  * a round rim and hub
	  * one coloured wedge per Config.Wheel segment, drawn as a fan of thin rotated
	    bars from the centre (GUI frames can't be wedge-shaped)
	  * each segment's label, reading outward from the hub
	Segment i is centred at WheelRules.segmentCentre(i) degrees clockwise from the
	top, the same convention WheelRules.restingAngle uses to stop the spin, so the
	wheel lands exactly on the server's roll.

	Returns the rotating container: set its Rotation (clockwise degrees) to spin.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Config = require(Shared.Config)
local WheelRules = require(Shared.WheelRules)

local WheelArt = {}

local RAYS_PER_SEGMENT = 12

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function corner(parent: Instance, scale: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(scale, 0)
	c.Parent = parent
end

function WheelArt.draw(parent: GuiObject): Frame
	local rim = Instance.new("Frame")
	rim.Name = "WheelRim"
	rim.Size = UDim2.fromScale(1, 1)
	rim.BackgroundColor3 = Color3.fromRGB(30, 34, 52)
	rim.BorderSizePixel = 0
	corner(rim, 0.5)
	rim.Parent = parent

	local wheel = Instance.new("Frame")
	wheel.Name = "Wheel"
	wheel.AnchorPoint = Vector2.new(0.5, 0.5)
	wheel.Position = UDim2.fromScale(0.5, 0.5)
	wheel.Size = UDim2.fromScale(0.94, 0.94)
	wheel.BackgroundColor3 = Color3.fromRGB(16, 20, 34)
	wheel.BorderSizePixel = 0
	wheel.ClipsDescendants = false
	corner(wheel, 0.5)
	wheel.Parent = rim

	local n = #Config.Wheel.Segments
	local width = 360 / n
	for index, segment in Config.Wheel.Segments do
		local centre = WheelRules.segmentCentre(index)
		local color = rgb(segment.Color)
		-- Fan of bars from the centre to the edge covering the wedge.
		for r = 0, RAYS_PER_SEGMENT - 1 do
			local angle = centre - width / 2 + (r + 0.5) * width / RAYS_PER_SEGMENT
			local ray = Instance.new("Frame")
			ray.AnchorPoint = Vector2.new(0.5, 1)
			ray.Position = UDim2.fromScale(0.5, 0.5)
			ray.Size = UDim2.fromScale(math.rad(width / RAYS_PER_SEGMENT) * 0.5 * 1.35, 0.5)
			ray.Rotation = angle
			ray.BackgroundColor3 = if index % 2 == 0 then color:Lerp(Color3.new(0, 0, 0), 0.12) else color
			ray.BorderSizePixel = 0
			ray.ZIndex = 2
			ray.Parent = wheel
		end
		-- Label along the segment's centre line, reading outward.
		local holder = Instance.new("Frame")
		holder.AnchorPoint = Vector2.new(0.5, 0.5)
		holder.Position = UDim2.fromScale(0.5, 0.5)
		holder.Size = UDim2.fromScale(1, 1)
		holder.BackgroundTransparency = 1
		holder.Rotation = centre
		holder.ZIndex = 3
		holder.Parent = wheel
		local label = Instance.new("TextLabel")
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, 0.19)
		label.Size = UDim2.fromScale(0.22, 0.09)
		label.BackgroundTransparency = 1
		label.Text = segment.Label
		label.TextScaled = true
		label.Font = Enum.Font.BuilderSansExtraBold
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextStrokeTransparency = 0.35
		label.ZIndex = 4
		label.Parent = holder
		local kind = Instance.new("TextLabel")
		kind.AnchorPoint = Vector2.new(0.5, 0.5)
		kind.Position = UDim2.fromScale(0.5, 0.27)
		kind.Size = UDim2.fromScale(0.16, 0.05)
		kind.BackgroundTransparency = 1
		kind.Text = if segment.Kind == "Cosmetic" then "ITEM" else string.upper(segment.Kind)
		kind.TextScaled = true
		kind.Font = Enum.Font.BuilderSansBold
		kind.TextColor3 = Color3.fromRGB(20, 24, 40)
		kind.ZIndex = 4
		kind.Parent = holder
	end

	local hub = Instance.new("Frame")
	hub.AnchorPoint = Vector2.new(0.5, 0.5)
	hub.Position = UDim2.fromScale(0.5, 0.5)
	hub.Size = UDim2.fromScale(0.18, 0.18)
	hub.BackgroundColor3 = Color3.fromRGB(255, 205, 70)
	hub.BorderSizePixel = 0
	hub.ZIndex = 5
	corner(hub, 0.5)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Thickness = 3
	stroke.Parent = hub
	hub.Parent = wheel
	return wheel
end

return WheelArt
