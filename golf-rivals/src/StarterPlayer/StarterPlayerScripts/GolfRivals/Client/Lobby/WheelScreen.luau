--!strict
--[[
	WheelScreen.luau  (Client/Lobby)

	The DAILY WHEELSPIN window (opened from the lobby tile or the 3D wheel's
	"Spin the wheel" prompt). Modern layout: a glowing stage for the wheel on the
	left, glassy cards with gradients and soft glow strokes on the right.

	  left    the wheel (WheelArt - the very same drawing as the 3D wheel) under the
	          pointer; when it stops, a RESULT CARD pops up in the landed segment's
	          colour with the same icon (the segment under the pointer is the
	          server's roll: checked offline in tools/verify_features.luau)
	  right   status card (free spin ready / countdown, stored spins), SPIN, buy a
	          spin with gems, buy with Robux (Developer Product, shown when
	          Config.Wheel.RobuxProductId is set), and the odds card

	SYNC WITH THE 3D WHEEL: the server rolls (SpinWheel) and replies with the
	spin's start angle, resting angle, server start time and duration - exactly
	what it writes on the lobby wheel's attributes. Every frame this screen sets
	its wheel to WheelRules.spinAngle(from, to, start, duration, serverNow): the
	same function and the same server clock as the 3D wheel (WheelController), so
	both show the same slice at every moment and stop on the rewarded slice. When
	someone else spins, the screen mirrors the 3D wheel too.

	ODDS: WheelRules.odds() returns fractions (weight / total weight); shown x100.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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
local WheelController = require(script.Parent.WheelController)

local WheelScreen = {}

local C = Theme.Colors

type Spin = { From: number, To: number, Start: number, Duration: number }

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

-- A glassy card: dark translucent panel, sheen gradient, soft glow stroke.
local function card(props: Kit.Props): Frame
	local frame = Kit.panel(props)
	frame.BackgroundColor3 = C.PanelDark
	return frame
end

WheelScreen.factory = {
	Title = "DAILY WHEELSPIN",
	create = function(content: Frame, _host: ModalHost.Host): ModalHost.ScreenApi
		local state: any = nil
		local stateAt = 0.0
		local spinning = false
		local isOpen = false
		local mySpin: Spin? = nil

		-- ---- the wheel stage (left) ----------------------------------------------------------------
		local stage = Kit.new("Frame", {
			Size = UDim2.new(0.5, -10, 1, 0), BackgroundColor3 = Color3.fromRGB(10, 12, 28), BackgroundTransparency = 0.1, BorderSizePixel = 0, Parent = content,
		}, {
			Kit.corner(18),
			Kit.glow(C.Purple, 2, 0.45),
			Kit.new("UIGradient", {
				Color = ColorSequence.new(Color3.fromRGB(70, 60, 140), Color3.fromRGB(16, 18, 40)),
				Rotation = 90,
			}),
		}) :: Frame
		local square = Kit.new("Frame", {
			Size = UDim2.new(1, -60, 1, -70), Position = UDim2.new(0.5, 0, 0.5, 16), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Parent = stage,
		}, { Kit.new("UIAspectRatioConstraint", { AspectRatio = 1 }) }) :: Frame
		local wheel = WheelArt.draw(square)
		local currentAngle = 0
		local function setAngle(angle: number)
			if angle ~= currentAngle then
				currentAngle = angle
				wheel.setAngle(angle)
			end
		end
		-- Pointer at 12 o'clock: a red diamond whose lower tip touches the rim exactly
		-- above the centre line (angle 0), where WheelRules measures the result.
		local pointer = Kit.new("Frame", {
			Size = UDim2.fromScale(0.085, 0.085), Position = UDim2.fromScale(0.5, 0.005), AnchorPoint = Vector2.new(0.5, 0.5), Rotation = 45,
			BackgroundColor3 = Color3.fromRGB(255, 70, 96), BorderSizePixel = 0, ZIndex = 40, Parent = square,
		}, {
			Kit.corner(4),
			Kit.new("UIStroke", { Color = Color3.fromRGB(24, 18, 40), Thickness = 3 }),
			Kit.new("UIGradient", { Color = ColorSequence.new(Color3.fromRGB(255, 160, 175), Color3.fromRGB(200, 30, 60)), Rotation = 45 }),
		}) :: Frame
		Kit.new("Frame", {
			Size = UDim2.fromScale(0.3, 0.3), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0, ZIndex = 41, Parent = pointer,
		}, { Kit.corner(99) })
		local banner = Kit.label("", {
			Size = UDim2.new(1, -40, 0, 40), Position = UDim2.fromOffset(20, 10), TextSize = 26, Font = Theme.Fonts.Title,
			TextColor3 = C.Gold, TextXAlignment = Enum.TextXAlignment.Center, TextStrokeTransparency = 0.4, ZIndex = 10, Parent = stage,
		})

		-- RESULT CARD: pops up over the wheel when it stops, in the landed segment's
		-- colour with the SAME icon and label as the wedge under the pointer.
		local result = Kit.new("Frame", {
			Size = UDim2.fromScale(0.62, 0.44), Position = UDim2.fromScale(0.5, 0.56), AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ZIndex = 50, Visible = false, Parent = stage,
		}, {
			Kit.corner(18),
			Kit.new("UIStroke", { Color = Color3.fromRGB(24, 18, 40), Thickness = 4 }),
		}) :: Frame
		local resultGradient = Kit.new("UIGradient", { Rotation = 90, Parent = result }) :: UIGradient
		local resultScale = Kit.new("UIScale", { Scale = 1, Parent = result }) :: UIScale
		local resultTitle = Kit.label("YOU WON!", {
			Size = UDim2.fromScale(0.9, 0.2), Position = UDim2.fromScale(0.05, 0.04), TextScaled = true, Font = Theme.Fonts.Title,
			TextColor3 = Color3.new(1, 1, 1), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 52, Parent = result,
		})
		Kit.new("UIStroke", { Color = Color3.fromRGB(24, 18, 40), Thickness = 3, Parent = resultTitle })
		local resultIcon = Kit.new("Frame", {
			Size = UDim2.fromScale(0.3, 0.3), Position = UDim2.fromScale(0.5, 0.42), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, ZIndex = 52, Parent = result,
		}, { Kit.new("UIAspectRatioConstraint", { AspectRatio = 1 }) }) :: Frame
		local resultText = Kit.label("", {
			Size = UDim2.fromScale(0.9, 0.24), Position = UDim2.fromScale(0.05, 0.6), TextScaled = true, Font = Theme.Fonts.Title,
			TextColor3 = Color3.new(1, 1, 1), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 52, Parent = result,
		})
		Kit.new("UIStroke", { Color = Color3.fromRGB(24, 18, 40), Thickness = 3, Parent = resultText })
		local resultHint = Kit.label("tap to close", {
			Size = UDim2.fromScale(0.9, 0.1), Position = UDim2.fromScale(0.05, 0.86), TextScaled = true,
			TextColor3 = Color3.fromRGB(255, 255, 255), TextTransparency = 0.25, TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 52, Parent = result,
		})
		resultHint.Name = "Hint"
		local closeResult = Kit.new("TextButton", {
			Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", ZIndex = 55, Parent = result,
		}) :: TextButton
		closeResult.Activated:Connect(function()
			result.Visible = false
		end)
		local function showResult(segmentIndex: number, reward: any)
			local segment = Config.Wheel.Segments[segmentIndex]
			if segment == nil then
				return
			end
			for _, child in resultIcon:GetChildren() do
				if not child:IsA("UIAspectRatioConstraint") then
					child:Destroy()
				end
			end
			WheelArt.icon(segment, resultIcon, 53)
			local color = Theme.rgb(segment.Color)
			resultGradient.Color = ColorSequence.new(color:Lerp(Color3.new(1, 1, 1), 0.25), color:Lerp(Color3.new(0, 0, 0), 0.35))
			resultTitle.Text = if segment.Label == "JACKPOT" then "JACKPOT!" else "YOU WON!"
			resultText.Text = string.upper(WheelScreen.rewardText(reward))
			result.Visible = true
			resultScale.Scale = 0.6
			TweenService:Create(resultScale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end

		-- ---- status + buttons (right) --------------------------------------------------------------
		local side = Kit.new("Frame", { Size = UDim2.new(0.5, -10, 1, 0), Position = UDim2.new(0.5, 10, 0, 0), BackgroundTransparency = 1, Parent = content }) :: Frame
		local statusCard = card({ Size = UDim2.new(1, 0, 0, 84), Parent = side })
		local status = Kit.label("Loading...", { Size = UDim2.new(1, -28, 0, 34), Position = UDim2.fromOffset(14, 10), TextScaled = true, Font = Theme.Fonts.Title, Parent = statusCard })
		Kit.new("UITextSizeConstraint", { MaxTextSize = 26, Parent = status }) -- shrinks on narrow screens instead of overflowing
		local sub = Kit.label("", { Size = UDim2.new(1, -28, 0, 22), Position = UDim2.fromOffset(14, 48), TextSize = 15, TextColor3 = C.TextDim, Parent = statusCard })

		local spinButton = Kit.button("SPIN!", "primary", nil, { Size = UDim2.new(1, 0, 0, 64), Position = UDim2.fromOffset(0, 96), TextSize = 30, Font = Theme.Fonts.Title, Parent = side })
		local spinGlow = Kit.glow(C.GlowAccent, 3, 0.25) :: UIStroke
		spinGlow.Parent = spinButton
		local gemButton = Kit.priceButton("BUY A SPIN", "Gems", tostring(Config.Wheel.GemSpinPrice), "purple", nil, {
			Size = UDim2.new(0.5, -5, 0, 46), Position = UDim2.fromOffset(0, 172), TextSize = 16, Parent = side,
		})
		local robuxButton = Kit.button("BUY WITH ROBUX", "gold", nil, {
			Size = UDim2.new(0.5, -5, 0, 46), Position = UDim2.new(0.5, 5, 0, 172), TextSize = 16, Visible = Config.Wheel.RobuxProductId > 0, Parent = side,
		})
		if Config.Wheel.RobuxProductId <= 0 then
			gemButton.Size = UDim2.new(1, 0, 0, 46)
		end

		local oddsCard = card({ Size = UDim2.new(1, 0, 1, -230), Position = UDim2.fromOffset(0, 230), Parent = side })
		Kit.label("DROP RATES", { Size = UDim2.new(1, -28, 0, 20), Position = UDim2.fromOffset(14, 8), TextSize = 13, TextColor3 = C.TextDim, Font = Theme.Fonts.Title, Parent = oddsCard })
		local oddsList = Kit.new("ScrollingFrame", {
			Size = UDim2.new(1, -16, 1, -36), Position = UDim2.fromOffset(8, 30), BackgroundTransparency = 1, BorderSizePixel = 0,
			AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), ScrollBarThickness = 4, Parent = oddsCard,
		}, { Kit.list(Enum.FillDirection.Vertical, 4) }) :: ScrollingFrame
		local odds = WheelRules.odds()
		local topChance = math.max(table.unpack(odds))
		for index, segment in Config.Wheel.Segments do
			local row = Kit.new("Frame", { Size = UDim2.new(1, -6, 0, 26), BackgroundColor3 = C.Panel, BackgroundTransparency = 0.25, BorderSizePixel = 0, LayoutOrder = index, Parent = oddsList }, {
				Kit.corner(8),
			}) :: Frame
			Kit.new("Frame", { Size = UDim2.fromOffset(12, 12), Position = UDim2.fromOffset(8, 7), BackgroundColor3 = Theme.rgb(segment.Color), BorderSizePixel = 0, Parent = row }, {
				Kit.corner(6),
				Kit.glow(Theme.rgb(segment.Color), 1.5, 0.3),
			})
			local what = if segment.Kind == "Cosmetic" then `{segment.Rarity or ""} cosmetic` elseif segment.Kind == "Gems" then `{segment.Amount} gems` else `{Format.commas(segment.Amount or 0)} coins`
			Kit.label(if segment.Label == "JACKPOT" then `JACKPOT · {what}` else what, { Size = UDim2.new(1, -150, 1, 0), Position = UDim2.fromOffset(28, 0), TextSize = 14, Font = Theme.Fonts.Bold, Parent = row })
			-- A small bar showing the chance, plus the exact percentage.
			local chance = odds[index] or 0
			local barTrack = Kit.new("Frame", { Size = UDim2.fromOffset(56, 6), Position = UDim2.new(1, -124, 0.5, -3), BackgroundColor3 = C.Track, BorderSizePixel = 0, Parent = row }, { Kit.corner(3) }) :: Frame
			Kit.new("Frame", { Size = UDim2.fromScale(math.clamp(chance / math.max(topChance, 1e-9), 0, 1), 1), BackgroundColor3 = Theme.rgb(segment.Color), BorderSizePixel = 0, Parent = barTrack }, { Kit.corner(3) })
			Kit.label(string.format("%.1f%%", chance * 100), { Size = UDim2.fromOffset(58, 26), Position = UDim2.new(1, -64, 0, 0), TextSize = 14, TextColor3 = C.TextDim, TextXAlignment = Enum.TextXAlignment.Right, Parent = row })
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
			local free = s.FreeReady or left <= 0
			if free then
				status.Text = "FREE SPIN READY!"
				status.TextColor3 = C.Good
			else
				status.Text = `NEXT FREE SPIN IN {Format.countdown(left)}`
				status.TextColor3 = C.Text
			end
			sub.Text = if extra > 0 then `You have {extra} extra spin{if extra == 1 then "" else "s"}.` else "One free spin every 24 hours. Extra spins never expire."
			local canSpin = (free or extra > 0) and not spinning
			spinButton.Text = if spinning then "SPINNING..." elseif canSpin then (if free then "SPIN FREE!" else "SPIN (1 EXTRA)") else "NO SPINS LEFT"
			spinButton.AutoButtonColor = canSpin
			spinButton.BackgroundTransparency = if canSpin then 0 else 0.45
			spinGlow.Enabled = canSpin
		end

		-- Every frame while open: the wheel shows the synced spin angle.
		local frameConnection: RBXScriptConnection? = nil
		local function follow()
			local now = workspace:GetServerTimeNow()
			local spin = mySpin
			if spin then
				setAngle(WheelRules.spinAngle(spin.From, spin.To, spin.Start, spin.Duration, now))
				return
			end
			local part = WheelController.wheelPart()
			if part then
				setAngle(WheelController.angleAt(part, now)) -- mirror the 3D wheel
			end
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
			banner.Text = ""
			result.Visible = false
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
			local spinData: Spin = {
				From = tonumber(reply.From) or (currentAngle % 360),
				To = tonumber(reply.Angle) or 0,
				Start = tonumber(reply.Start) or workspace:GetServerTimeNow(),
				Duration = duration,
			}
			mySpin = spinData
			-- Wait for the shared clock to reach the end of the spin.
			while workspace:GetServerTimeNow() < spinData.Start + duration do
				task.wait()
			end
			setAngle(spinData.To) -- exactly the resting angle of the rewarded slice
			mySpin = nil
			spinning = false
			local text = WheelScreen.rewardText(reply.Reward)
			banner.Text = ""
			-- The card shows the segment under the pointer, which IS the server's roll
			-- (WheelRules.segmentAt(restingAngle(i)) == i, checked offline).
			showResult(WheelRules.segmentAt(spinData.To), reply.Reward)
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

		return {
			refresh = render,
			onOpen = function()
				isOpen = true
				fetch()
				if frameConnection == nil then
					frameConnection = RunService.RenderStepped:Connect(follow)
				end
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
				local connection = frameConnection
				if connection then
					connection:Disconnect()
					frameConnection = nil
				end
			end,
		}
	end,
} :: ModalHost.Factory

return WheelScreen
