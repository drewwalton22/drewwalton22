--!strict
--[[
	ModeScreen.luau  (Client/Lobby)

	PLAY: ranked leagues (mockup panel 8) and free practice against a bot.

	Ranked: the entry fee is charged by the server when you queue and refunded if you
	cancel. Choosing a league sends QueueRanked; on success the window closes and the
	lobby shows the searching banner (Bus.QueueStarted). Bots start a match straight
	away; the first MatchState from the server takes over the screen.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local ModeView = require(Shared.ModeView)
local Remotes = require(Shared.Remotes)

local Bus = require(script.Parent.Parent.Bus)
local ClientState = require(script.Parent.Parent.ClientState)
local Kit = require(script.Parent.Parent.UI.Kit)
local Theme = require(script.Parent.Parent.UI.Theme)
local Toast = require(script.Parent.Parent.UI.Toast)
local ModalHost = require(script.Parent.ModalHost)
local Reasons = require(script.Parent.Reasons)

local ModeScreen = {}

local C = Theme.Colors

local LEAGUE_COLORS: { [string]: Color3 } = {
	Rookie = Color3.fromRGB(80, 200, 120),
	Amateur = Color3.fromRGB(70, 150, 255),
	Pro = Color3.fromRGB(170, 100, 255),
	Champion = Color3.fromRGB(255, 190, 40),
}

ModeScreen.factory = {
	Title = "⛳  PLAY",
	create = function(content: Frame, host: ModalHost.Host): ModalHost.ScreenApi
		Kit.label("RANKED LEAGUES", { Size = UDim2.new(1, 0, 0, 24), TextSize = 16, TextColor3 = C.TextDim, Font = Theme.Fonts.Bold, Parent = content })
		local leagueRow = Kit.new("Frame", { Size = UDim2.new(1, 0, 0, 250), Position = UDim2.fromOffset(0, 28), BackgroundTransparency = 1, Parent = content }, {
			Kit.list(Enum.FillDirection.Horizontal, 14),
		}) :: Frame
		Kit.label("PRACTICE VS BOT  (no entry fee)", { Size = UDim2.new(1, 0, 0, 24), Position = UDim2.fromOffset(0, 292), TextSize = 16, TextColor3 = C.TextDim, Font = Theme.Fonts.Bold, Parent = content })
		local botRow = Kit.new("Frame", { Size = UDim2.new(1, 0, 0, 150), Position = UDim2.fromOffset(0, 322), BackgroundTransparency = 1, Parent = content }, {
			Kit.list(Enum.FillDirection.Horizontal, 14),
		}) :: Frame

		local busy = false

		local function render()
			local profile = ClientState.get()
			if profile == nil then
				return
			end
			Kit.clear(leagueRow)
			for index, league in ModeView.leagues(profile) do
				local accent = LEAGUE_COLORS[league.Id] or C.Blue
				local card = Kit.panel({ Size = UDim2.new(0.25, -11, 1, 0), LayoutOrder = index, Parent = leagueRow })
				local stroke = card:FindFirstChildOfClass("UIStroke")
				if stroke then
					stroke.Color = accent
					stroke.Thickness = 2.5
				end
				Kit.label("🛡", { Size = UDim2.new(1, 0, 0, 56), Position = UDim2.fromOffset(0, 10), TextSize = 44, TextXAlignment = Enum.TextXAlignment.Center, Parent = card })
				Kit.label(string.upper(league.DisplayName), { Size = UDim2.new(1, -16, 0, 24), Position = UDim2.fromOffset(8, 68), TextSize = 17, Font = Theme.Fonts.Title, TextColor3 = accent, TextXAlignment = Enum.TextXAlignment.Center, Parent = card })
				Kit.label(`Entry fee   🪙 {league.FeeText}`, { Size = UDim2.new(1, -16, 0, 20), Position = UDim2.fromOffset(8, 104), TextSize = 14, TextColor3 = C.TextDim, TextXAlignment = Enum.TextXAlignment.Center, Parent = card })
				Kit.label(`Win   🪙 {league.PayoutText}`, { Size = UDim2.new(1, -16, 0, 22), Position = UDim2.fromOffset(8, 126), TextSize = 17, Font = Theme.Fonts.Bold, TextColor3 = C.Gold, TextXAlignment = Enum.TextXAlignment.Center, Parent = card })
				local queued = Bus.Queued
				local label = if queued then "IN QUEUE" elseif league.CanAfford then "FIND MATCH" else `NEED {league.Shortfall} MORE`
				Kit.button(label, if league.CanAfford and not queued then "primary" else "ghost", function()
					if busy or queued or not league.CanAfford then
						if not league.CanAfford then
							Toast.show("You can't afford that entry fee yet.", "error")
						end
						return
					end
					busy = true
					local reply = Remotes.invoke("QueueRanked", league.Id)
					busy = false
					if type(reply) == "table" and reply.ok then
						Bus.Queued = true
						Bus.QueueStarted.fire(league.Id)
						host.close()
					else
						Toast.show(Reasons.text(if type(reply) == "table" then reply.reason else nil), "error")
					end
				end, { Size = UDim2.new(1, -24, 0, 42), Position = UDim2.new(0, 12, 1, -54), TextSize = 14, Parent = card })
			end

			Kit.clear(botRow)
			for index, bot in ModeView.bots() do
				local card = Kit.panel({ Size = UDim2.new(1 / 3, -10, 1, 0), LayoutOrder = index, Parent = botRow })
				Kit.label(`🤖  {bot.Label}`, { Size = UDim2.new(1, -20, 0, 28), Position = UDim2.fromOffset(12, 10), TextSize = 20, Font = Theme.Fonts.Title, Parent = card })
				Kit.label(bot.Blurb, { Size = UDim2.new(1, -20, 0, 36), Position = UDim2.fromOffset(12, 40), TextSize = 13, TextColor3 = C.TextDim, Parent = card })
				Kit.label(`OVR {bot.Ovr}`, { Size = UDim2.new(0.4, 0, 0, 22), Position = UDim2.fromOffset(12, 84), TextSize = 15, TextColor3 = C.Gold, Font = Theme.Fonts.Bold, Parent = card })
				Kit.button("PLAY", "secondary", function()
					if busy or Bus.Queued then
						Toast.show("Cancel your search first.", "error")
						return
					end
					busy = true
					local reply = Remotes.invoke("StartBotMatch", bot.Difficulty)
					busy = false
					if type(reply) == "table" and reply.ok then
						host.close()
					else
						Toast.show(Reasons.text(if type(reply) == "table" then reply.reason else nil), "error")
					end
				end, { Size = UDim2.fromOffset(110, 36), Position = UDim2.new(1, -122, 1, -46), TextSize = 15, Parent = card })
			end
		end

		Bus.QueueStarted.connect(function()
			render()
		end)
		Bus.QueueEnded.connect(function()
			render()
		end)
		return { refresh = render }
	end,
} :: ModalHost.Factory

return ModeScreen
