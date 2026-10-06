--!strict
--[[
	QuestsScreen.luau  (Client/Lobby)

	The Quest Board (mockup panel 11): Daily / Weekly / Lifetime tabs, each quest with a
	progress bar, its reward and a CLAIM button. Quests come from the server (GetQuests,
	which also rolls over to a new day or week); claiming calls ClaimQuest. While the
	window is open the board re-fetches every few seconds so progress made in a match
	shows up without reopening it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Format = require(Shared.Format)
local Remotes = require(Shared.Remotes)

local Kit = require(script.Parent.Parent.UI.Kit)
local Theme = require(script.Parent.Parent.UI.Theme)
local Toast = require(script.Parent.Parent.UI.Toast)
local ModalHost = require(script.Parent.ModalHost)
local Reasons = require(script.Parent.Reasons)

local QuestsScreen = {}

local C = Theme.Colors

local function rewardText(reward: any): string
	local parts: { string } = {}
	if type(reward.Coins) == "number" then
		table.insert(parts, `🪙 {Format.commas(reward.Coins)}`)
	end
	if type(reward.Gems) == "number" then
		table.insert(parts, `💎 {Format.commas(reward.Gems)}`)
	end
	return table.concat(parts, "   ")
end

QuestsScreen.factory = {
	Title = "📜  QUEST BOARD",
	create = function(content: Frame, _host: ModalHost.Host): ModalHost.ScreenApi
		local periods: { any } = {}
		local serverOffset = 0 -- serverNow - os.time(), so countdowns use server time
		local tab = "Daily"
		local isOpen = false

		local tabRow = Kit.new("Frame", { Size = UDim2.new(1, 0, 0, 44), BackgroundTransparency = 1, Parent = content }, {
			Kit.list(Enum.FillDirection.Horizontal, 8),
		}) :: Frame
		local resetLabel = Kit.label("", { Size = UDim2.new(0, 360, 0, 40), Position = UDim2.new(1, -360, 0, 2), TextSize = 14, TextColor3 = C.TextDim, TextXAlignment = Enum.TextXAlignment.Right, Parent = content })
		local list = Kit.new("ScrollingFrame", {
			Size = UDim2.new(1, 0, 1, -56), Position = UDim2.fromOffset(0, 54), BackgroundTransparency = 1, BorderSizePixel = 0,
			CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 6, Parent = content,
		}, { Kit.list(Enum.FillDirection.Vertical, 8), Kit.padding(2) }) :: ScrollingFrame

		local render: () -> ()

		local function fetch()
			local reply = Remotes.invoke("GetQuests")
			if type(reply) == "table" and reply.ok then
				periods = reply.Periods
				serverOffset = reply.Now - os.time()
				render()
			end
		end

		render = function()
			Kit.clear(tabRow)
			local current: any = nil
			for index, period in periods do
				if period.Period == tab then
					current = period
				end
				local claimable = 0
				for _, quest in period.Quests do
					if quest.Complete and not quest.Claimed then
						claimable += 1
					end
				end
				Kit.button(`{string.upper(period.Period)}{if claimable > 0 then `  ●{claimable}` else ""}`, if period.Period == tab then "secondary" else "ghost", function()
					tab = period.Period
					render()
				end, { Size = UDim2.fromOffset(150, 40), TextSize = 14, LayoutOrder = index, Parent = tabRow })
			end
			Kit.clear(list)
			if current == nil then
				Kit.label("Loading quests...", { Size = UDim2.new(1, 0, 0, 30), TextColor3 = C.TextDim, Parent = list })
				return
			end
			resetLabel.Text = if current.ResetsAt then `RESETS IN {Format.countdown(current.ResetsAt - (os.time() + serverOffset))}` else "ACHIEVEMENTS NEVER RESET"
			for index, quest in current.Quests do
				local row = Kit.panel({ Size = UDim2.new(1, -8, 0, 68), LayoutOrder = index, Parent = list })
				Kit.label(quest.Name, { Size = UDim2.new(0.5, 0, 0, 24), Position = UDim2.fromOffset(16, 8), TextSize = 17, Font = Theme.Fonts.Bold, Parent = row })
				local ratio = if quest.Target > 0 then math.clamp(quest.Progress / quest.Target, 0, 1) else 0
				local bar = Kit.new("Frame", { Size = UDim2.new(0.5, -20, 0, 14), Position = UDim2.fromOffset(16, 42), BackgroundColor3 = C.PanelDark, BorderSizePixel = 0, Parent = row }, { Kit.corner(7) }) :: Frame
				Kit.new("Frame", { Size = UDim2.fromScale(ratio, 1), BackgroundColor3 = if quest.Complete then C.Good else C.Blue, BorderSizePixel = 0, Parent = bar }, { Kit.corner(7) })
				Kit.label(`{Format.commas(quest.Progress)} / {Format.commas(quest.Target)}`, { Size = UDim2.fromOffset(150, 20), Position = UDim2.new(0.5, 0, 0, 40), TextSize = 13, TextColor3 = C.TextDim, Parent = row })
				Kit.label(rewardText(quest.Reward), { Size = UDim2.fromOffset(200, 24), Position = UDim2.new(1, -330, 0, 22), TextSize = 17, Font = Theme.Fonts.Bold, TextColor3 = C.Gold, Parent = row })
				local label = if quest.Claimed then "CLAIMED" elseif quest.Complete then "CLAIM" else "IN PROGRESS"
				Kit.button(label, if quest.Complete and not quest.Claimed then "primary" else "ghost", function()
					if quest.Claimed or not quest.Complete then
						return
					end
					local reply = Remotes.invoke("ClaimQuest", quest.Id)
					if type(reply) == "table" and reply.ok then
						Toast.show(`Reward claimed: {rewardText(quest.Reward)}`, "success")
					else
						Toast.show(Reasons.text(if type(reply) == "table" then reply.reason else nil), "error")
					end
					fetch()
				end, { Size = UDim2.fromOffset(120, 40), Position = UDim2.new(1, -136, 0.5, -20), TextSize = 14, Parent = row })
			end
		end

		return {
			refresh = render,
			onOpen = function()
				isOpen = true
				task.spawn(function()
					while isOpen do
						fetch()
						for _ = 1, 5 do
							if not isOpen then
								return
							end
							task.wait(1)
							if isOpen and #periods > 0 then
								render() -- keeps the reset countdown ticking
							end
						end
					end
				end)
			end,
			onClose = function()
				isOpen = false
			end,
		}
	end,
} :: ModalHost.Factory

return QuestsScreen
