--!strict
--[[
	WheelScreen.luau  (Client/Lobby)

	The DAILY WHEELSPIN window (opened from the lobby tile or the 3D wheel's
	"Spin the wheel" prompt):

	  left    the wheel (WheelArt, identical to the 3D one) under a red pointer
	  right   free-spin status / countdown, bought spins, SPIN, buy a spin for gems,
	          buy a spin with Robux (Developer Product, only when
	          Config.Wheel.RobuxProductId is set), and the odds of every segment

	The SERVER rolls (SpinWheel) and replies with the segment and the exact angle to
	stop at; this screen only animates to it (ease-out over the server's duration)
	and announces the reward. The 3D lobby wheel spins at the same time for everyone
	(WheelController).
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Config = require(Shared.Config)
local Format = require(Shared.Format)
local ItemDatabase = require(Shared.ItemDatabase)
local Remotes = require(Shared.Remotes)
local WheelArt = require(Shared.WheelArt)
local WheelRules = require(Shared.WheelRules)

local Kit = require(script.Parent.Parent.UI.Kit)
local Theme = require(script.Parent.Parent.UI.Theme)
local Toast = require(script.Parent.Parent.UI.Toast)
local ModalHost = require(script.Parent.ModalHost)
local Reasons = require(script.Parent.Reasons)

local WheelScreen = {}

local C = Theme.Colors

-- "+1,500 coins" / "+25 gems" / "Unique: Aurora Trail".
function WheelScreen.rewardText(reward: any): string
	if type(reward) ~= "table" then
		return "a reward"
	end
	if reward.Kind == "Coins" then
		return `+{Format.commas(tonumber(reward.Amount) or 0)} coins`
	elseif reward.Kind == "Gems" then
		return `+{Format.commas(tonumber(reward.Amount) or 0)} gems`
	end
	local item = ItemDatabase.get(reward.ItemId)
	return if item then `{item.Rarity}: {item.Name}` else "a cosmetic item"
end

WheelScreen.factory = {
	Title = "DAILY WHEELSPIN",
	create = function(content: Frame, _host: ModalHost.Host): ModalHost.ScreenApi
		local state: any = nil
		local stateAt = 0.0
		local spinning = false
		local isOpen = false

		-- ---- the wheel (left) -------------------------------------------------------------------
		local stage = Kit.new("Frame", { Size = UDim2.new(0.5, -10, 1, 0), BackgroundTransparency = 1, Parent = content }) :: Frame
		local square = Kit.new("Frame", {
			Size = UDim2.new(1, -20, 1, -40), Position = UDim2.new(0.5, 0, 0.5, 14), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Parent = stage,
		}, { Kit.new("UIAspectRatioConstraint", { AspectRatio = 1 }) }) :: Frame
		local wheel = WheelArt.draw(square)
		local pointer = Kit.label("▼", {
			Size = UDim2.fromOffset(60, 54), Position = UDim2.new(0.5, 0, 0, -30), AnchorPoint = Vector2.new(0.5, 0), TextSize = 54, Font = Theme.Fonts.Title,
			TextColor3 = Color3.fromRGB(255, 70, 90), TextStrokeTransparency = 0, TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 8, Parent = square,
		})
		pointer.TextStrokeColor3 = Color3.new(1, 1, 1)

		-- ---- controls (right) ---------------------------------------------------------------------
		local side = Kit.new("Frame", { Size = UDim2.new(0.5, -10, 1, 0), Position = UDim2.new(0.5, 10, 0, 0), BackgroundTransparency = 1, Parent = content }) :: Frame
		local status = Kit.label("Loading...", { Size = UDim2.new(1, 0, 0, 34), TextSize = 26, Font = Theme.Fonts.Title, Parent = side })
		local sub = Kit.label("", { Size = UDim2.new(1, 0, 0, 22), Position = UDim2.fromOffset(0, 36), TextSize = 15, TextColor3 = C.TextDim, Parent = side })
		local result = Kit.label("", { Size = UDim2.new(1, 0, 0, 30), Position = UDim2.fromOffset(0, 62), TextSize = 22, Font = Theme.Fonts.Title, TextColor3 = C.Gold, Parent = side })

		local spinButton = Kit.button("SPIN!", "primary", nil, { Size = UDim2.new(1, 0, 0, 64), Position = UDim2.fromOffset(0, 100), TextSize = 30, Font = Theme.Fonts.Title, Parent = side })
		local gemButton, setGemButton = Kit.priceButton("BUY A SPIN", "Gems", tostring(Config.Wheel.GemSpinPrice), "purple", nil, {
			Size = UDim2.new(0.5, -5, 0, 46), Position = UDim2.fromOffset(0, 174), TextSize = 16, Parent = side,
		})
		local robuxButton = Kit.button("BUY WITH ROBUX", "gold", nil, {
			Size = UDim2.new(0.5, -5, 0, 46), Position = UDim2.new(0.5, 5, 0, 174), TextSize = 16, Visible = Config.Wheel.RobuxProductId > 0, Parent = side,
		})
		if Config.Wheel.RobuxProductId <= 0 then
			gemButton.Size = UDim2.new(1, 0, 0, 46)
		end

		Kit.label("ODDS", { Size = UDim2.new(1, 0, 0, 18), Position = UDim2.fromOffset(0, 232), TextSize = 13, TextColor3 = C.TextDim, Font = Theme.Fonts.Bold, Parent = side })
		local oddsList = Kit.new("ScrollingFrame", {
			Size = UDim2.new(1, 0, 1, -256), Position = UDim2.fromOffset(0, 254), BackgroundTransparency = 1, BorderSizePixel = 0,
			AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), ScrollBarThickness = 5, Parent = side,
		}, { Kit.list(Enum.FillDirection.Vertical, 4) }) :: ScrollingFrame
		local odds = WheelRules.odds()
		for index, segment in Config.Wheel.Segments do
			local row = Kit.new("Frame", { Size = UDim2.new(1, -8, 0, 26), BackgroundColor3 = C.PanelDark, BorderSizePixel = 0, LayoutOrder = index, Parent = oddsList }, { Kit.corner(6) }) :: Frame
			Kit.new("Frame", { Size = UDim2.fromOffset(12, 12), Position = UDim2.fromOffset(8, 7), BackgroundColor3 = Theme.rgb(segment.Color), BorderSizePixel = 0, Parent = row }, { Kit.corner(6) })
			local what = if segment.Kind == "Cosmetic" then `{segment.Rarity or ""} cosmetic` elseif segment.Kind == "Gems" then `{segment.Amount} gems` else `{Format.commas(segment.Amount or 0)} coins`
			Kit.label(if segment.Label == "JACKPOT" then `JACKPOT · {what}` else what, { Size = UDim2.new(1, -110, 1, 0), Position = UDim2.fromOffset(28, 0), TextSize = 14, Font = Theme.Fonts.Bold, Parent = row })
			Kit.label(string.format("%.1f%%", (odds[index] or 0) * 100), { Size = UDim2.fromOffset(70, 26), Position = UDim2.new(1, -78, 0, 0), TextSize = 14, TextColor3 = C.TextDim, TextXAlignment = Enum.TextXAlignment.Right, Parent = row })
		end

		-- ---- behaviour --------------------------------------------------------------------------------
		local function render()
			local s = state
			if s == nil then
				status.Text = "Loading..."
				return
			end
			local left = math.max(0, (tonumber(s.SecondsUntilFree) or 0) - (os.clock() - stateAt))
			local extra = tonumber(s.ExtraSpins) or 0
			if s.FreeReady or left <= 0 then
				status.Text = "FREE SPIN READY!"
				status.TextColor3 = C.Good
			else
				status.Text = `NEXT FREE SPIN IN {Format.countdown(left)}`
				status.TextColor3 = C.Text
			end
			sub.Text = if extra > 0 then `You have {extra} extra spin{if extra == 1 then "" else "s"}.` else "One free spin every 24 hours. Extra spins never expire."
			local canSpin = (s.FreeReady or left <= 0 or extra > 0) and not spinning
			spinButton.Text = if spinning then "SPINNING..." elseif canSpin then (if s.FreeReady or left <= 0 then "SPIN FREE!" else "SPIN (1 EXTRA)") else "NO SPINS LEFT"
			spinButton.AutoButtonColor = canSpin
			spinButton.BackgroundTransparency = if canSpin then 0 else 0.45
		end

		local function fetch()
			local reply = Remotes.invoke("GetWheel")
			if type(reply) == "table" and reply.ok then
				state, stateAt = reply.State, os.clock()
				render()
			end
		end

		local function spin()
			if spinning then
				return
			end
			spinning = true
			result.Text = ""
			render()
			local reply = Remotes.invoke("SpinWheel")
			if type(reply) ~= "table" or not reply.ok then
				spinning = false
				if type(reply) == "table" and reply.State then
					state, stateAt = reply.State, os.clock()
				end
				render()
				Toast.show(Reasons.text(if type(reply) == "table" then reply.reason else nil), "error")
				return
			end
			state, stateAt = reply.State, os.clock()
			local duration = tonumber(reply.Duration) or 5
			wheel.Rotation = wheel.Rotation % 360
			local tween = TweenService:Create(wheel, TweenInfo.new(duration, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Rotation = tonumber(reply.Angle) or 0 })
			tween:Play()
			tween.Completed:Wait()
			spinning = false
			local text = WheelScreen.rewardText(reply.Reward)
			result.Text = `YOU WON {string.upper(text)}`
			Toast.show(`Daily wheel: {text}!`, "success")
			render()
		end

		spinButton.Activated:Connect(function()
			task.spawn(spin)
		end)
		gemButton.Activated:Connect(function()
			if spinning then
				return
			end
			local reply = Remotes.invoke("BuyWheelSpin")
			if type(reply) == "table" and reply.ok then
				state, stateAt = reply.State, os.clock()
				Toast.show("Extra spin added!", "success")
				render()
			else
				Toast.show(Reasons.text(if type(reply) == "table" then reply.reason else nil), "error")
			end
		end)
		robuxButton.Activated:Connect(function()
			if Config.Wheel.RobuxProductId > 0 then
				MarketplaceService:PromptProductPurchase(Players.LocalPlayer, Config.Wheel.RobuxProductId)
			end
		end)
		-- A Robux purchase is granted by the server's ProcessReceipt; refresh after it.
		MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId: number, productId: number, purchased: boolean)
			if purchased and userId == Players.LocalPlayer.UserId and productId == Config.Wheel.RobuxProductId then
				task.delay(1.5, fetch)
			end
		end)
		setGemButton("BUY A SPIN", tostring(Config.Wheel.GemSpinPrice))

		return {
			refresh = render,
			onOpen = function()
				isOpen = true
				fetch()
				task.spawn(function()
					while isOpen do
						task.wait(1)
						if isOpen and not spinning then
							render()
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

return WheelScreen
