--!strict
-- ROBLOX-ONLY: builds GuiObjects. The segment layout it draws is WheelRules'.
--[[
	WheelArt.luau  (ReplicatedStorage.GolfRivals.Shared)

	Draws the daily wheel's face into any GuiObject (a square Frame on screen, or a
	SurfaceGui on the 3D lobby wheel) so both are IDENTICAL - the same function,
	the same angles:

	  * a gold gradient rim with a soft glow and a peg at every segment boundary
	  * one coloured wedge per Config.Wheel segment, with a gloss gradient
	  * thin white separators between segments
	  * each segment's label (and COINS / GEMS / ITEM), reading outward
	  * a gold hub

	HOW THE WEDGES ARE DRAWN: GUI frames can't be wedge-shaped, so each wedge is a
	fan of thin bars from the centre. Roblox rotates a GuiObject around its OWN
	CENTRE (not its AnchorPoint), so every bar lives inside a full-size, centred
	"arm" frame and the ARM is rotated - its centre is the wheel's centre. (Rotating
	a half-length bar directly spins it around a point halfway to the rim, which
	drew the wheel as a small blob off-centre.)

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

local RAYS_PER_SEGMENT = 16

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function corner(parent: Instance, scale: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(scale, 0)
	c.Parent = parent
end

local function gradient(parent: Instance, top: Color3, bottom: Color3, rotation: number)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(top, bottom)
	g.Rotation = rotation
	g.Parent = parent
end

local function stroke(parent: Instance, color: Color3, thickness: number, transparency: number)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Transparency = transparency
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
end

-- A full-size, centred, transparent frame rotated by `angle` - children placed
-- along its vertical centre line point at `angle` from the wheel's centre.
local function arm(parent: Instance, angle: number, zIndex: number): Frame
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundTransparency = 1
	frame.Rotation = angle
	frame.ZIndex = zIndex
	frame.Parent = parent
	return frame
end

function WheelArt.draw(parent: GuiObject): Frame
	local rim = Instance.new("Frame")
	rim.Name = "WheelRim"
	rim.Size = UDim2.fromScale(1, 1)
	rim.BackgroundColor3 = Color3.fromRGB(255, 214, 96)
	rim.BorderSizePixel = 0
	corner(rim, 0.5)
	gradient(rim, Color3.fromRGB(255, 236, 160), Color3.fromRGB(190, 120, 30), 45)
	stroke(rim, Color3.fromRGB(255, 200, 90), 3, 0.35)
	rim.Parent = parent

	local wheel = Instance.new("Frame")
	wheel.Name = "Wheel"
	wheel.AnchorPoint = Vector2.new(0.5, 0.5)
	wheel.Position = UDim2.fromScale(0.5, 0.5)
	wheel.Size = UDim2.fromScale(0.92, 0.92)
	wheel.BackgroundColor3 = Color3.fromRGB(16, 20, 34)
	wheel.BorderSizePixel = 0
	wheel.ClipsDescendants = false
	corner(wheel, 0.5)
	wheel.Parent = rim

	local n = #Config.Wheel.Segments
	local width = 360 / n
	local barWidth = math.rad(width / RAYS_PER_SEGMENT) * 0.5 * 1.45 -- arc at the rim, with overlap
	for index, segment in Config.Wheel.Segments do
		local centre = WheelRules.segmentCentre(index)
		local color = rgb(segment.Color)
		local shade = if index % 2 == 0 then color:Lerp(Color3.new(0, 0, 0), 0.14) else color
		-- Wedge: a fan of bars, each in its own rotating arm.
		for r = 0, RAYS_PER_SEGMENT - 1 do
			local angle = centre - width / 2 + (r + 0.5) * width / RAYS_PER_SEGMENT
			local bar = Instance.new("Frame")
			bar.AnchorPoint = Vector2.new(0.5, 1)
			bar.Position = UDim2.fromScale(0.5, 0.5)
			bar.Size = UDim2.fromScale(barWidth, 0.5)
			bar.BackgroundColor3 = shade
			bar.BorderSizePixel = 0
			bar.ZIndex = 2
			-- Gloss: lighter toward the rim.
			gradient(bar, Color3.new(1, 1, 1), Color3.fromRGB(205, 205, 215), 90)
			bar.Parent = arm(wheel, angle, 2)
		end
		-- Separator line + rim peg at the segment's leading edge.
		local edge = arm(wheel, centre - width / 2, 3)
		local line = Instance.new("Frame")
		line.AnchorPoint = Vector2.new(0.5, 1)
		line.Position = UDim2.fromScale(0.5, 0.5)
		line.Size = UDim2.new(0, 2, 0.5, 0)
		line.BackgroundColor3 = Color3.new(1, 1, 1)
		line.BackgroundTransparency = 0.35
		line.BorderSizePixel = 0
		line.ZIndex = 3
		line.Parent = edge
		local peg = Instance.new("Frame")
		peg.AnchorPoint = Vector2.new(0.5, 0.5)
		peg.Position = UDim2.fromScale(0.5, -0.025)
		peg.Size = UDim2.fromScale(0.035, 0.035)
		peg.BackgroundColor3 = Color3.new(1, 1, 1)
		peg.BorderSizePixel = 0
		peg.ZIndex = 4
		corner(peg, 0.5)
		peg.Parent = edge

		-- Label along the segment's centre line, reading outward.
		local holder = arm(wheel, centre, 4)
		local label = Instance.new("TextLabel")
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, 0.17)
		label.Size = UDim2.fromScale(0.24, 0.09)
		label.BackgroundTransparency = 1
		label.Text = segment.Label
		label.TextScaled = true
		label.Font = Enum.Font.BuilderSansExtraBold
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextStrokeTransparency = 0.35
		label.ZIndex = 5
		label.Parent = holder
		local kind = Instance.new("TextLabel")
		kind.AnchorPoint = Vector2.new(0.5, 0.5)
		kind.Position = UDim2.fromScale(0.5, 0.255)
		kind.Size = UDim2.fromScale(0.16, 0.05)
		kind.BackgroundTransparency = 1
		kind.Text = if segment.Kind == "Cosmetic" then "ITEM" else string.upper(segment.Kind)
		kind.TextScaled = true
		kind.Font = Enum.Font.BuilderSansBold
		kind.TextColor3 = Color3.fromRGB(20, 24, 40)
		kind.ZIndex = 5
		kind.Parent = holder
	end

	local hub = Instance.new("Frame")
	hub.AnchorPoint = Vector2.new(0.5, 0.5)
	hub.Position = UDim2.fromScale(0.5, 0.5)
	hub.Size = UDim2.fromScale(0.17, 0.17)
	hub.BackgroundColor3 = Color3.fromRGB(255, 205, 70)
	hub.BorderSizePixel = 0
	hub.ZIndex = 6
	corner(hub, 0.5)
	gradient(hub, Color3.fromRGB(255, 240, 170), Color3.fromRGB(214, 140, 30), 90)
	stroke(hub, Color3.new(1, 1, 1), 3, 0)
	hub.Parent = wheel
	return wheel
end

return WheelArt
