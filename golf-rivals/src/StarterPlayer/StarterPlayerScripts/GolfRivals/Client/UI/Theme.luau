--!strict
--[[
	Theme.luau  (Client/UI)

	Colours, fonts and sizes shared by every screen, so the whole UI reads as one
	product (dark navy panels, green primary action, gold currency, rarity colours
	taken from Rarity.lua so they match the item cards).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Rarity = require(ReplicatedStorage.GolfRivals.Shared.Rarity)
local Types = require(ReplicatedStorage.GolfRivals.Shared.Types)

local Theme = {}

Theme.Colors = {
	Background = Color3.fromRGB(10, 15, 28),
	Panel = Color3.fromRGB(18, 26, 46),
	PanelLight = Color3.fromRGB(28, 40, 68),
	PanelDark = Color3.fromRGB(12, 18, 34),
	Stroke = Color3.fromRGB(52, 70, 110),
	Text = Color3.fromRGB(240, 244, 255),
	TextDim = Color3.fromRGB(150, 164, 196),
	Accent = Color3.fromRGB(34, 197, 94), -- primary action (green)
	AccentDark = Color3.fromRGB(21, 128, 61),
	Blue = Color3.fromRGB(43, 127, 255),
	Gold = Color3.fromRGB(255, 196, 40),
	Gem = Color3.fromRGB(80, 200, 255),
	Danger = Color3.fromRGB(239, 68, 68),
	Good = Color3.fromRGB(74, 222, 128),
	Poor = Color3.fromRGB(248, 113, 113),
}

Theme.Fonts = {
	Title = Enum.Font.GothamBlack,
	Bold = Enum.Font.GothamBold,
	Body = Enum.Font.Gotham,
}

Theme.CornerRadius = UDim.new(0, 10)

function Theme.rgb(color: { number }): Color3
	return Color3.fromRGB(color[1], color[2], color[3])
end

function Theme.rarity(id: Types.RarityId): Color3
	return Theme.rgb(Rarity.Info[id].Color)
end

return Theme
