--!strict
--[[
	TimingBar.luau  (Client/UI)

	The classic 2-STAGE timing bar used in matches and at the driving range.

	    POWER      [██████████████▌·········|········]  62%      stage 1: click to lock
	                                ^ white tick = the power your aim reticle asks for
	    ACCURACY   [░░░░░░▒▒▒[ SWEET ]▒▒▒░░░░░░░░░░░]           stage 2: click on the sweet spot
	                         ▲ needle (left = early/slice, right = late/hook)

	It draws a GaugeView.Layout (shared, tested); it owns no timing logic. While a
	stage is not active its track dims, so it's always obvious which click is next.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GaugeView = require(ReplicatedStorage.GolfRivals.Shared.GaugeView)

local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Theme)

export type Bar = {
	Frame: Frame,
	set: (layout: GaugeView.Layout?, quality: string?) -> (),
	destroy: () -> (),
}

local TimingBar = {}

local C = Theme.Colors

function TimingBar.new(props: Kit.Props): Bar
	local frame = Kit.panel({ Size = UDim2.fromOffset(560, 124), Visible = false })
	for key, value in props do
		(frame :: any)[key] = value
	end

	local hint = Kit.label("", { Size = UDim2.new(1, -24, 0, 18), Position = UDim2.fromOffset(12, 6), TextSize = 13, Font = Theme.Fonts.Bold, TextColor3 = C.TextDim, TextXAlignment = Enum.TextXAlignment.Center, Parent = frame })

	-- ---- power track --------------------------------------------------------------------------
	Kit.label("POWER", { Size = UDim2.fromOffset(84, 30), Position = UDim2.fromOffset(12, 28), TextSize = 14, Font = Theme.Fonts.Title, Parent = frame })
	local powerTrack = Kit.new("Frame", {
		Size = UDim2.new(1, -184, 0, 26), Position = UDim2.fromOffset(96, 30), BackgroundColor3 = C.PanelDark, BorderSizePixel = 0, ClipsDescendants = true, Parent = frame,
	}, { Kit.corner(8), Kit.stroke(C.Stroke, 1.5) }) :: Frame
	local powerFill = Kit.new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = C.Accent, BorderSizePixel = 0, Parent = powerTrack }, {
		Kit.new("UIGradient", {
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(60, 200, 90)),
				ColorSequenceKeypoint.new(0.65, Color3.fromRGB(240, 210, 60)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(235, 80, 60)),
			}),
		}),
	}) :: Frame
	local target = Kit.new("Frame", { Size = UDim2.new(0, 3, 1, 0), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Visible = false, ZIndex = 3, Parent = powerTrack }) :: Frame
	local percent = Kit.label("0%", { Size = UDim2.fromOffset(76, 30), Position = UDim2.new(1, -84, 0, 28), TextSize = 22, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Right, Parent = frame })

	-- ---- accuracy track ------------------------------------------------------------------------
	Kit.label("ACCURACY", { Size = UDim2.fromOffset(84, 30), Position = UDim2.fromOffset(12, 68), TextSize = 14, Font = Theme.Fonts.Title, Parent = frame })
	local accuracyTrack = Kit.new("Frame", {
		Size = UDim2.new(1, -184, 0, 26), Position = UDim2.fromOffset(96, 70), BackgroundColor3 = Color3.fromRGB(120, 40, 48), BorderSizePixel = 0, Parent = frame,
	}, { Kit.corner(8), Kit.stroke(C.Stroke, 1.5) }) :: Frame
	local good = Kit.new("Frame", { BackgroundColor3 = Color3.fromRGB(230, 190, 60), BorderSizePixel = 0, Parent = accuracyTrack }) :: Frame
	local sweet = Kit.new("Frame", { BackgroundColor3 = Color3.fromRGB(70, 220, 110), BorderSizePixel = 0, ZIndex = 2, Parent = accuracyTrack }, {
		Kit.stroke(Color3.fromRGB(220, 255, 225), 1.5),
	}) :: Frame
	Kit.label("SWEET SPOT", { Size = UDim2.fromScale(1, 1), TextSize = 9, Font = Theme.Fonts.Title, TextColor3 = Color3.fromRGB(10, 50, 20), TextXAlignment = Enum.TextXAlignment.Center, TextScaled = false, ZIndex = 3, Parent = sweet })
	local needle = Kit.new("Frame", { Size = UDim2.new(0, 4, 1, 10), Position = UDim2.new(0, -2, 0, -5), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Visible = false, ZIndex = 4, Parent = accuracyTrack }, {
		Kit.corner(2),
		Kit.stroke(Color3.new(0, 0, 0), 1),
	}) :: Frame
	local qualityLabel = Kit.label("", { Size = UDim2.fromOffset(76, 30), Position = UDim2.new(1, -84, 0, 68), TextSize = 14, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Right, Parent = frame })
	Kit.label("SLICE", { Size = UDim2.fromOffset(60, 14), Position = UDim2.fromOffset(96, 100), TextSize = 10, TextColor3 = C.TextDim, Parent = frame })
	Kit.label("HOOK", { Size = UDim2.fromOffset(60, 14), Position = UDim2.new(1, -148, 0, 100), TextSize = 10, TextColor3 = C.TextDim, TextXAlignment = Enum.TextXAlignment.Right, Parent = frame })

	local function set(layout: GaugeView.Layout?, quality: string?)
		if layout == nil then
			frame.Visible = false
			return
		end
		frame.Visible = true
		local inPower = layout.Phase == "Power" or layout.Phase == "Idle"
		powerFill.Size = UDim2.fromScale(layout.PowerFill, 1)
		powerTrack.BackgroundTransparency = if inPower then 0 else 0.35
		target.Visible = layout.TargetPower ~= nil
		if layout.TargetPower then
			target.Position = UDim2.new(layout.TargetPower, -1, 0, 0)
		end
		percent.Text = `{math.floor(layout.PowerPercent + 0.5)}%`
		percent.TextColor3 = if layout.Locked then C.Gold else C.Text

		good.Position = UDim2.fromScale(layout.GoodLeft, 0)
		good.Size = UDim2.fromScale(layout.GoodRight - layout.GoodLeft, 1)
		sweet.Position = UDim2.fromScale(layout.SweetLeft, 0)
		sweet.Size = UDim2.fromScale(layout.SweetRight - layout.SweetLeft, 1)
		accuracyTrack.BackgroundTransparency = if inPower then 0.55 else 0
		needle.Visible = layout.NeedleX ~= nil
		if layout.NeedleX then
			needle.Position = UDim2.new(layout.NeedleX, -2, 0, -5)
		end

		local putting = layout.Mode == "Putt"
		hint.Text = if inPower then (if putting then "PUTT  ·  CLICK / SPACE TO SET THE PACE" else "CLICK / SPACE TO LOCK POWER")
			elseif layout.Phase == "Accuracy" then "CLICK WHEN THE NEEDLE IS ON THE SWEET SPOT"
			else ""
		qualityLabel.Text = quality or ""
		qualityLabel.TextColor3 = if quality == "PERFECT" then C.Good elseif quality == "GOOD" then C.Gold else C.Poor
	end

	return {
		Frame = frame,
		set = set,
		destroy = function()
			frame:Destroy()
		end,
	}
end

return TimingBar
