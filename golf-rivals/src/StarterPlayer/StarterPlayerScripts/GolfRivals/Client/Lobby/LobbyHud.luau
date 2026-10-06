--!strict
--[[
	LobbyHud.luau  (Client/Lobby)

	The always-visible lobby overlay (mockup panel 1):

	  top-left      player card: name and OVR
	  top-right     coins and gems
	  left          menu: Shop, Cases, Quests (with a badge for unclaimed rewards),
	                Leaderboard
	  bottom-centre PLAY, LOADOUT, TRADE-UP
	  top-centre    "searching for an opponent" banner with Cancel while queued

	It only displays and forwards clicks; LobbyController owns the behaviour.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Format = require(Shared.Format)
local Signal = require(Shared.Signal)

local Theme = require(script.Parent.Parent.UI.Theme)
local Kit = require(script.Parent.Parent.UI.Kit)

export type Hud = {
	Gui: ScreenGui,
	onOpen: Signal.Signal, -- fires (screenName: string)
	onCancelQueue: Signal.Signal,
	setCurrency: (coins: number, gems: number) -> (),
	setOvr: (ovr: number) -> (),
	setQuestBadge: (count: number) -> (),
	setQueue: (text: string?) -> (),
	setVisible: (visible: boolean) -> (),
}

local LobbyHud = {}

local C = Theme.Colors

function LobbyHud.new(): Hud
	local gui = Kit.screenGui("GolfRivalsLobbyHud", 3)
	local opened, cancel = Signal.new(), Signal.new()

	-- ---- player card ---------------------------------------------------------------------
	local card = Kit.panel({ Size = UDim2.fromOffset(250, 64), Position = UDim2.fromOffset(16, 16), Parent = gui })
	Kit.label(Players.LocalPlayer.DisplayName, { Size = UDim2.new(1, -90, 0, 26), Position = UDim2.fromOffset(14, 8), TextSize = 18, TextTruncate = Enum.TextTruncate.AtEnd, Parent = card })
	local ovrLabel = Kit.label("OVR --", { Size = UDim2.new(1, -90, 0, 20), Position = UDim2.fromOffset(14, 34), TextSize = 15, TextColor3 = C.Gold, Font = Theme.Fonts.Title, Parent = card })
	Kit.label("👑", { Size = UDim2.fromOffset(50, 50), Position = UDim2.new(1, -60, 0, 7), TextSize = 32, TextXAlignment = Enum.TextXAlignment.Center, Parent = card })

	-- ---- currency (top-right) ------------------------------------------------------------------
	local bar = Kit.new("Frame", { Size = UDim2.fromOffset(330, 44), Position = UDim2.new(1, -346, 0, 16), BackgroundTransparency = 1, Parent = gui }, {
		Kit.list(Enum.FillDirection.Horizontal, 8, { HorizontalAlignment = Enum.HorizontalAlignment.Right }),
	}) :: Frame
	local function chip(icon: string, color: Color3, order: number): TextLabel
		local frame = Kit.panel({ Size = UDim2.fromOffset(150, 44), LayoutOrder = order, Parent = bar })
		Kit.label(icon, { Size = UDim2.fromOffset(36, 44), Position = UDim2.fromOffset(8, 0), TextSize = 22, TextXAlignment = Enum.TextXAlignment.Center, Parent = frame })
		return Kit.label("0", { Size = UDim2.new(1, -52, 1, 0), Position = UDim2.fromOffset(46, 0), TextSize = 19, TextColor3 = color, Font = Theme.Fonts.Title, Parent = frame })
	end
	local coinLabel = chip("🪙", C.Gold, 1)
	local gemLabel = chip("💎", C.Gem, 2)
	Kit.button("+", "primary", function()
		require(script.Parent.Parent.UI.Toast).show("Gem purchases are coming soon!", "info")
	end, { Size = UDim2.fromOffset(34, 34), LayoutOrder = 3, TextSize = 22, Parent = bar })

	-- ---- left menu ---------------------------------------------------------------------------------
	local menu = Kit.new("Frame", { Size = UDim2.fromOffset(170, 250), Position = UDim2.new(0, 16, 0.5, -125), BackgroundTransparency = 1, Parent = gui }, {
		Kit.list(Enum.FillDirection.Vertical, 10),
	}) :: Frame
	local questBadge: TextLabel? = nil
	for index, entry in { { "🛒  SHOP", "Shop" }, { "📦  CASES", "Cases" }, { "📜  QUESTS", "Quests" }, { "🏆  LEADERBOARD", "Leaderboard" } } do
		local button = Kit.button(entry[1], "ghost", function()
			opened.fire(entry[2])
		end, { Size = UDim2.new(1, 0, 0, 52), TextSize = 17, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = index, Parent = menu })
		Kit.new("UIPadding", { PaddingLeft = UDim.new(0, 16), Parent = button })
		Kit.stroke().Parent = button
		if entry[2] == "Quests" then
			questBadge = Kit.label("0", {
				Size = UDim2.fromOffset(24, 24), Position = UDim2.new(1, -32, 0.5, -12), TextSize = 14, Font = Theme.Fonts.Title, BackgroundColor3 = C.Danger,
				BackgroundTransparency = 0, TextXAlignment = Enum.TextXAlignment.Center, Visible = false, Parent = button,
			})
			Kit.corner(12).Parent = questBadge
		end
	end

	-- ---- bottom buttons --------------------------------------------------------------------------------
	local bottom = Kit.new("Frame", { Size = UDim2.fromOffset(560, 70), Position = UDim2.new(0.5, -280, 1, -96), BackgroundTransparency = 1, Parent = gui }, {
		Kit.list(Enum.FillDirection.Horizontal, 14, { HorizontalAlignment = Enum.HorizontalAlignment.Center }),
	}) :: Frame
	Kit.button("⛳  PLAY", "primary", function()
		opened.fire("Play")
	end, { Size = UDim2.fromOffset(220, 64), TextSize = 24, LayoutOrder = 1, Parent = bottom })
	Kit.button("🏌  LOADOUT", "secondary", function()
		opened.fire("Loadout")
	end, { Size = UDim2.fromOffset(160, 64), TextSize = 17, LayoutOrder = 2, Parent = bottom })
	Kit.button("🔁  TRADE-UP", "ghost", function()
		opened.fire("TradeUp")
	end, { Size = UDim2.fromOffset(160, 64), TextSize = 17, LayoutOrder = 3, Parent = bottom })

	-- ---- queue banner ------------------------------------------------------------------------------------------
	local queue = Kit.panel({ Size = UDim2.fromOffset(470, 54), Position = UDim2.new(0.5, -235, 0, 92), Visible = false, Parent = gui })
	local queueLabel = Kit.label("", { Size = UDim2.new(1, -130, 1, 0), Position = UDim2.fromOffset(16, 0), TextSize = 15, Font = Theme.Fonts.Bold, Parent = queue })
	Kit.button("CANCEL", "danger", function()
		cancel.fire()
	end, { Size = UDim2.fromOffset(100, 36), Position = UDim2.new(1, -112, 0.5, -18), TextSize = 14, Parent = queue })

	return {
		Gui = gui,
		onOpen = opened,
		onCancelQueue = cancel,
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
		setQueue = function(text: string?)
			queue.Visible = text ~= nil
			queueLabel.Text = text or ""
		end,
		setVisible = function(visible: boolean)
			gui.Enabled = visible
		end,
	}
end

return LobbyHud
