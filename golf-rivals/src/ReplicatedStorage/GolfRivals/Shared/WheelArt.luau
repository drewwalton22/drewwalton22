--!strict
-- ROBLOX-ONLY: builds GuiObjects. The geometry it draws is WheelRules'.
--[[
	WheelArt.luau  (ReplicatedStorage.GolfRivals.Shared)

	Draws the daily wheel's face into any GuiObject (a square Frame on screen, or a
	SurfaceGui on the 3D lobby wheel) so both are IDENTICAL - the same function,
	the same geometry:

	  * a gold rim with a peg at every segment boundary
	  * one exact coloured wedge per Config.Wheel segment, white separators
	  * each segment's ICON (coin / gem / gift), its amount and COINS / GEMS / ITEM,
	    sized by WheelRules.layout() to fit inside the wedge at any screen size
	  * a static gloss highlight and a gold hub with a star

	EXACT WEDGES (no images needed): see WheelRules.wedgePieces. Each half of the
	face is a clipping frame holding half-disc frames (a circle with a hard-edged
	UIGradient whose Rotation aims it); stacked in order they leave exactly each
	segment's wedge visible. Clipping doesn't work inside ROTATED frames, so the
	wedges are never rotated: to spin, setAngle() re-aims the gradients, while the
	separators, pegs, icons and labels sit in a "Spinner" frame that rotates.

	Segment i is centred at WheelRules.segmentCentre(i) degrees clockwise from the
	top, the same convention WheelRules.restingAngle uses to stop the spin, so the
	pointer at 12 o'clock lands exactly on the server's roll.

	Returns a Face: setAngle(degrees clockwise) turns the wheel.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Assets = require(Shared.Assets)
local Config = require(Shared.Config)
local WheelRules = require(Shared.WheelRules)

export type Face = {
	Root: Frame,
	setAngle: (degrees: number) -> (),
}

local WheelArt = {}

local DARK = Color3.fromRGB(24, 18, 40)
local FONT = Enum.Font.FredokaOne

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function corner(parent: Instance, scale: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(scale, 0)
	c.Parent = parent
end

local function gradient(parent: Instance, a: Color3, b: Color3, rotation: number): UIGradient
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(a, b)
	g.Rotation = rotation
	g.Parent = parent
	return g
end

local function stroke(parent: Instance, color: Color3, thickness: number, transparency: number, contextual: boolean?)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Transparency = transparency
	s.ApplyStrokeMode = if contextual then Enum.ApplyStrokeMode.Contextual else Enum.ApplyStrokeMode.Border
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Parent = parent
end

local function frame(name: string, size: UDim2, position: UDim2, color: Color3, zIndex: number, parent: Instance): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Size = size
	f.Position = position
	f.BackgroundColor3 = color
	f.BorderSizePixel = 0
	f.ZIndex = zIndex
	f.Parent = parent
	return f
end

local function text(value: string, size: UDim2, position: UDim2, zIndex: number, parent: Instance): TextLabel
	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Size = size
	label.Position = position
	label.BackgroundTransparency = 1
	label.Text = value
	label.TextScaled = true
	label.Font = FONT
	label.TextColor3 = Color3.new(1, 1, 1)
	label.ZIndex = zIndex
	label.Parent = parent
	stroke(label, DARK, 2, 0, true)
	return label
end

-- Position on the face at `radius` (face units) along `angle` (clockwise from top).
local function polar(angle: number, radius: number): UDim2
	local a = math.rad(angle)
	return UDim2.fromScale(0.5 + math.sin(a) * radius, 0.5 - math.cos(a) * radius)
end

-- A segment's icon, filling `holder`: the uploaded image when set, else a drawn
-- coin / gem / gift. Used on the wheel AND the result card, so they match.
function WheelArt.icon(segment: Config.WheelSegment, holder: GuiObject, zIndex: number)
	local imageName = if segment.Kind == "Coins" then "CoinIcon" elseif segment.Kind == "Gems" then "GemIcon" else "GiftIcon"
	local image = Assets.image(imageName)
	if image then
		local picture = Instance.new("ImageLabel")
		picture.Size = UDim2.fromScale(1, 1)
		picture.BackgroundTransparency = 1
		picture.Image = image
		picture.ScaleType = Enum.ScaleType.Fit
		picture.ZIndex = zIndex
		picture.Parent = holder
		return
	end
	local mid = UDim2.fromScale(0.5, 0.5)
	if segment.Kind == "Coins" then
		local coin = frame("Coin", UDim2.fromScale(0.9, 0.9), mid, Color3.fromRGB(255, 205, 50), zIndex, holder)
		corner(coin, 0.5)
		gradient(coin, Color3.fromRGB(255, 240, 150), Color3.fromRGB(230, 150, 20), 90)
		stroke(coin, DARK, 2, 0)
		local inner = frame("Inner", UDim2.fromScale(0.62, 0.62), mid, Color3.fromRGB(255, 190, 40), zIndex + 1, coin)
		corner(inner, 0.5)
		stroke(inner, Color3.fromRGB(200, 120, 10), 1.5, 0.2)
		local mark = text(if segment.Label == "JACKPOT" then "★" else "$", UDim2.fromScale(0.8, 0.8), mid, zIndex + 2, inner)
		mark.TextColor3 = Color3.fromRGB(255, 250, 220)
	elseif segment.Kind == "Gems" then
		local gem = frame("Gem", UDim2.fromScale(0.62, 0.62), mid, Color3.fromRGB(90, 220, 255), zIndex, holder)
		gem.Rotation = 45 -- a diamond
		corner(gem, 0.18)
		gradient(gem, Color3.fromRGB(210, 250, 255), Color3.fromRGB(40, 140, 230), 0)
		stroke(gem, DARK, 2, 0)
		local facet = frame("Facet", UDim2.fromScale(0.4, 0.4), UDim2.fromScale(0.35, 0.35), Color3.new(1, 1, 1), zIndex + 1, gem)
		facet.BackgroundTransparency = 0.45
		corner(facet, 0.2)
	else
		local tint = rgb(segment.Color)
		local box = frame("Gift", UDim2.fromScale(0.78, 0.62), UDim2.fromScale(0.5, 0.6), tint, zIndex, holder)
		corner(box, 0.14)
		gradient(box, Color3.new(1, 1, 1), Color3.fromRGB(170, 170, 185), 90)
		stroke(box, DARK, 2, 0)
		local gold = Color3.fromRGB(255, 220, 80)
		frame("RibbonV", UDim2.fromScale(0.2, 1), UDim2.fromScale(0.5, 0.5), gold, zIndex + 1, box)
		local lid = frame("Lid", UDim2.fromScale(1.12, 0.3), UDim2.fromScale(0.5, 0.08), tint:Lerp(Color3.new(1, 1, 1), 0.2), zIndex + 2, box)
		corner(lid, 0.3)
		stroke(lid, DARK, 2, 0)
		frame("RibbonLid", UDim2.fromScale(0.18, 1), UDim2.fromScale(0.5, 0.5), gold, zIndex + 3, lid)
		for _, side in { -1, 1 } do
			local bow = frame("Bow", UDim2.fromScale(0.22, 0.2), UDim2.fromScale(0.5 + side * 0.13, -0.17), gold, zIndex + 3, holder)
			bow.Rotation = side * 25
			corner(bow, 0.5)
			stroke(bow, DARK, 1.5, 0)
		end
	end
end

function WheelArt.kindText(segment: Config.WheelSegment): string
	return if segment.Kind == "Cosmetic" then "ITEM" else string.upper(segment.Kind)
end

function WheelArt.draw(parent: GuiObject): Face
	local segments = Config.Wheel.Segments
	local n = #segments
	local width = 360 / n
	local layout = WheelRules.layout()

	-- Rim: a gold ring with a dark outline.
	local rim = frame("WheelRim", UDim2.fromScale(1, 1), UDim2.fromScale(0.5, 0.5), Color3.fromRGB(255, 205, 70), 1, parent)
	corner(rim, 0.5)
	gradient(rim, Color3.fromRGB(255, 240, 170), Color3.fromRGB(200, 120, 20), 90)
	stroke(rim, DARK, 3, 0)

	-- The face (everything else lives inside it, so its size is the face unit).
	local face = frame("Wheel", UDim2.fromScale(0.9, 0.9), UDim2.fromScale(0.5, 0.5), DARK, 2, rim)
	corner(face, 0.5)
	stroke(face, Color3.fromRGB(150, 90, 10), 2, 0)

	-- Wedges: two clipping halves, n half-disc frames each (re-aimed by setAngle).
	local halves: { [string]: { { Disc: Frame, Gradient: UIGradient } } } = {}
	for _, half in { "Right", "Left" } do
		local clip = Instance.new("Frame")
		clip.Name = `{half}Half`
		clip.Size = UDim2.fromScale(0.5, 1)
		clip.Position = UDim2.fromScale(if half == "Right" then 0.5 else 0, 0)
		clip.BackgroundTransparency = 1
		clip.ClipsDescendants = true
		clip.ZIndex = 3
		clip.Parent = face
		local discs: { { Disc: Frame, Gradient: UIGradient } } = {}
		for i = 1, n do
			local disc = Instance.new("Frame")
			disc.Name = `Piece{i}`
			disc.Size = UDim2.fromScale(2, 1) -- the whole face
			disc.Position = UDim2.fromScale(if half == "Right" then -1 else 0, 0)
			disc.BorderSizePixel = 0
			disc.Visible = false
			disc.ZIndex = 3 + i
			corner(disc, 0.5)
			local g = Instance.new("UIGradient")
			g.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(0.5, 0),
				NumberSequenceKeypoint.new(0.5005, 1),
				NumberSequenceKeypoint.new(1, 1),
			})
			g.Parent = disc
			disc.Parent = clip
			table.insert(discs, { Disc = disc, Gradient = g })
		end
		halves[half] = discs
	end

	-- Gloss: a soft highlight across the top of the face (doesn't spin: it's light).
	local gloss = frame("Gloss", UDim2.fromScale(1, 1), UDim2.fromScale(0.5, 0.5), Color3.new(1, 1, 1), 20, face)
	corner(gloss, 0.5)
	local shine = Instance.new("UIGradient")
	shine.Rotation = 90
	shine.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.62),
		NumberSequenceKeypoint.new(0.45, 0.92),
		NumberSequenceKeypoint.new(1, 1),
	})
	shine.Parent = gloss
	-- Inner shadow at the rim for depth.
	local shade = frame("RimShade", UDim2.fromScale(1, 1), UDim2.fromScale(0.5, 0.5), Color3.new(0, 0, 0), 21, face)
	shade.BackgroundTransparency = 1
	corner(shade, 0.5)
	stroke(shade, Color3.new(0, 0, 0), 6, 0.6)

	-- The spinner: separators, pegs, icons and labels (rotates as a whole).
	local spinner = frame("Spinner", UDim2.fromScale(1, 1), UDim2.fromScale(0.5, 0.5), Color3.new(), 22, face)
	spinner.BackgroundTransparency = 1
	for index, segment in segments do
		local centre = WheelRules.segmentCentre(index)
		local edge = centre - width / 2
		-- Separator: a thin white bar from the hub to the rim along the boundary.
		local line = frame("Separator", UDim2.new(0, 3, 0.5, 0), polar(edge, 0.25), Color3.new(1, 1, 1), 23, spinner)
		line.Rotation = edge
		line.BackgroundTransparency = 0.1
		-- Rim peg on the boundary.
		local peg = frame("Peg", UDim2.fromScale(0.04, 0.04), polar(edge, layout.Pegs), Color3.new(1, 1, 1), 24, spinner)
		corner(peg, 0.5)
		stroke(peg, DARK, 1.5, 0)
		gradient(peg, Color3.new(1, 1, 1), Color3.fromRGB(255, 210, 120), 90)

		-- Icon, amount and kind, upright toward the rim on the centre line.
		local iconHolder = frame("Icon", UDim2.fromScale(layout.Icon.Width, layout.Icon.Height), polar(centre, layout.Icon.Radius), Color3.new(), 25, spinner)
		iconHolder.BackgroundTransparency = 1
		iconHolder.Rotation = centre
		WheelArt.icon(segment, iconHolder, 25)
		local amount = text(segment.Label, UDim2.fromScale(layout.Label.Width, layout.Label.Height), polar(centre, layout.Label.Radius), 26, spinner)
		amount.Name = "Label"
		amount.Rotation = centre
		local kind = text(WheelArt.kindText(segment), UDim2.fromScale(layout.Kind.Width, layout.Kind.Height), polar(centre, layout.Kind.Radius), 26, spinner)
		kind.Name = "Kind"
		kind.Rotation = centre
		kind.TextColor3 = Color3.fromRGB(255, 244, 210)
	end

	-- Hub: gold, with a star (static on top).
	local hub = frame("Hub", UDim2.fromScale(layout.Hub, layout.Hub), UDim2.fromScale(0.5, 0.5), Color3.fromRGB(255, 205, 70), 30, face)
	corner(hub, 0.5)
	gradient(hub, Color3.fromRGB(255, 244, 180), Color3.fromRGB(215, 135, 25), 90)
	stroke(hub, DARK, 3, 0)
	local star = text("★", UDim2.fromScale(0.7, 0.7), UDim2.fromScale(0.5, 0.5), 31, hub)
	star.TextColor3 = Color3.fromRGB(255, 255, 235)

	local function setAngle(degrees: number)
		local used: { [string]: number } = { Right = 0, Left = 0 }
		for _, piece in WheelRules.wedgePieces(degrees) do
			local slot = halves[piece.Half][piece.Rank]
			used[piece.Half] = math.max(used[piece.Half], piece.Rank)
			local segment = segments[piece.Segment]
			local color = rgb(segment.Color)
			slot.Disc.BackgroundColor3 = if piece.Segment % 2 == 0 then color:Lerp(Color3.new(0, 0, 0), 0.12) else color
			slot.Gradient.Rotation = WheelRules.halfDiscRotation(piece.Start)
			slot.Disc.ZIndex = 3 + piece.Rank
			slot.Disc.Visible = true
		end
		for half, discs in halves do
			for rank = used[half] + 1, #discs do
				discs[rank].Disc.Visible = false
			end
		end
		spinner.Rotation = degrees
	end
	setAngle(0)

	return { Root = face, setAngle = setAngle }
end

return WheelArt
