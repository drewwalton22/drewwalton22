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

	-- ---- currency (top-right) -----------------------------------------------------------------------
	local bar = Kit.new("Frame", { Size = UDim2.fromOffset(360, 46), Position = UDim2.fromScale(1, 0), AnchorPoint = Vector2.new(1, 0), BackgroundTransparency = 1, Parent = safe }, {
		Kit.list(Enum.FillDirection.Horizontal, 8, { HorizontalAlignment = Enum.HorizontalAlignment.Right, VerticalAlignment = Enum.VerticalAlignment.Center }),
	}) :: Frame
	local function pill(currency: string, order: number): TextLabel
		local frame = Kit.panel({ Size = UDim2.fromOffset(150, 44), LayoutOrder = order, Parent = bar })
		local icon = Icons.currency(currency, UDim2.fromOffset(28, 28))
		icon.Position = UDim2.fromOffset(10, 8)
		icon.Parent = frame
		return Kit.label("0", {
			Size = UDim2.new(1, -52, 1, 0), Position = UDim2.fromOffset(46, 0), TextSize = 20, Font = Theme.Fonts.Title,
			TextColor3 = if currency == "Gems" then C.Gem else C.Gold, TextTruncate = Enum.TextTruncate.AtEnd, Parent = frame,
		})
	end
	local coinLabel = pill("Coins", 1)
	local gemLabel = pill("Gems", 2)
	Kit.button("+", "primary", function()
		getGems.fire()
	end, { Size = UDim2.fromOffset(40, 40), LayoutOrder = 3, TextSize = 26, Font = Theme.Fonts.Title, Parent = bar })

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
		Kit.stroke(Color3.new(1, 1, 1), 1.5).Parent = button
		local art = AssetLoader.image(tile.Asset, UDim2.fromOffset(52, 52), function(size: UDim2): GuiObject
			return Kit.label(tile.Glyph, { Size = size, TextSize = 36, TextXAlignment = Enum.TextXAlignment.Center })
		end)
		art.Position = UDim2.new(0.5, -26, 0, 4)
		art.Parent = button
		Kit.label(tile.Label, { Size = UDim2.new(1, -6, 0, 22), Position = UDim2.new(0, 3, 1, -26), TextSize = 12, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center, Parent = button })
		if tile.Screen == "Quests" then
			local badge = Kit.label("0", {
				Size = UDim2.fromOffset(26, 26), Position = UDim2.new(1, -18, 0, -8), TextSize = 14, Font = Theme.Fonts.Title, BackgroundColor3 = C.Danger,
				BackgroundTransparency = 0, TextXAlignment = Enum.TextXAlignment.Center, Visible = false, ZIndex = 3, Parent = button,
			})
			Kit.corner(13).Parent = badge
			Kit.stroke(Color3.new(1, 1, 1), 2).Parent = badge
			questBadge = badge
		elseif tile.Screen == "Wheel" then
			local badge = Kit.label("FREE", {
				Size = UDim2.fromOffset(44, 22), Position = UDim2.new(1, -30, 0, -8), TextSize = 12, Font = Theme.Fonts.Title, BackgroundColor3 = C.Good,
				BackgroundTransparency = 0, TextXAlignment = Enum.TextXAlignment.Center, Visible = false, ZIndex = 3, Parent = button,
			})
			Kit.corner(11).Parent = badge
			Kit.stroke(Color3.new(1, 1, 1), 2).Parent = badge
			wheelBadge = badge
		end
	end

	-- ---- bottom buttons ------------------------------------------------------------------------------------
	local bottom = Kit.new("Frame", { Size = UDim2.new(0, 640, 0, 92), Position = UDim2.fromScale(0.5, 1), AnchorPoint = Vector2.new(0.5, 1), BackgroundTransparency = 1, Parent = safe }, {
		Kit.list(Enum.FillDirection.Horizontal, 14, { HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Bottom }),
	}) :: Frame
	local function bigButton(title: string, subtitle: string, variant: string, width: number, height: number, order: number, onClick: () -> ())
		local button = Kit.button("", variant, onClick, { Size = UDim2.fromOffset(width, height), LayoutOrder = order, Parent = bottom })
		Kit.stroke(Color3.new(1, 1, 1), 2).Parent = button
		Kit.label(title, { Size = UDim2.new(1, -12, 0.6, 0), Position = UDim2.fromOffset(6, 4), TextSize = if height > 80 then 34 else 20, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center, Parent = button })
		Kit.label(subtitle, { Size = UDim2.new(1, -12, 0.3, 0), Position = UDim2.new(0, 6, 0.62, 0), TextSize = 13, Font = Theme.Fonts.Bold, TextColor3 = Color3.fromRGB(230, 240, 255), TextXAlignment = Enum.TextXAlignment.Center, Parent = button })
	end
	bigButton("DRIVING RANGE", "Hit targets · earn coins", "secondary", 190, 70, 1, function()
		travel.fire("Range")
	end)
	bigButton("PLAY", "Ranked & practice", "primary", 220, 90, 2, function()
		opened.fire("Play")
	end)
	bigButton("AFK LOUNGE", "Relax · earn coins", "teal", 190, 70, 3, function()
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
