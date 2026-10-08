--!strict
--[[
	TimingBar.luau  (Client/UI)

	The 2-STAGE SHOT METER used in matches and at the driving range - a modern,
	glassy design: a semi-translucent dark panel with a top-lit sheen and a soft
	glow border, pill-shaped inset tracks, gradient fills, and a glow that moves to
	whichever stage is waiting for your click.

	    POWER      (████████████▌······|·······)  62%     stage 1: click to lock
	                                   ^ white tick = the power your target needs
	    ACCURACY   (░░▒▒▒▒[ SWEET ]▒▒▒▒░░)  ◀ ▶          stage 2: the needle swings
	    ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬  3.2s              back and forth; click on
	                                                     the sweet spot
	The thin bar under the accuracy track is the 5-SECOND TIMEOUT: it drains, turns
	red, and when it runs out the shot fires with a random hook or slice.

	PUTTS: the power track becomes a distance scale - tick marks labelled in feet,
	a HOLE flag where the hole distance falls (the meter auto-scales so that's
	about 2/3 of the way), and the readout in feet.

	It draws a GaugeView.Layout (shared, tested); it owns no timing logic.
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
local TRACK_LEFT = 104
local TRACK_RIGHT_PAD = 96

local function pill(parent: Instance, y: number, height: number): (Frame, UIStroke)
	local track = Kit.new("Frame", {
		Size = UDim2.new(1, -(TRACK_LEFT + TRACK_RIGHT_PAD), 0, height), Position = UDim2.fromOffset(TRACK_LEFT, y),
		BackgroundColor3 = C.Track, BackgroundTransparency = 0.05, BorderSizePixel = 0, ClipsDescendants = true, Parent = parent,
	}, { Kit.corner(height // 2) }) :: Frame
	local glow = Kit.glow(C.Stroke, 1.5, 0.2) :: UIStroke
	glow.Parent = track
	return track, glow
end

function TimingBar.new(props: Kit.Props): Bar
	local frame = Kit.panel({ Size = UDim2.fromOffset(580, 134), Visible = false })
	for key, value in props do
		(frame :: any)[key] = value
	end

	local hint = Kit.label("", {
		Size = UDim2.new(1, -24, 0, 18), Position = UDim2.fromOffset(12, 8), TextSize = 13, Font = Theme.Fonts.Title,
		TextColor3 = C.TextDim, TextXAlignment = Enum.TextXAlignment.Center, Parent = frame,
	})

	-- ---- power -------------------------------------------------------------------------------
	local powerLabel = Kit.label("POWER", { Size = UDim2.fromOffset(84, 28), Position = UDim2.fromOffset(16, 32), TextSize = 15, Font = Theme.Fonts.Title, Parent = frame })
	local powerTrack, powerGlow = pill(frame, 32, 28)
	local powerFill = Kit.new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Parent = powerTrack }, {
		Kit.corner(14),
		Kit.new("UIGradient", {
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(48, 210, 120)),
				ColorSequenceKeypoint.new(0.6, Color3.fromRGB(250, 214, 70)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(245, 84, 72)),
			}),
		}),
	}) :: Frame
	-- Gloss highlight across the top half of the fill.
	Kit.new("Frame", { Size = UDim2.new(1, 0, 0.45, 0), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.78, BorderSizePixel = 0, Parent = powerFill }, { Kit.corner(14) })
	local target = Kit.new("Frame", { Size = UDim2.new(0, 3, 1, 0), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Visible = false, ZIndex = 3, Parent = powerTrack }, {
		Kit.glow(Color3.new(1, 1, 1), 1, 0.5),
	}) :: Frame
	-- Putting scale: tick marks + feet labels under the track, and a HOLE flag.
	local tickHost = Kit.new("Frame", {
		Size = UDim2.new(1, -(TRACK_LEFT + TRACK_RIGHT_PAD), 0, 12), Position = UDim2.fromOffset(TRACK_LEFT, 60), BackgroundTransparency = 1, Visible = false, Parent = frame,
	}) :: Frame
	local flagHost = Kit.new("Frame", {
		Size = UDim2.new(1, -(TRACK_LEFT + TRACK_RIGHT_PAD), 0, 14), Position = UDim2.fromOffset(TRACK_LEFT, 17), BackgroundTransparency = 1, ZIndex = 6, Parent = frame,
	}) :: Frame
	local holeFlag = Kit.label("⛳ HOLE", {
		Size = UDim2.fromOffset(60, 14), AnchorPoint = Vector2.new(0.5, 0), TextSize = 11, Font = Theme.Fonts.Title,
		TextColor3 = Color3.new(1, 1, 1), TextXAlignment = Enum.TextXAlignment.Center, Visible = false, ZIndex = 6, Parent = flagHost,
	})
	local tickKey = ""
	local function drawTicks(ticks: { GaugeView.PuttTick }?)
		local key = ""
		if ticks then
			for _, t in ticks do
				key ..= t.Label .. ","
			end
		end
		if key == tickKey then
			return
		end
		tickKey = key
		Kit.clear(tickHost)
		tickHost.Visible = ticks ~= nil
		if ticks == nil then
			return
		end
		for _, t in ticks do
			Kit.new("Frame", { Size = UDim2.fromOffset(2, 5), Position = UDim2.new(t.X, -1, 0, -3), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.3, BorderSizePixel = 0, Parent = tickHost })
			Kit.label(t.Label, {
				Size = UDim2.fromOffset(30, 10), Position = UDim2.new(t.X, 0, 0, 2), AnchorPoint = Vector2.new(0.5, 0), TextSize = 9,
				Font = Theme.Fonts.Bold, TextColor3 = C.TextDim, TextXAlignment = Enum.TextXAlignment.Center, Parent = tickHost,
			})
		end
	end

	local percent = Kit.label("0%", {
		Size = UDim2.fromOffset(80, 30), Position = UDim2.new(1, -88, 0, 31), TextSize = 24, Font = Theme.Fonts.Title,
		TextXAlignment = Enum.TextXAlignment.Right, Parent = frame,
	})

	-- ---- accuracy ----------------------------------------------------------------------------
	local accuracyLabel = Kit.label("ACCURACY", { Size = UDim2.fromOffset(90, 28), Position = UDim2.fromOffset(16, 72), TextSize = 15, Font = Theme.Fonts.Title, Parent = frame })
	local accuracyTrack, accuracyGlow = pill(frame, 72, 28)
	-- Hook / slice danger fading toward the edges.
	local danger = Kit.new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.35, BorderSizePixel = 0, Parent = accuracyTrack }, {
		Kit.new("UIGradient", {
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(200, 52, 72)),
				ColorSequenceKeypoint.new(0.5, Color3.fromRGB(70, 50, 90)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 52, 72)),
			}),
		}),
	}) :: Frame
	local good = Kit.new("Frame", { BackgroundColor3 = Color3.fromRGB(242, 196, 64), BackgroundTransparency = 0.1, BorderSizePixel = 0, ZIndex = 2, Parent = accuracyTrack }, {
		Kit.corner(6),
	}) :: Frame
	local sweet = Kit.new("Frame", { BackgroundColor3 = Color3.fromRGB(64, 232, 128), BorderSizePixel = 0, ZIndex = 3, Parent = accuracyTrack }, {
		Kit.corner(6),
		Kit.glow(Color3.fromRGB(190, 255, 210), 1.5, 0.15),
		Kit.sheen(0.8),
	}) :: Frame
	Kit.label("SWEET", { Size = UDim2.fromScale(1, 1), TextSize = 10, Font = Theme.Fonts.Title, TextColor3 = Color3.fromRGB(6, 46, 22), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 4, Parent = sweet })
	-- The needle sits on the panel (not inside the clipped track) so it can overhang.
	local needleHost = Kit.new("Frame", {
		Size = UDim2.new(1, -(TRACK_LEFT + TRACK_RIGHT_PAD), 0, 28), Position = UDim2.fromOffset(TRACK_LEFT, 72), BackgroundTransparency = 1, ZIndex = 5, Parent = frame,
	}) :: Frame
	local needle = Kit.new("Frame", {
		Size = UDim2.new(0, 5, 1, 12), Position = UDim2.new(0, -2, 0, -6), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Visible = false, ZIndex = 6, Parent = needleHost,
	}, { Kit.corner(3), Kit.glow(Color3.fromRGB(150, 220, 255), 2, 0.25) }) :: Frame
	local qualityLabel = Kit.label("", {
		Size = UDim2.fromOffset(80, 30), Position = UDim2.new(1, -88, 0, 71), TextSize = 15, Font = Theme.Fonts.Title,
		TextXAlignment = Enum.TextXAlignment.Right, Parent = frame,
	})

	-- ---- 5 s timeout countdown -------------------------------------------------------------------
	local timerTrack = Kit.new("Frame", {
		Size = UDim2.new(1, -(TRACK_LEFT + TRACK_RIGHT_PAD), 0, 5), Position = UDim2.fromOffset(TRACK_LEFT, 108), BackgroundColor3 = C.Track,
		BorderSizePixel = 0, Visible = false, Parent = frame,
	}, { Kit.corner(3) }) :: Frame
	local timerFill = Kit.new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.Good, BorderSizePixel = 0, Parent = timerTrack }, { Kit.corner(3) }) :: Frame
	local timerText = Kit.label("", {
		Size = UDim2.fromOffset(80, 18), Position = UDim2.new(1, -88, 0, 101), TextSize = 13, Font = Theme.Fonts.Title,
		TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = C.TextDim, Parent = frame,
	})
	Kit.label("SLICE", { Size = UDim2.fromOffset(60, 14), Position = UDim2.fromOffset(TRACK_LEFT, 116), TextSize = 10, TextColor3 = C.TextDim, Parent = frame })
	Kit.label("HOOK", { Size = UDim2.fromOffset(60, 14), Position = UDim2.new(1, -(TRACK_RIGHT_PAD + 60), 0, 116), TextSize = 10, TextColor3 = C.TextDim, TextXAlignment = Enum.TextXAlignment.Right, Parent = frame })

	local function set(layout: GaugeView.Layout?, quality: string?)
		if layout == nil then
			frame.Visible = false
			return
		end
		frame.Visible = true
		local inPower = layout.Phase == "Power" or layout.Phase == "Idle"
		local inAccuracy = layout.Phase == "Accuracy"

		powerFill.Size = UDim2.fromScale(layout.PowerFill, 1)
		target.Visible = layout.TargetPower ~= nil
		if layout.TargetPower then
			target.Position = UDim2.new(layout.TargetPower, -1, 0, 0)
		end
		percent.Text = layout.PowerLabel
		drawTicks(layout.PuttTicks)
		holeFlag.Visible = layout.HoleX ~= nil
		if layout.HoleX then
			holeFlag.Position = UDim2.fromScale(layout.HoleX, 0) -- above the track, at the hole's distance
		end
		percent.TextColor3 = if layout.Locked then C.Gold else C.Text

		good.Position = UDim2.fromScale(layout.GoodLeft, 0)
		good.Size = UDim2.fromScale(layout.GoodRight - layout.GoodLeft, 1)
		sweet.Position = UDim2.fromScale(layout.SweetLeft, 0)
		sweet.Size = UDim2.fromScale(layout.SweetRight - layout.SweetLeft, 1)
		needle.Visible = layout.NeedleX ~= nil
		if layout.NeedleX then
			needle.Position = UDim2.new(layout.NeedleX, -2, 0, -6)
		end

		-- The waiting stage glows; the other one dims.
		powerGlow.Color = if inPower then C.GlowAccent else C.Stroke
		powerGlow.Thickness = if inPower then 2.5 else 1.5
		accuracyGlow.Color = if inAccuracy then C.GlowAccent else C.Stroke
		accuracyGlow.Thickness = if inAccuracy then 2.5 else 1.5
		powerTrack.BackgroundTransparency = if inPower then 0.05 else 0.35
		danger.BackgroundTransparency = if inPower then 0.7 else 0.35
		powerLabel.TextColor3 = if inPower then C.Text else C.TextDim
		accuracyLabel.TextColor3 = if inAccuracy then C.Text else C.TextDim

		local fraction = layout.TimeFraction
		timerTrack.Visible = inAccuracy and fraction ~= nil
		if inAccuracy and fraction then
			timerFill.Size = UDim2.fromScale(fraction, 1)
			timerFill.BackgroundColor3 = if fraction > 0.5 then C.Good elseif fraction > 0.25 then C.Gold else C.Danger
			timerText.Text = string.format("%.1fs", layout.TimeLeft or 0)
			timerText.TextColor3 = if fraction > 0.25 then C.TextDim else C.Danger
		else
			timerText.Text = ""
		end

		local putting = layout.Mode == "Putt"
		hint.Text = if inPower then (if putting then "PUTT  ·  CLICK / SPACE TO SET THE PACE" else "CLICK / SPACE TO LOCK POWER")
			elseif inAccuracy then "CLICK WHEN THE NEEDLE CROSSES THE SWEET SPOT"
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
