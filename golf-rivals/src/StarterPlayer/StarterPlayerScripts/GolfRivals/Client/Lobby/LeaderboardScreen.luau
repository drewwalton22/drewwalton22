--!strict
--[[
	LeaderboardScreen.luau  (Client/Lobby)

	Top players by OVR. The server caches the board for a minute, so opening this is
	cheap. Your own row is highlighted; your current OVR is shown at the bottom even if
	you aren't in the top 25.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Remotes = require(Shared.Remotes)

local Kit = require(script.Parent.Parent.UI.Kit)
local Theme = require(script.Parent.Parent.UI.Theme)
local ModalHost = require(script.Parent.ModalHost)

local LeaderboardScreen = {}

local C = Theme.Colors

LeaderboardScreen.factory = {
	Title = "🏆  LEADERBOARD",
	create = function(content: Frame, _host: ModalHost.Host): ModalHost.ScreenApi
		local entries: { any } = {}
		local yourOvr = 0
		local loaded = false

		local header = Kit.label("RANK     PLAYER                                                     OVR", { Size = UDim2.new(1, 0, 0, 24), TextSize = 13, TextColor3 = C.TextDim, Parent = content })
		header.Font = Theme.Fonts.Bold
		local list = Kit.new("ScrollingFrame", {
			Size = UDim2.new(1, 0, 1, -70), Position = UDim2.fromOffset(0, 28), BackgroundTransparency = 1, BorderSizePixel = 0,
			CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 6, Parent = content,
		}, { Kit.list(Enum.FillDirection.Vertical, 6), Kit.padding(2) }) :: ScrollingFrame
		local footer = Kit.label("", { Size = UDim2.new(1, 0, 0, 30), Position = UDim2.new(0, 0, 1, -34), TextSize = 18, Font = Theme.Fonts.Bold, TextColor3 = C.Gold, Parent = content })

		local function render()
			Kit.clear(list)
			if not loaded then
				Kit.label("Loading...", { Size = UDim2.new(1, 0, 0, 30), TextColor3 = C.TextDim, Parent = list })
			elseif #entries == 0 then
				Kit.label("No ranked players yet. Be the first!", { Size = UDim2.new(1, 0, 0, 30), TextColor3 = C.TextDim, Parent = list })
			end
			local myId = Players.LocalPlayer.UserId
			for index, entry in entries do
				local mine = entry.UserId == myId
				local row = Kit.panel({ Size = UDim2.new(1, -8, 0, 44), BackgroundColor3 = if mine then C.PanelLight else C.Panel, LayoutOrder = index, Parent = list })
				local rankColor = if entry.Rank == 1 then C.Gold elseif entry.Rank == 2 then Color3.fromRGB(200, 205, 215) elseif entry.Rank == 3 then Color3.fromRGB(205, 140, 90) else C.TextDim
				Kit.label(`#{entry.Rank}`, { Size = UDim2.fromOffset(70, 44), Position = UDim2.fromOffset(16, 0), TextSize = 20, Font = Theme.Fonts.Title, TextColor3 = rankColor, Parent = row })
				Kit.label(entry.Name .. (if mine then "  (you)" else ""), { Size = UDim2.new(1, -220, 1, 0), Position = UDim2.fromOffset(96, 0), TextSize = 17, TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
				Kit.label(tostring(entry.Ovr), { Size = UDim2.fromOffset(90, 44), Position = UDim2.new(1, -106, 0, 0), TextSize = 22, Font = Theme.Fonts.Title, TextColor3 = C.Gold, TextXAlignment = Enum.TextXAlignment.Right, Parent = row })
			end
			footer.Text = `YOUR OVR: {yourOvr}`
		end

		return {
			refresh = render,
			onOpen = function()
				task.spawn(function()
					local reply = Remotes.invoke("GetLeaderboard")
					if type(reply) == "table" and reply.ok then
						entries, yourOvr, loaded = reply.Entries, reply.YourOvr, true
					end
					render()
				end)
			end,
		}
	end,
} :: ModalHost.Factory

return LeaderboardScreen
