--!strict
--[[
	Theme.luau  (Client/UI)

	Colours, fonts and sizes shared by every screen. The look is a bright,
	chunky CARTOON style: vivid gradient buttons and panels with thick dark
	outlines, glossy highlight strips, bold rounded fonts with a dark outline on
	all text (UI/TextOutline), bouncy buttons and pulsing badges.

	Fonts: Luckiest Guy (Display: big titles and the main lobby buttons) and
	Fredoka One (everything else), both built into Roblox. Glyphs that Roblox's
	emoji font can't draw (the coin emoji, the "x" close mark) are never used as
	text: UI/Icons draws them with frames.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Rarity = require(ReplicatedStorage.GolfRivals.Shared.Rarity)
local Types = require(ReplicatedStorage.GolfRivals.Shared.Types)

local Theme = {}

Theme.Colors = {
	Background = Color3.fromRGB(22, 26, 70),
	Panel = Color3.fromRGB(52, 74, 178), -- vivid royal blue
	PanelLight = Color3.fromRGB(88, 120, 235),
	PanelDark = Color3.fromRGB(32, 42, 112),
	Stroke = Color3.fromRGB(18, 16, 44), -- the thick dark cartoon outline
	StrokeSoft = Color3.fromRGB(70, 92, 190),
	Text = Color3.fromRGB(255, 255, 255),
	TextDim = Color3.fromRGB(206, 218, 255),
	Accent = Color3.fromRGB(96, 236, 84), -- primary action (green)
	AccentDark = Color3.fromRGB(28, 168, 60),
	Blue = Color3.fromRGB(72, 182, 255),
	BlueDark = Color3.fromRGB(34, 96, 236),
	Purple = Color3.fromRGB(196, 116, 255),
	PurpleDark = Color3.fromRGB(122, 52, 232),
	Teal = Color3.fromRGB(52, 236, 222),
	TealDark = Color3.fromRGB(12, 152, 176),
	Orange = Color3.fromRGB(255, 176, 52),
	OrangeDark = Color3.fromRGB(242, 92, 30),
	Gold = Color3.fromRGB(255, 214, 56),
	GoldDark = Color3.fromRGB(240, 142, 18),
	Gem = Color3.fromRGB(92, 214, 255),
	Pink = Color3.fromRGB(255, 102, 196),
	PinkDark = Color3.fromRGB(210, 40, 140),
	Danger = Color3.fromRGB(255, 92, 92),
	DangerDark = Color3.fromRGB(200, 28, 54),
	Good = Color3.fromRGB(110, 240, 120),
	Poor = Color3.fromRGB(255, 120, 120),
	Glow = Color3.fromRGB(120, 170, 255), -- soft outer glow
	GlowAccent = Color3.fromRGB(120, 255, 170), -- the active control's glow
	Track = Color3.fromRGB(16, 20, 58), -- inset meter tracks
	Neon = Color3.fromRGB(80, 255, 240), -- neon accents (lobby)
}

Theme.Fonts = {
	Display = Enum.Font.LuckiestGuy, -- big titles, PLAY / DRIVING RANGE / AFK LOUNGE
	Title = Enum.Font.FredokaOne,
	Bold = Enum.Font.FredokaOne,
	Body = Enum.Font.FredokaOne,
}

Theme.CornerRadius = UDim.new(0, 14)
Theme.PanelTransparency = 0.06 -- near-solid, colourful panels
Theme.GlowTransparency = 0.45 -- soft glow strokes (Kit.glow)
Theme.OutlineThickness = 3 -- dark border on buttons and panels
Theme.Gutter = 14 -- distance from the safe-area edges

function Theme.rgb(color: { number }): Color3
	return Color3.fromRGB(color[1], color[2], color[3])
end

function Theme.rarity(id: Types.RarityId): Color3
	return Theme.rgb(Rarity.Info[id].Color)
end

-- Button / tile colour pairs (top, bottom of the vertical gradient).
Theme.Variants = {
	primary = { Theme.Colors.Accent, Theme.Colors.AccentDark },
	secondary = { Theme.Colors.Blue, Theme.Colors.BlueDark },
	ghost = { Theme.Colors.PanelLight, Theme.Colors.Panel },
	danger = { Theme.Colors.Danger, Theme.Colors.DangerDark },
	gold = { Theme.Colors.Gold, Theme.Colors.GoldDark },
	purple = { Theme.Colors.Purple, Theme.Colors.PurpleDark },
	teal = { Theme.Colors.Teal, Theme.Colors.TealDark },
	orange = { Theme.Colors.Orange, Theme.Colors.OrangeDark },
	pink = { Theme.Colors.Pink, Theme.Colors.PinkDark },
} :: { [string]: { Color3 } }

return Theme
