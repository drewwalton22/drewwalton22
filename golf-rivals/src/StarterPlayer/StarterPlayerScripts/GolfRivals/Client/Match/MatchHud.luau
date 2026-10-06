--!strict
--[[
	MatchHud.luau  (Client/Match)

	The in-match overlay (mockup panels 9 and 10). It owns no game logic: it builds
	the widgets once and exposes setters; MatchController feeds it values computed
	by the tested pure modules (MatchView, GaugeView, MiniMap, TelemetryView).

	LAYOUT
	  top-left      hole card (HOLE / PAR / yards) with the wind arrow under it
	  top-centre    turn banner + turn timer
	  left          scoreboard
	  right         top-down mini map, yards-to-pin; live telemetry panel below it
	  bottom-centre club selector, aim controls, 3-click swing gauge
	  centre        shot feedback ("Perfect!") and the end-of-match results screen
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local CourseDatabase = require(Shared.CourseDatabase)
local Format = require(Shared.Format)
local GaugeView = require(Shared.GaugeView)
local MatchView = require(Shared.MatchView)
local MiniMap = require(Shared.MiniMap)
local Signal = require(Shared.Signal)
local TelemetryView = require(Shared.TelemetryView)

local Kit = require(script.Parent.Parent.UI.Kit)
local Theme = require(script.Parent.Parent.UI.Theme)

export type Dot = { X: number, Z: number, IsMe: boolean, Holed: boolean }

export type Hud = {
	Gui: ScreenGui,
	onClubStep: Signal.Signal, -- fires (delta: number) -1 / +1
	onClubAuto: Signal.Signal,
	onAimStep: Signal.Signal, -- fires (deltaDegrees: number)
	onLeave: Signal.Signal,
	onForfeit: Signal.Signal,
	setTimer: (seconds: number, running: boolean) -> (),
	update: (model: MatchView.HudModel) -> (),
	setHole: (hole: CourseDatabase.HoleDef) -> (),
	setDots: (dots: { Dot }) -> (),
	setGauge: (layout: GaugeView.Layout?, quality: string?) -> (),
	feedback: (text: string, color: Color3) -> (),
	showTelemetry: (live: TelemetryView.Live) -> (),
	hideTelemetry: () -> (),
	showSummary: (summary: MatchView.Summary, winningsText: string?) -> (),
	destroy: () -> (),
}

local MatchHud = {}

local C = Theme.Colors

local LIE_COLORS: { [string]: Color3 } = {
	Fairway = Color3.fromRGB(104, 170, 78),
	Sand = Color3.fromRGB(226, 208, 150),
	Green = Color3.fromRGB(128, 214, 98),
	Water = Color3.fromRGB(58, 128, 214),
}

local function text(parent: Instance, content: string, props: Kit.Props): TextLabel
	props.Parent = parent
	return Kit.label(content, props)
end

function MatchHud.new(): Hud
	local gui = Kit.screenGui("GolfRivalsMatchHud", 5)
	local clubStep, clubAuto, aimStep, leave, forfeit = Signal.new(), Signal.new(), Signal.new(), Signal.new(), Signal.new()

	-- ---- hole card + wind (top-left) -------------------------------------------------
	local holeCard = Kit.panel({ Size = UDim2.fromOffset(230, 104), Position = UDim2.fromOffset(16, 16), Parent = gui })
	local holeTitle = text(holeCard, "HOLE 1", { Size = UDim2.new(1, -20, 0, 34), Position = UDim2.fromOffset(14, 8), Font = Theme.Fonts.Title, TextSize = 30 })
	local holeSub = text(holeCard, "PAR 4  ·  380 YDS", { Size = UDim2.new(1, -20, 0, 22), Position = UDim2.fromOffset(14, 44), TextSize = 16, TextColor3 = C.TextDim })
	local holeProgress = text(holeCard, "1 / 3", { Size = UDim2.new(1, -20, 0, 20), Position = UDim2.fromOffset(14, 72), TextSize = 14, TextColor3 = C.TextDim })

	local windCard = Kit.panel({ Size = UDim2.fromOffset(150, 74), Position = UDim2.fromOffset(16, 128), Parent = gui })
	local windArrow = text(windCard, "▲", { Size = UDim2.fromOffset(44, 44), Position = UDim2.fromOffset(12, 15), TextSize = 34, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.Accent, Rotation = 0 })
	text(windCard, "WIND", { Size = UDim2.fromOffset(70, 18), Position = UDim2.fromOffset(66, 12), TextSize = 12, TextColor3 = C.TextDim })
	local windText = text(windCard, "8 MPH", { Size = UDim2.fromOffset(80, 26), Position = UDim2.fromOffset(66, 32), TextSize = 18 })

	-- ---- banner + timer (top-centre) --------------------------------------------------
	local banner = Kit.panel({ Size = UDim2.fromOffset(380, 58), Position = UDim2.new(0.5, -190, 0, 16), Parent = gui })
	local bannerText = text(banner, "YOUR SHOT", { Size = UDim2.new(1, -90, 1, 0), Position = UDim2.fromOffset(16, 0), Font = Theme.Fonts.Title, TextSize = 22 })
	local timerText = text(banner, "0:40", { Size = UDim2.fromOffset(70, 58), Position = UDim2.new(1, -78, 0, 0), TextSize = 26, TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = C.Gold })

	-- ---- scoreboard (left) --------------------------------------------------------------
	local board = Kit.panel({ Size = UDim2.fromOffset(230, 160), Position = UDim2.fromOffset(16, 214), Parent = gui }, {
		Kit.padding(8),
		Kit.list(Enum.FillDirection.Vertical, 6),
	})
	text(board, "SCORECARD", { Size = UDim2.new(1, 0, 0, 16), TextSize = 12, TextColor3 = C.TextDim, LayoutOrder = 0 })

	-- ---- mini map (right) ------------------------------------------------------------------
	local MAP_W, MAP_H = 150, 280
	local mapPanel = Kit.panel({ Size = UDim2.fromOffset(MAP_W + 16, MAP_H + 52), Position = UDim2.new(1, -(MAP_W + 32), 0, 16), Parent = gui })
	local mapCanvas = Kit.new("Frame", {
		Size = UDim2.fromOffset(MAP_W, MAP_H), Position = UDim2.fromOffset(8, 8), BackgroundColor3 = C.PanelDark,
		BorderSizePixel = 0, ClipsDescendants = true, Parent = mapPanel,
	}, { Kit.corner(8) }) :: Frame
	local yardsLabel = text(mapPanel, "380 YDS", { Size = UDim2.new(1, -16, 0, 28), Position = UDim2.fromOffset(8, MAP_H + 14), TextSize = 22, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center })
	local mapLayout: MiniMap.Layout? = nil
	local dotFrames: { Frame } = {}

	-- ---- telemetry (right, under the map) --------------------------------------------------------
	local telemetry = Kit.panel({ Size = UDim2.fromOffset(MAP_W + 16, 196), Position = UDim2.new(1, -(MAP_W + 32), 0, MAP_H + 84), Visible = false, Parent = gui }, {
		Kit.padding(10),
		Kit.list(Enum.FillDirection.Vertical, 4),
	})
	local telemetryValues: { [string]: TextLabel } = {}
	for index, row in { { "TOTAL DISTANCE", "Total" }, { "CARRY", "Carry" }, { "ROLL", "Roll" }, { "APEX", "Apex" }, { "SPIN", "Spin" } } do
		local line = Kit.new("Frame", { Size = UDim2.new(1, 0, 0, 32), BackgroundTransparency = 1, LayoutOrder = index, Parent = telemetry }) :: Frame
		text(line, row[1], { Size = UDim2.new(1, 0, 0, 12), TextSize = 10, TextColor3 = C.TextDim })
		telemetryValues[row[2]] = text(line, "0", { Size = UDim2.new(1, 0, 0, 20), Position = UDim2.fromOffset(0, 12), TextSize = 18, Font = Theme.Fonts.Title })
	end

	-- ---- club + aim controls (bottom-centre) -------------------------------------------------------
	local controls = Kit.panel({ Size = UDim2.fromOffset(600, 62), Position = UDim2.new(0.5, -300, 1, -186), Parent = gui })
	Kit.button("◀", "ghost", function()
		clubStep.fire(-1)
	end, { Size = UDim2.fromOffset(44, 40), Position = UDim2.fromOffset(10, 11), Parent = controls })
	local clubName = text(controls, "DRIVER", { Size = UDim2.fromOffset(190, 24), Position = UDim2.fromOffset(60, 6), TextSize = 18, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center })
	local clubInfo = text(controls, "250 YDS", { Size = UDim2.fromOffset(190, 20), Position = UDim2.fromOffset(60, 32), TextSize = 13, TextColor3 = C.TextDim, TextXAlignment = Enum.TextXAlignment.Center })
	Kit.button("▶", "ghost", function()
		clubStep.fire(1)
	end, { Size = UDim2.fromOffset(44, 40), Position = UDim2.fromOffset(256, 11), Parent = controls })
	Kit.button("AUTO", "secondary", function()
		clubAuto.fire()
	end, { Size = UDim2.fromOffset(64, 40), Position = UDim2.fromOffset(310, 11), TextSize = 14, Parent = controls })
	Kit.button("◀", "ghost", function()
		aimStep.fire(-2)
	end, { Size = UDim2.fromOffset(40, 40), Position = UDim2.fromOffset(392, 11), Parent = controls })
	local aimText = text(controls, "AIM  0°", { Size = UDim2.fromOffset(100, 40), Position = UDim2.fromOffset(436, 11), TextSize = 15, TextXAlignment = Enum.TextXAlignment.Center })
	Kit.button("▶", "ghost", function()
		aimStep.fire(2)
	end, { Size = UDim2.fromOffset(40, 40), Position = UDim2.fromOffset(542, 11), Parent = controls })

	-- ---- swing gauge (bottom-centre) -------------------------------------------------------------------
	local gaugePanel = Kit.panel({ Size = UDim2.fromOffset(600, 84), Position = UDim2.new(0.5, -300, 1, -112), Visible = false, Parent = gui })
	local BAR_W = 520
	local bar = Kit.new("Frame", {
		Size = UDim2.fromOffset(BAR_W, 22), Position = UDim2.fromOffset(40, 40), BackgroundColor3 = C.PanelDark, BorderSizePixel = 0, Parent = gaugePanel,
	}, { Kit.corner(11), Kit.stroke() }) :: Frame
	local zero = GaugeView.toX(0)
	Kit.new("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 30, 40)),
			ColorSequenceKeypoint.new(math.max(zero - 0.001, 0), Color3.fromRGB(180, 50, 50)),
			ColorSequenceKeypoint.new(zero, Color3.fromRGB(60, 200, 90)),
			ColorSequenceKeypoint.new(zero + (1 - zero) * 0.55, Color3.fromRGB(240, 210, 60)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(235, 80, 60)),
		}),
		Parent = bar,
	})
	local fill = Kit.new("Frame", { Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.55, BorderSizePixel = 0, Parent = bar }) :: Frame
	local greenZone = Kit.new("Frame", {
		Size = UDim2.new(0, 10, 1, 8), Position = UDim2.new(0, 0, 0, -4), BackgroundColor3 = Color3.fromRGB(180, 255, 190),
		BackgroundTransparency = 0.35, BorderSizePixel = 0, Parent = bar,
	}, { Kit.stroke(Color3.fromRGB(220, 255, 225), 2) }) :: Frame
	local locked = Kit.new("Frame", { Size = UDim2.new(0, 3, 1, 10), Position = UDim2.new(0, 0, 0, -5), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Visible = false, Parent = bar }) :: Frame
	local marker = text(gaugePanel, "▼", { Size = UDim2.fromOffset(24, 22), Position = UDim2.fromOffset(28, 20), TextSize = 24, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.Text })
	local gaugeTitle = text(gaugePanel, "CLICK 1: START   ·   CLICK 2: POWER   ·   CLICK 3: ACCURACY", { Size = UDim2.new(1, -20, 0, 18), Position = UDim2.fromOffset(10, 6), TextSize = 12, TextColor3 = C.TextDim, TextXAlignment = Enum.TextXAlignment.Center })
	local powerText = text(gaugePanel, "0%", { Size = UDim2.fromOffset(120, 18), Position = UDim2.new(1, -130, 1, -22), TextSize = 14, TextXAlignment = Enum.TextXAlignment.Right })
	local qualityText = text(gaugePanel, "", { Size = UDim2.fromOffset(200, 18), Position = UDim2.fromOffset(40, 64), TextSize = 14, Font = Theme.Fonts.Title })

	Kit.button("FORFEIT", "ghost", function()
		forfeit.fire()
	end, { Size = UDim2.fromOffset(110, 36), Position = UDim2.new(0, 16, 1, -52), TextSize = 13, Parent = gui })

	-- ---- shot feedback + results (centre) ----------------------------------------------------------------
	local feedbackLabel = text(gui, "", {
		Size = UDim2.fromOffset(600, 70), Position = UDim2.new(0.5, -300, 0.5, -170), TextSize = 56, Font = Theme.Fonts.Title,
		TextXAlignment = Enum.TextXAlignment.Center, TextTransparency = 1, TextStrokeTransparency = 1, TextStrokeColor3 = Color3.new(0, 0, 0),
	})
	local overlay: Frame? = nil

	-- ---- API -------------------------------------------------------------------------------------------------
	local function rebuildScoreboard(rows: { MatchView.Row })
		for _, child in board:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		for index, row in rows do
			local line = Kit.new("Frame", {
				Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = if row.IsMe then C.PanelLight else C.PanelDark, BorderSizePixel = 0, LayoutOrder = index, Parent = board,
			}, { Kit.corner(6) }) :: Frame
			local turnDot = if row.IsActive then "● " else ""
			text(line, turnDot .. row.Name .. (if row.IsBot then " 🤖" else ""), { Size = UDim2.new(1, -60, 0, 18), Position = UDim2.fromOffset(8, 3), TextSize = 14, TextTruncate = Enum.TextTruncate.AtEnd })
			local detail = if row.Forfeited then "forfeited" elseif row.Holed then `holed in {row.Strokes}` else `{row.Strokes} strokes · {Format.yards(row.YardsToPin)}`
			text(line, detail, { Size = UDim2.new(1, -60, 0, 16), Position = UDim2.fromOffset(8, 21), TextSize = 11, TextColor3 = C.TextDim })
			text(line, tostring(row.Total), { Size = UDim2.fromOffset(44, 40), Position = UDim2.new(1, -50, 0, 0), TextSize = 22, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.Gold })
		end
		board.Size = UDim2.fromOffset(230, 24 + #rows * 46)
	end

	local function update(model: MatchView.HudModel)
		holeTitle.Text = model.HoleText
		holeSub.Text = `{model.ParText}  ·  {model.YardsText}`
		holeProgress.Text = model.ProgressText
		windText.Text = model.WindText
		windArrow.Rotation = model.WindRotationDeg
		bannerText.Text = model.Banner
		bannerText.TextColor3 = if model.IsMyTurn then C.Accent else C.Text
		timerText.Text = if model.Phase == "Swing" then model.TimerText else ""
		timerText.TextColor3 = if model.TimerSeconds <= 10 and model.Phase == "Swing" then C.Danger else C.Gold
		yardsLabel.Text = model.YardsToPinText
		rebuildScoreboard(model.Rows)

		for _, option in model.ClubOptions do
			if option.Selected then
				clubName.Text = string.upper(option.DisplayName) .. (if option.Recommended then "  ★" else "")
				clubInfo.Text = if option.ReachYds > 0 then `{math.floor(option.ReachYds + 0.5)} YDS  ·  {string.upper(model.Lie)}` else `PUTTER  ·  {string.upper(model.Lie)}`
			end
		end
		aimText.Text = `AIM  {if model.AimDeg > 0 then "+" else ""}{math.floor(model.AimDeg + 0.5)}°`
		controls.Visible = model.IsMyTurn
	end

	-- Cheap per-frame countdown (the full `update` rebuilds the scoreboard).
	local function setTimer(seconds: number, running: boolean)
		timerText.Text = if running then Format.clock(seconds) else ""
		timerText.TextColor3 = if seconds <= 10 and running then C.Danger else C.Gold
	end

	local function setHole(hole: CourseDatabase.HoleDef)
		for _, child in mapCanvas:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		dotFrames = {}
		local layout = MiniMap.layout(hole, MAP_W, MAP_H, 10)
		mapLayout = layout

		-- Rough = the rotated playable rectangle.
		local p1, p2, p3, p4 = layout.Outline[1], layout.Outline[2], layout.Outline[3], layout.Outline[4]
		local e2x, e2y = p4[1] - p1[1], p4[2] - p1[2]
		local e1x, e1y = p2[1] - p1[1], p2[2] - p1[2]
		Kit.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset((p1[1] + p3[1]) / 2, (p1[2] + p3[2]) / 2),
			Size = UDim2.fromOffset(math.sqrt(e2x * e2x + e2y * e2y), math.sqrt(e1x * e1x + e1y * e1y)),
			Rotation = math.deg(math.atan2(e2y, e2x)), BackgroundColor3 = Color3.fromRGB(58, 98, 50), BorderSizePixel = 0, Parent = mapCanvas,
		})
		for _, shape in layout.Shapes do
			if shape.Kind == "Circle" then
				Kit.new("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(shape.X, shape.Y), Size = UDim2.fromOffset(shape.R * 2, shape.R * 2),
					BackgroundColor3 = LIE_COLORS[shape.Lie] or C.Panel, BorderSizePixel = 0, Parent = mapCanvas,
				}, { Kit.new("UICorner", { CornerRadius = UDim.new(1, 0) }) })
			else
				local dx, dy = shape.X2 - shape.X1, shape.Y2 - shape.Y1
				Kit.new("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset((shape.X1 + shape.X2) / 2, (shape.Y1 + shape.Y2) / 2),
					Size = UDim2.fromOffset(math.sqrt(dx * dx + dy * dy) + shape.Width, shape.Width), Rotation = math.deg(math.atan2(dy, dx)),
					BackgroundColor3 = LIE_COLORS.Fairway, BorderSizePixel = 0, Parent = mapCanvas,
				}, { Kit.new("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
			end
		end
		-- Pin marker.
		Kit.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(layout.Pin[1], layout.Pin[2]), Size = UDim2.fromOffset(8, 8),
			BackgroundColor3 = Color3.fromRGB(230, 50, 60), BorderSizePixel = 0, Parent = mapCanvas,
		}, { Kit.new("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	end

	local function setDots(dots: { Dot })
		local layout = mapLayout
		if layout == nil then
			return
		end
		for _, frame in dotFrames do
			frame:Destroy()
		end
		dotFrames = {}
		for _, dot in dots do
			if not dot.Holed then
				local px, py = layout.project(dot.X, dot.Z)
				local frame = Kit.new("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(px, py), Size = UDim2.fromOffset(if dot.IsMe then 10 else 8, if dot.IsMe then 10 else 8),
					BackgroundColor3 = if dot.IsMe then Color3.new(1, 1, 1) else Color3.fromRGB(255, 150, 60), BorderSizePixel = 0, ZIndex = 5, Parent = mapCanvas,
				}, { Kit.new("UICorner", { CornerRadius = UDim.new(1, 0) }), Kit.stroke(Color3.new(0, 0, 0), 1) }) :: Frame
				table.insert(dotFrames, frame)
			end
		end
	end

	local function setGauge(layout: GaugeView.Layout?, quality: string?)
		if layout == nil then
			gaugePanel.Visible = false
			return
		end
		gaugePanel.Visible = true
		fill.Position = UDim2.fromScale(layout.FillFromX, 0)
		fill.Size = UDim2.fromScale(math.max(layout.FillToX - layout.FillFromX, 0), 1)
		greenZone.Position = UDim2.new(layout.GreenLeftX, 0, 0, -4)
		greenZone.Size = UDim2.new(layout.GreenRightX - layout.GreenLeftX, 0, 1, 8)
		marker.Position = UDim2.fromOffset(40 + BAR_W * layout.MarkerX - 12, 20)
		locked.Visible = layout.LockedX ~= nil
		if layout.LockedX then
			locked.Position = UDim2.new(layout.LockedX, -1, 0, -5)
		end
		powerText.Text = `POWER {math.floor(layout.PowerPercent + 0.5)}%`
		qualityText.Text = quality or ""
		qualityText.TextColor3 = if quality == "PERFECT" then C.Good elseif quality == "GOOD" then C.Gold else C.Poor
		gaugeTitle.Text = if layout.Phase == "Idle" then "CLICK TO START THE POWER BAR" elseif layout.Phase == "PowerRising" then "CLICK TO LOCK POWER" elseif layout.Phase == "AccuracyFalling" then "CLICK ON THE GREEN ZONE FOR A STRAIGHT SHOT" else ""
	end

	local function feedback(message: string, color: Color3)
		feedbackLabel.Text = message
		feedbackLabel.TextColor3 = color
		feedbackLabel.TextTransparency = 0
		feedbackLabel.TextStrokeTransparency = 0.4
		task.delay(1.6, function()
			if feedbackLabel.Parent then
				Kit.tween(feedbackLabel, 0.5, { TextTransparency = 1, TextStrokeTransparency = 1 })
			end
		end)
	end

	local function showTelemetry(live: TelemetryView.Live)
		telemetry.Visible = true
		telemetryValues.Total.Text = Format.yards(live.TotalYds)
		telemetryValues.Carry.Text = Format.yards(live.CarryYds)
		telemetryValues.Roll.Text = Format.yards(live.RollYds)
		telemetryValues.Apex.Text = Format.feet(live.ApexFeet)
		telemetryValues.Spin.Text = Format.rpm(live.SpinRpm)
	end

	local function showSummary(summary: MatchView.Summary, winningsText: string?)
		if overlay then
			overlay:Destroy()
		end
		local dim = Kit.new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45, BorderSizePixel = 0, ZIndex = 20, Parent = gui }) :: Frame
		overlay = dim
		local card = Kit.panel({ Size = UDim2.fromOffset(520, 120 + #summary.Rows * 56 + 90), Position = UDim2.new(0.5, -260, 0.5, -(120 + #summary.Rows * 56 + 90) / 2), ZIndex = 21, Parent = dim })
		local titleColor = if summary.Won then C.Good elseif summary.Draw then C.Gold else C.Poor
		text(card, summary.Title, { Size = UDim2.new(1, 0, 0, 70), Position = UDim2.fromOffset(0, 14), TextSize = 56, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = titleColor, ZIndex = 22 })
		local reason = if summary.Reason == "forfeit" then "Won by forfeit" else ""
		text(card, reason, { Size = UDim2.new(1, 0, 0, 20), Position = UDim2.fromOffset(0, 82), TextSize = 14, TextColor3 = C.TextDim, TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 22 })
		for index, row in summary.Rows do
			local line = Kit.new("Frame", { Size = UDim2.new(1, -40, 0, 48), Position = UDim2.fromOffset(20, 110 + (index - 1) * 56), BackgroundColor3 = if row.IsMe then C.PanelLight else C.PanelDark, BorderSizePixel = 0, ZIndex = 22, Parent = card }, { Kit.corner(8) }) :: Frame
			local holes = {}
			for _, strokes in row.HoleScores do
				table.insert(holes, tostring(strokes))
			end
			text(line, row.Name .. (if row.Forfeited then "  (forfeit)" else ""), { Size = UDim2.new(0.5, 0, 1, 0), Position = UDim2.fromOffset(14, 0), TextSize = 18, ZIndex = 23 })
			text(line, table.concat(holes, "  ·  "), { Size = UDim2.new(0.3, 0, 1, 0), Position = UDim2.new(0.5, 0, 0, 0), TextSize = 15, TextColor3 = C.TextDim, ZIndex = 23 })
			text(line, tostring(row.Total), { Size = UDim2.fromOffset(60, 48), Position = UDim2.new(1, -66, 0, 0), TextSize = 28, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.Gold, ZIndex = 23 })
		end
		if winningsText then
			text(card, winningsText, { Size = UDim2.new(1, 0, 0, 28), Position = UDim2.new(0, 0, 1, -112), TextSize = 22, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.Gold, ZIndex = 22 })
		end
		Kit.button("RETURN TO LOBBY", "primary", function()
			leave.fire()
		end, { Size = UDim2.new(1, -40, 0, 50), Position = UDim2.new(0, 20, 1, -70), TextSize = 20, ZIndex = 22, Parent = card })
	end

	return {
		Gui = gui,
		onClubStep = clubStep,
		onClubAuto = clubAuto,
		onAimStep = aimStep,
		onLeave = leave,
		onForfeit = forfeit,
		setTimer = setTimer,
		update = update,
		setHole = setHole,
		setDots = setDots,
		setGauge = setGauge,
		feedback = feedback,
		showTelemetry = showTelemetry,
		hideTelemetry = function()
			telemetry.Visible = false
		end,
		showSummary = showSummary,
		destroy = function()
			gui:Destroy()
		end,
	}
end

return MatchHud
