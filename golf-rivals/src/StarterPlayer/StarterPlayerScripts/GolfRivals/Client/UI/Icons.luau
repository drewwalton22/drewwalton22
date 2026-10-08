--!strict
--[[
	Icons.luau  (Client/UI)

	Small icons drawn with plain Frames (UICorner circles, rotated squares, bars),
	so they render identically on every device - unlike emoji such as the coin,
	which Roblox's font can't draw (it shows as an empty box). Each icon is a
	transparent Frame of the requested size; scale it like any GuiObject.

	If an uploaded image exists for an icon (Assets.Images.CoinIcon / GemIcon),
	Icons.currency uses it via AssetLoader and keeps the drawn version as the
	fallback.
]]

local Theme = require(script.Parent.Theme)
local AssetLoader = require(script.Parent.AssetLoader)

local Icons = {}

local C = Theme.Colors

local function holder(size: UDim2, name: string): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Size = size
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	return frame
end

local function circle(parent: Instance, scale: number, color: Color3, offset: Vector2?): Frame
	local dot = Instance.new("Frame")
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5 + (if offset then offset.X else 0), 0.5 + (if offset then offset.Y else 0))
	dot.Size = UDim2.fromScale(scale, scale)
	dot.BackgroundColor3 = color
	dot.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = dot
	dot.Parent = parent
	return dot
end

-- Gold coin: rim, face, inner ring and a highlight.
function Icons.coinDrawn(size: UDim2): GuiObject
	local frame = holder(size, "CoinIcon")
	circle(frame, 1, C.GoldDark)
	circle(frame, 0.84, C.Gold)
	local ring = circle(frame, 0.56, C.Gold)
	local stroke = Instance.new("UIStroke")
	stroke.Color = C.GoldDark
	stroke.Thickness = 1.5
	stroke.Parent = ring
	circle(frame, 0.2, Color3.fromRGB(255, 240, 180), Vector2.new(-0.18, -0.18))
	return frame
end

-- Blue gem: a rotated square with a lighter facet.
function Icons.gemDrawn(size: UDim2): GuiObject
	local frame = holder(size, "GemIcon")
	local body = Instance.new("Frame")
	body.AnchorPoint = Vector2.new(0.5, 0.5)
	body.Position = UDim2.fromScale(0.5, 0.5)
	body.Size = UDim2.fromScale(0.68, 0.68)
	body.Rotation = 45
	body.BackgroundColor3 = C.Gem
	body.BorderSizePixel = 0
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(Color3.fromRGB(190, 240, 255), Color3.fromRGB(30, 120, 220))
	gradient.Rotation = 45
	gradient.Parent = body
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.15, 0)
	corner.Parent = body
	body.Parent = frame
	return frame
end

function Icons.coin(size: UDim2): GuiObject
	return AssetLoader.image("CoinIcon", size, Icons.coinDrawn)
end

function Icons.gem(size: UDim2): GuiObject
	return AssetLoader.image("GemIcon", size, Icons.gemDrawn)
end

function Icons.currency(currency: string, size: UDim2): GuiObject
	return if currency == "Gems" then Icons.gem(size) else Icons.coin(size)
end

-- Two crossed bars ("close").
function Icons.close(size: UDim2, color: Color3?): Frame
	local frame = holder(size, "CloseIcon")
	for _, angle in { 45, -45 } do
		local bar = Instance.new("Frame")
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = UDim2.fromScale(0.5, 0.5)
		bar.Size = UDim2.new(0.9, 0, 0, 3)
		bar.Rotation = angle
		bar.BackgroundColor3 = color or C.Text
		bar.BorderSizePixel = 0
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 2)
		corner.Parent = bar
		bar.Parent = frame
	end
	return frame
end

-- A simple padlock (shackle ring + body).
function Icons.lock(size: UDim2): Frame
	local frame = holder(size, "LockIcon")
	local shackle = Instance.new("Frame")
	shackle.AnchorPoint = Vector2.new(0.5, 0)
	shackle.Position = UDim2.fromScale(0.5, 0.05)
	shackle.Size = UDim2.fromScale(0.5, 0.5)
	shackle.BackgroundTransparency = 1
	local stroke = Instance.new("UIStroke")
	stroke.Color = C.TextDim
	stroke.Thickness = 3
	stroke.Parent = shackle
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0.5, 0)
	round.Parent = shackle
	shackle.Parent = frame
	local body = Instance.new("Frame")
	body.AnchorPoint = Vector2.new(0.5, 1)
	body.Position = UDim2.fromScale(0.5, 0.98)
	body.Size = UDim2.fromScale(0.78, 0.55)
	body.BackgroundColor3 = C.TextDim
	body.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.18, 0)
	corner.Parent = body
	body.Parent = frame
	return frame
end

return Icons
