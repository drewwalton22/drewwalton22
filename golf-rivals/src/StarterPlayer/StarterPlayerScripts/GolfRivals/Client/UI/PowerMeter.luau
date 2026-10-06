--!strict
--[[
	PowerMeter.luau  (Client/UI)

	The vertical 3-click power meter used in matches and at the driving range.

	    100% -- top
	      |   fill rises while you charge (click 2 locks it, a white tick stays)
	      |
	     ZERO -- the green "perfect" band: click 3 when the falling marker is here
	      |   below = clicked too late (hook)
	    bottom

	It draws a GaugeView.Layout (shared, tested): GaugeView's horizontal 0..1 axis
	maps to this bar's height (y = 1 - x). A big percentage readout sits on top and
	a one-line instruction underneath ("CLICK TO START" ...).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GaugeView = require(ReplicatedStorage.GolfRivals.Shared.GaugeView)

local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Theme)

export type Meter = {
	Frame: Frame,
	set: (layout: GaugeView.Layout?, quality: string?) -> (),
	destroy: () -> (),
}

local PowerMeter = {}

local C = Theme.Colors

function PowerMeter.new(props: Kit.Props): Meter
	local frame = Kit.panel({ Size = UDim2.fromOffset(92, 380), Visible = false })
	for key, value in props do
		(frame :: any)[key] = value
	end

	local percent = Kit.label("0%", { Size = UDim2.new(1, 0, 0, 34), Position = UDim2.fromOffset(0, 8), TextSize = 28, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center, Parent = frame })
	Kit.label("POWER", { Size = UDim2.new(1, 0, 0, 14), Position = UDim2.fromOffset(0, 40), TextSize = 12, Font = Theme.Fonts.Bold, TextColor3 = C.TextDim, TextXAlignment = Enum.TextXAlignment.Center, Parent = frame })

	local bar = Kit.new("Frame", {
		Size = UDim2.new(0, 34, 1, -128), Position = UDim2.new(0.5, -17, 0, 62), BackgroundColor3 = C.PanelDark, BorderSizePixel = 0, Parent = frame,
	}, { Kit.corner(10), Kit.stroke(C.Stroke, 2) }) :: Frame

	-- Colour scale: late zone (red) below ZERO, then green -> yellow -> red at 100%.
	local zero = GaugeView.toX(0)
	Kit.new("UIGradient", {
		Rotation = -90, -- 0 at the bottom, 1 at the top
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 30, 40)),
			ColorSequenceKeypoint.new(math.max(zero - 0.001, 0), Color3.fromRGB(180, 50, 50)),
			ColorSequenceKeypoint.new(zero, Color3.fromRGB(60, 200, 90)),
			ColorSequenceKeypoint.new(zero + (1 - zero) * 0.6, Color3.fromRGB(240, 210, 60)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(235, 80, 60)),
		}),
		Parent = bar,
	})
	local fill = Kit.new("Frame", { Size = UDim2.fromScale(1, 0), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.45, BorderSizePixel = 0, Parent = bar }, { Kit.corner(10) }) :: Frame
	local green = Kit.new("Frame", {
		Size = UDim2.new(1, 12, 0, 6), Position = UDim2.new(0, -6, 0, 0), BackgroundColor3 = Color3.fromRGB(180, 255, 190), BackgroundTransparency = 0.25, BorderSizePixel = 0, ZIndex = 2, Parent = bar,
	}, { Kit.corner(3), Kit.stroke(Color3.fromRGB(225, 255, 230), 1.5) }) :: Frame
	local locked = Kit.new("Frame", { Size = UDim2.new(1, 14, 0, 3), Position = UDim2.new(0, -7, 0, 0), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Visible = false, ZIndex = 3, Parent = bar }) :: Frame
	-- The moving marker: a bright notch either side of the bar.
	local marker = Kit.new("Frame", { Size = UDim2.new(1, 22, 0, 4), Position = UDim2.new(0, -11, 0, 0), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ZIndex = 4, Parent = bar }, {
		Kit.corner(2),
		Kit.stroke(Color3.new(0, 0, 0), 1),
	}) :: Frame

	local hint = Kit.label("", { Size = UDim2.new(1, -10, 0, 44), Position = UDim2.new(0, 5, 1, -60), TextSize = 12, Font = Theme.Fonts.Bold, TextColor3 = C.TextDim, TextXAlignment = Enum.TextXAlignment.Center, Parent = frame })
	local qualityLabel = Kit.label("", { Size = UDim2.new(1, 0, 0, 16), Position = UDim2.new(0, 0, 1, -20), TextSize = 13, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center, Parent = frame })

	local function y(x: number): number
		return 1 - math.clamp(x, 0, 1)
	end

	local function set(layout: GaugeView.Layout?, quality: string?)
		if layout == nil then
			frame.Visible = false
			return
		end
		frame.Visible = true
		local from, to = layout.FillFromX, layout.FillToX
		fill.Position = UDim2.fromScale(0, y(math.max(from, to)))
		fill.Size = UDim2.fromScale(1, math.abs(to - from))
		green.Position = UDim2.new(0, -6, y(layout.GreenRightX), 0)
		green.Size = UDim2.new(1, 12, layout.GreenRightX - layout.GreenLeftX, 0)
		marker.Position = UDim2.new(0, -11, y(layout.MarkerX), -2)
		locked.Visible = layout.LockedX ~= nil
		if layout.LockedX then
			locked.Position = UDim2.new(0, -7, y(layout.LockedX), -1)
		end
		percent.Text = `{math.floor(layout.PowerPercent + 0.5)}%`
		hint.Text = if layout.Phase == "Idle" then "CLICK / SPACE TO START" elseif layout.Phase == "PowerRising" then "CLICK TO SET POWER" elseif layout.Phase == "AccuracyFalling" then "CLICK ON THE GREEN BAND" else ""
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

return PowerMeter
