--!strict
--[[
	ItemCard.luau  (Client/UI)

	One reusable card for any cosmetic or reward: a rarity-coloured frame, a preview
	tile tinted with the item's own colours and a glyph for its type, the name, a
	slot/subtitle line, and a footer (price, "EQUIPPED", "x3"...). Used by the shop,
	cases, trade-up and loadout screens so every item looks the same everywhere.

	Cards are plain Frames; pass `OnClick` to make the whole card a button.
]]

local Theme = require(script.Parent.Theme)
local Kit = require(script.Parent.Kit)

local ItemCard = {}

export type Props = {
	Name: string,
	Color: { number }, -- rarity colour (RGB)
	Subtitle: string?,
	Primary: { number }?, -- preview tint
	Secondary: { number }?,
	Glyph: string?,
	Footer: string?,
	FooterColor: Color3?,
	Badge: string?, -- small corner tag: "NEW", "x3", "LOCKED"
	Locked: boolean?,
	Selected: boolean?,
	Size: UDim2?,
	OnClick: (() -> ())?,
	LayoutOrder: number?,
}

local GLYPHS: { [string]: string } = {
	Driver = "🏌", Wood = "🏌", Iron = "🏌", Wedge = "🏌", Putter = "🏌",
	Swing = "💪", Stance = "🧍", Emote = "🎉",
	BallModel = "⚪", BallTrail = "☄", HoleEffect = "🎆",
}

function ItemCard.glyphFor(slot: string): string
	return GLYPHS[slot] or "⭐"
end

local function rgb(c: { number }?, fallback: Color3): Color3
	if c == nil then
		return fallback
	end
	return Color3.fromRGB(c[1], c[2], c[3])
end

function ItemCard.new(props: Props): Frame
	local rarity = rgb(props.Color, Theme.Colors.Stroke)
	local locked = props.Locked == true
	local card = Kit.panel({
		Size = props.Size or UDim2.fromOffset(120, 150),
		BackgroundColor3 = Theme.Colors.PanelDark,
		LayoutOrder = props.LayoutOrder or 0,
	})
	local stroke = card:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = if props.Selected then Theme.Colors.Text else rarity
		stroke.Thickness = if props.Selected then 3 else 2
	end

	-- Preview tile.
	local primary = rgb(props.Primary, rarity)
	local secondary = rgb(props.Secondary, primary)
	local tile = Kit.new("Frame", {
		Size = UDim2.new(1, -12, 0, 72), Position = UDim2.fromOffset(6, 6), BackgroundColor3 = primary, BorderSizePixel = 0, Parent = card,
	}, {
		Kit.corner(8),
		Kit.new("UIGradient", { Color = ColorSequence.new(primary, secondary), Rotation = 45 }),
	}) :: Frame
	Kit.label(props.Glyph or "⭐", {
		Size = UDim2.fromScale(1, 1), TextSize = 34, TextXAlignment = Enum.TextXAlignment.Center,
		TextTransparency = if locked then 0.6 else 0, Parent = tile,
	})
	if locked then
		tile.BackgroundTransparency = 0.5
		Kit.label("🔒", { Size = UDim2.fromScale(1, 1), TextSize = 24, TextXAlignment = Enum.TextXAlignment.Center, Parent = tile })
	end

	Kit.label(props.Name, {
		Size = UDim2.new(1, -10, 0, 18), Position = UDim2.fromOffset(6, 82), TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd, Parent = card,
	})
	if props.Subtitle then
		Kit.label(props.Subtitle, {
			Size = UDim2.new(1, -10, 0, 14), Position = UDim2.fromOffset(6, 99), TextSize = 11, TextColor3 = rarity, Font = Theme.Fonts.Bold,
			TextTruncate = Enum.TextTruncate.AtEnd, Parent = card,
		})
	end
	if props.Footer then
		Kit.label(props.Footer, {
			Size = UDim2.new(1, -10, 0, 20), Position = UDim2.new(0, 6, 1, -26), TextSize = 14, TextColor3 = props.FooterColor or Theme.Colors.Text,
			Font = Theme.Fonts.Bold, Parent = card,
		})
	end
	if props.Badge then
		Kit.label(props.Badge, {
			Size = UDim2.fromOffset(46, 18), Position = UDim2.new(1, -52, 0, 10), TextSize = 11, Font = Theme.Fonts.Title,
			BackgroundTransparency = 0.15, BackgroundColor3 = rarity, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = Color3.new(0, 0, 0),
			Parent = card,
		}).ZIndex = 3
	end
	if props.OnClick then
		local button = Kit.new("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", ZIndex = 5, Parent = card }) :: TextButton
		button.Activated:Connect(props.OnClick)
	end
	return card
end

return ItemCard
