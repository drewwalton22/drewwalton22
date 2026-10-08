--!strict
--[[
	LobbyHud.luau  (Client/Lobby)

	The always-visible lobby overlay - clean, modern and kept clear of Roblox's own
	top-bar buttons (everything sits inside Kit.safeArea, which follows
	GuiService.TopbarInset):

	  top-left       profile card: avatar headshot, name, OVR
	  top-right      currency pills (drawn coin / gem icons) and "+"
	  left           2-column tile menu: Shop, Cases, Loadout, Inventory, Trade-Up,
	                 Quests (unclaimed-rewards badge), Daily Wheel ("FREE" badge when
	                 the free spin is ready), Leaderboard
	  bottom-centre  DRIVING RANGE  |  PLAY  |  AFK LOUNGE   (range and lounge walk
	                 you straight there)
	  top-centre     status banners: ranked search (with Cancel), AFK lounge / range
	                 progress

	Tile and button art comes from Assets.Images when uploaded; until then each tile
	draws a gradient plate with a glyph, so a missing asset id never shows a blank.
	It only displays and forwards clicks; LobbyController owns the behaviour.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Format = require(Shared.Format)
local Signal = require(Shared.Signal)

local AssetLoader = require(script.Parent.Parent.UI.AssetLoader)
local Kit = require(script.Parent.Parent.UI.Kit)
local Theme = require(script.Parent.Parent.UI.Theme)
local Icons = require(script.Parent.Parent.UI.Icons)

export type Hud = {
	Gui: ScreenGui,
	onOpen: Signal.Signal, -- fires (screenName: string)
	onTravel: Signal.Signal, -- fires (zone: "Range" | "Afk")
	onCancelQueue: Signal.Signal,
	onGetGems: Signal.Signal,
	setCurrency: (coins: number, gems: number) -> (),
	setOvr: (ovr: number) -> (),
	setQuestBadge: (count: number) -> (),
	setWheelBadge: (ready: boolean) -> (),
	setQueue: (text: string?) -> (),
	setZoneStatus: (text: string?, color: Color3?) -> (),
	setVisible: (visible: boolean) -> (),
}

local LobbyHud = {}

local C = Theme.Colors

type TileDef = { Screen: string, Label: string, Glyph: string, Asset: string, Variant: string }

local TILES: { TileDef } = {
	{ Screen = "Shop", Label = "SHOP", Glyph = "🛒", Asset = "ShopTile", Variant = "orange" },
	{ Screen = "Cases", Label = "CASES", Glyph = "📦", Asset = "CasesTile", Variant = "gold" },
	{ Screen = "Loadout", Label = "LOADOUT", Glyph = "🏌", Asset = "LoadoutTile", Variant = "secondary" },
	{ Screen = "Inventory", Label = "INVENTORY", Glyph = "🎒", Asset = "InventoryTile", Variant = "secondary" },
	{ Screen = "TradeUp", Label = "TRADE-UP", Glyph = "🔁", Asset = "TradeUpTile", Variant = "purple" },
	{ Screen = "Quests", Label = "QUESTS", Glyph = "📜", Asset = "QuestsTile", Variant = "teal" },
	{ Screen = "Wheel", Label = "DAILY SPIN", Glyph = "🎡", Asset = "WheelTile", Variant = "orange" },
	{ Screen = "Leaderboard", Label = "RANKS", Glyph = "🏆", Asset = "LeaderboardTile", Variant = "ghost" },
}

function LobbyHud.new(): Hud
	local gui = Kit.screenGui("GolfRivalsLobbyHud", 3)
	local safe = Kit.safeArea(gui)
	local opened, travel, cancel, getGems = Signal.new(), Signal.new(), Signal.new(), Signal.new()

	-- ---- profile card (top-left) ---------------------------------------------------------------
	local player = Players.LocalPlayer
	local card = Kit.panel({ Size = UDim2.fromOffset(260, 68), Parent = safe })
	local avatar = Kit.new("Frame", { Size = UDim2.fromOffset(52, 52), Position = UDim2.fromOffset(8, 8), BackgroundColor3 = C.Blue, BorderSizePixel = 0, Parent = card }, {
		Kit.corner(26),
		Kit.gradient(C.Blue, C.Purple),
	}) :: Frame
	Kit.label(string.upper(string.sub(player.DisplayName, 1, 1)), { Size = UDim2.fromScale(1, 1), TextSize = 26, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center, Parent = avatar })
	task.spawn(function()
		-- Headshot replaces the initial when it loads (falls back silently).
		local ok, image = pcall(function()
			return Players:GetUserThumbnailAsync(player.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
		end)
		if ok and type(image) == "string" and image ~= "" then
			Kit.new("ImageLabel", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Image = image, Parent = avatar }, { Kit.corner(26) })
		end
	end)
	Kit.label(player.DisplayName, { Size = UDim2.new(1, -78, 0, 24), Position = UDim2.fromOffset(70, 9), TextSize = 18, Font = Theme.Fonts.Title, TextTruncate = Enum.TextTruncate.AtEnd, Parent = card })
	local ovrPill = Kit.new("Frame", { Size = UDim2.fromOffset(78, 22), Position = UDim2.fromOffset(70, 37), BackgroundColor3 = C.Gold, BorderSizePixel = 0, Parent = card }, {
		Kit.corner(11),
		Kit.gradient(C.Gold, C.GoldDark),
	}) :: Frame
	local ovrLabel = Kit.label("OVR --", { Size = UDim2.fromScale(1, 1), TextSize = 14, Font = Theme.Fonts.Title, TextColor3 = Color3.fromRGB(40, 24, 0), TextXAlignment = Enum.TextXAlignment.Center, Parent = ovrPill })

	-- ---- currency (top-right): big bold counters, each with its own "+" ---------------------------
	local bar = Kit.new("Frame", { Size = UDim2.fromOffset(440, 58), Position = UDim2.fromScale(1, 0), AnchorPoint = Vector2.new(1, 0), BackgroundTransparency = 1, Parent = safe }, {
		Kit.list(Enum.FillDirection.Horizontal, 10, { HorizontalAlignment = Enum.HorizontalAlignment.Right, VerticalAlignment = Enum.VerticalAlignment.Center }),
	}) :: Frame
	local function pill(currency: string, order: number, onPlus: () -> ()): TextLabel
		local frame = Kit.panel({ Size = UDim2.fromOffset(204, 54), LayoutOrder = order, BackgroundColor3 = C.PanelDark, Parent = bar })
		local icon = Icons.currency(currency, UDim2.fromOffset(40, 40))
		icon.Position = UDim2.fromOffset(6, 7)
		icon.Parent = frame
		local label = Kit.label("0", {
			Size = UDim2.new(1, -100, 1, 0), Position = UDim2.fromOffset(50, 0), TextSize = 28, Font = Theme.Fonts.Display,
			TextColor3 = if currency == "Gems" then C.Gem else C.Gold, TextTruncate = Enum.TextTruncate.AtEnd, Parent = frame,
		})
		Kit.button("+", "primary", onPlus, {
			Size = UDim2.fromOffset(40, 40), Position = UDim2.new(1, -46, 0.5, -20), TextSize = 30, Font = Theme.Fonts.Display, Parent = frame,
		})
		return label
	end
	local coinLabel = pill("Coins", 1, function()
		opened.fire("Shop")
	end)
	local gemLabel = pill("Gems", 2, function()
		getGems.fire()
	end)

	-- ---- tile menu (left) ------------------------------------------------------------------------------
	local menu = Kit.new("Frame", { Size = UDim2.fromOffset(180, 4 * 88 + 3 * 10), Position = UDim2.new(0, 0, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), BackgroundTransparency = 1, Parent = safe }, {
		Kit.grid(UDim2.fromOffset(84, 88), 10),
	}) :: Frame
	local questBadge: TextLabel? = nil
	local wheelBadge: TextLabel? = nil
	for index, tile in TILES do
		local button = Kit.button("", tile.Variant, function()
			opened.fire(tile.Screen)
		end, { LayoutOrder = index, Parent = menu })
		local art = AssetLoader.image(tile.Asset, UDim2.fromOffset(52, 52), function(size: UDim2): GuiObject
			return Kit.label(tile.Glyph, { Size = size, TextSize = 36, TextXAlignment = Enum.TextXAlignment.Center })
		end)
		art.Position = UDim2.new(0.5, -26, 0, 4)
		art.Parent = button
		Kit.label(tile.Label, { Size = UDim2.new(1, -6, 0, 22), Position = UDim2.new(0, 3, 1, -26), TextScaled = true, Font = Theme.Fonts.Display, TextXAlignment = Enum.TextXAlignment.Center, Parent = button })
		if tile.Screen == "Quests" then
			questBadge = Kit.badge("0", C.Danger, {
				Size = UDim2.fromOffset(28, 28), Position = UDim2.new(1, -18, 0, -8), TextSize = 15, Visible = false, Parent = button,
			}, true)
		elseif tile.Screen == "Wheel" then
			wheelBadge = Kit.badge("FREE!", C.Pink, {
				Size = UDim2.fromOffset(54, 24), Position = UDim2.new(1, -38, 0, -10), Rotation = 8, Visible = false, Parent = button,
			}, true)
		end
	end

	-- ---- bottom buttons: big, slanted, glossy, with a shine sweeping across ----------------------------
	local bottom = Kit.new("Frame", { Size = UDim2.new(0, 760, 0, 120), Position = UDim2.fromScale(0.5, 1), AnchorPoint = Vector2.new(0.5, 1), BackgroundTransparency = 1, Parent = safe }, {
		Kit.list(Enum.FillDirection.Horizontal, 22, { HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Bottom }),
	}) :: Frame
	local function bigButton(title: string, subtitle: string, glyph: string, asset: string, variant: string, width: number, height: number, order: number, onClick: () -> ())
		-- A transparent slot keeps the list layout straight while the button inside leans.
		local slot = Kit.new("Frame", { Size = UDim2.fromOffset(width, height), BackgroundTransparency = 1, LayoutOrder = order, Parent = bottom }) :: Frame
		local button = Kit.button("", variant, onClick, {
			Size = UDim2.fromScale(1, 1), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), Rotation = -5, Parent = slot,
		})
		local art = AssetLoader.image(asset, UDim2.fromOffset(height * 0.55, height * 0.55), function(size: UDim2): GuiObject
			return Kit.label(glyph, { Size = size, TextScaled = true, TextXAlignment = Enum.TextXAlignment.Center })
		end)
		art.Position = UDim2.new(0, 10, 0.5, -height * 0.275)
		art.Parent = button
		local left = height * 0.55 + 16
		Kit.label(title, {
			Size = UDim2.new(1, -left - 10, 0.58, 0), Position = UDim2.new(0, left, 0.06, 0), TextScaled = true, Font = Theme.Fonts.Display,
			TextXAlignment = Enum.TextXAlignment.Left, Parent = button,
		})
		Kit.label(subtitle, {
			Size = UDim2.new(1, -left - 10, 0.26, 0), Position = UDim2.new(0, left, 0.64, 0), TextScaled = true, Font = Theme.Fonts.Bold,
			TextColor3 = Color3.fromRGB(255, 255, 255), TextXAlignment = Enum.TextXAlignment.Left, Parent = button,
		})
		-- Shine: a bright diagonal band sliding across every few seconds (a gradient
		-- offset tween, so it never spills outside the rotated button).
		local shine = Kit.new("Frame", { Name = "Shine", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.35, BorderSizePixel = 0, Active = false, Parent = button }, {
			Kit.corner(12),
		}) :: Frame
		local band = Kit.new("UIGradient", {
			Rotation = 20,
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.42, 1), NumberSequenceKeypoint.new(0.5, 0.2),
				NumberSequenceKeypoint.new(0.58, 1), NumberSequenceKeypoint.new(1, 1),
			}),
			Offset = Vector2.new(-1, 0),
			Parent = shine,
		}) :: UIGradient
		task.spawn(function()
			while button.Parent do
				band.Offset = Vector2.new(-1, 0)
				TweenService:Create(band, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), { Offset = Vector2.new(1, 0) }):Play()
				task.wait(3.2 + order * 0.4)
			end
		end)
	end
	bigButton("DRIVING RANGE", "Hit targets, earn coins", "🎯", "RangeButton", "secondary", 230, 84, 1, function()
		travel.fire("Range")
	end)
	bigButton("PLAY", "Ranked & practice", "⛳", "PlayButton", "orange", 270, 112, 2, function()
		opened.fire("Play")
	end)
	bigButton("AFK LOUNGE", "Relax, earn coins", "🌴", "AfkButton", "purple", 230, 84, 3, function()
		travel.fire("Afk")
	end)

	-- ---- status banners (top-centre) -------------------------------------------------------------------------------
	local banners = Kit.new("Frame", { Size = UDim2.fromOffset(480, 130), Position = UDim2.fromScale(0.5, 0), AnchorPoint = Vector2.new(0.5, 0), BackgroundTransparency = 1, Parent = safe }, {
		Kit.list(Enum.FillDirection.Vertical, 8, { HorizontalAlignment = Enum.HorizontalAlignment.Center }),
	}) :: Frame
	local queue = Kit.panel({ Size = UDim2.fromOffset(470, 54), Visible = false, LayoutOrder = 1, Parent = banners })
	local queueLabel = Kit.label("", { Size = UDim2.new(1, -130, 1, 0), Position = UDim2.fromOffset(16, 0), TextSize = 15, Font = Theme.Fonts.Bold, Parent = queue })
	Kit.button("CANCEL", "danger", function()
		cancel.fire()
	end, { Size = UDim2.fromOffset(100, 36), Position = UDim2.new(1, -112, 0.5, -18), TextSize = 14, Parent = queue })
	local zone = Kit.panel({ Size = UDim2.fromOffset(470, 44), Visible = false, LayoutOrder = 2, Parent = banners })
	local zoneLabel = Kit.label("", { Size = UDim2.new(1, -24, 1, 0), Position = UDim2.fromOffset(12, 0), TextSize = 15, Font = Theme.Fonts.Bold, TextXAlignment = Enum.TextXAlignment.Center, Parent = zone })

	return {
		Gui = gui,
		onOpen = opened,
		onTravel = travel,
		onCancelQueue = cancel,
		onGetGems = getGems,
		setCurrency = function(coins: number, gems: number)
			coinLabel.Text = Format.commas(coins)
			gemLabel.Text = Format.commas(gems)
		end,
		setOvr = function(ovr: number)
			ovrLabel.Text = `OVR {ovr}`
		end,
		setQuestBadge = function(count: number)
			if questBadge then
				questBadge.Visible = count > 0
				questBadge.Text = tostring(count)
			end
		end,
		setWheelBadge = function(ready: boolean)
			if wheelBadge then
				wheelBadge.Visible = ready
			end
		end,
		setQueue = function(text: string?)
			queue.Visible = text ~= nil
			queueLabel.Text = text or ""
		end,
		setZoneStatus = function(text: string?, color: Color3?)
			zone.Visible = text ~= nil
			zoneLabel.Text = text or ""
			zoneLabel.TextColor3 = color or C.Text
		end,
		setVisible = function(visible: boolean)
			gui.Enabled = visible
		end,
	}
end

return LobbyHud
