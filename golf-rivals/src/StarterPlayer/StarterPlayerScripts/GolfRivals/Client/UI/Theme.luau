--!strict
--[[
	Theme.luau  (Client/UI)

	Colours, fonts and sizes shared by every screen, so the whole UI reads as one
	modern product: deep-navy glass panels, a vivid green primary action, gold
	currency, rarity colours taken from Rarity (so they match the item cards).

	Fonts use Roblox's Builder Sans family (crisp at every size, full Latin
	coverage). Glyphs that Roblox's emoji font can't draw (the coin emoji, the
	"x" close mark) are never used as text: UI/Icons draws them with frames.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Rarity = require(ReplicatedStorage.GolfRivals.Shared.Rarity)
local Types = require(ReplicatedStorage.GolfRivals.Shared.Types)

local Theme = {}

Theme.Colors = {
	Background = Color3.fromRGB(8, 12, 24),
	Panel = Color3.fromRGB(16, 23, 42),
	PanelLight = Color3.fromRGB(30, 42, 72),
	PanelDark = Color3.fromRGB(10, 15, 30),
	Stroke = Color3.fromRGB(56, 74, 118),
	StrokeSoft = Color3.fromRGB(38, 52, 86),
	Text = Color3.fromRGB(244, 247, 255),
	TextDim = Color3.fromRGB(150, 164, 196),
	Accent = Color3.fromRGB(34, 197, 94), -- primary action (green)
	AccentDark = Color3.fromRGB(21, 128, 61),
	Blue = Color3.fromRGB(43, 127, 255),
	BlueDark = Color3.fromRGB(29, 78, 216),
	Purple = Color3.fromRGB(150, 90, 255),
	PurpleDark = Color3.fromRGB(96, 50, 200),
	Teal = Color3.fromRGB(20, 190, 200),
	TealDark = Color3.fromRGB(12, 120, 140),
	Orange = Color3.fromRGB(255, 140, 50),
	OrangeDark = Color3.fromRGB(200, 80, 20),
	Gold = Color3.fromRGB(255, 196, 40),
	GoldDark = Color3.fromRGB(196, 128, 16),
	Gem = Color3.fromRGB(80, 200, 255),
	Danger = Color3.fromRGB(239, 68, 68),
	DangerDark = Color3.fromRGB(170, 30, 40),
	Good = Color3.fromRGB(74, 222, 128),
	Poor = Color3.fromRGB(248, 113, 113),
	Glow = Color3.fromRGB(96, 140, 255), -- soft outer glow on panels
	GlowAccent = Color3.fromRGB(90, 255, 170), -- the active control's glow
	Track = Color3.fromRGB(6, 10, 22), -- inset meter tracks
}

Theme.Fonts = {
	Title = Enum.Font.BuilderSansExtraBold,
	Bold = Enum.Font.BuilderSansBold,
	Body = Enum.Font.BuilderSansMedium,
}

Theme.CornerRadius = UDim.new(0, 12)
Theme.PanelTransparency = 0.16 -- semi-translucent dark glass over the 3D world
Theme.GlowTransparency = 0.45 -- panel border glow
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
} :: { [string]: { Color3 } }

return Theme
