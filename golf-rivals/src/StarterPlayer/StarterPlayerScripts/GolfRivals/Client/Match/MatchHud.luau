--!strict
--[[
	MatchHud.luau  (Client/Match)

	The in-match overlay. It owns no game logic: it builds the widgets once and
	exposes setters; MatchController feeds it values computed by the tested pure
	modules (MatchView, GaugeView, MiniMap, TelemetryView, PodiumView).

	Everything sits inside Kit.safeArea, so nothing hides under Roblox's top-bar
	buttons (the old hole card did).

	LAYOUT
	  top-left      hole card (HOLE / PAR / yards) with the wind arrow under it
	  top-centre    turn banner + turn timer
	  left          scoreboard
	  right         top-down mini map, yards-to-pin; live telemetry below it
	  bottom-centre the six club chips (DR FW LI SI WG PT, reach under each, the
	                recommended club starred) and aim controls; on the green the
	                putter is locked in and a "PUTTING" tag shows
	  above them    AIM stage: target distance + SWING button (or Space);
	                SWING stage: the 2-stage TIMING BAR (power, then accuracy)
	                and a "back to aim" button (or Tab)
	  centre        shot feedback ("PERFECT!")
	  end of match  a scoreboard panel docked on the left, so the 3D podium stays
	                visible, with RETURN TO LOBBY
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local CourseDatabase = require(Shared.CourseDatabase)
local Format = require(Shared.Format)
local GaugeView = require(Shared.GaugeView)
local MatchView = require(Shared.MatchView)
local MiniMap = require(Shared.MiniMap)
local PodiumView = require(Shared.PodiumView)
local Signal = require(Shared.Signal)
local TelemetryView = require(Shared.TelemetryView)

local Kit = require(script.Parent.Parent.UI.Kit)
local Theme = require(script.Parent.Parent.UI.Theme)
local TimingBar = require(script.Parent.Parent.UI.TimingBar)

export type Dot = { X: number, Z: number, IsMe: boolean, Holed: boolean }
export type AimStage = "Aim" | "Swing"

export type Hud = {
	Gui: ScreenGui,
	onClubPick: Signal.Signal, -- fires (label: string)
	onClubStep: Signal.Signal, -- fires (delta: number) -1 / +1
	onClubAuto: Signal.Signal,
	onAimStep: Signal.Signal, -- fires (deltaDegrees: number)
	onLeave: Signal.Signal,
	onForfeit: Signal.Signal,
	onConfirmAim: Signal.Signal, -- AIM stage -> SWING stage
	onToggleView: Signal.Signal, -- aerial <-> behind-the-player camera (also the V key)
	setViewLabel: (view: string) -> (), -- "Aerial" | "Behind"
	setTarget: (ballX: number, ballZ: number, targetX: number, targetZ: number) -> (), -- minimap reticle
	clearTarget: () -> (),
	onBackToAim: Signal.Signal, -- SWING stage -> AIM stage
	setAimStage: (stage: AimStage?, info: string?) -> (), -- nil hides the panel
	setTimer: (seconds: number, running: boolean) -> (),
	update: (model: MatchView.HudModel) -> (),
	setHole: (hole: CourseDatabase.HoleDef) -> (),
	setDots: (dots: { Dot }) -> (),
	setGauge: (layout: GaugeView.Layout?, quality: string?) -> (),
	feedback: (text: string, color: Color3) -> (),
	showTelemetry: (live: TelemetryView.Live) -> (),
	hideTelemetry: () -> (),
	showSummary: (summary: MatchView.Summary, podium: PodiumView.Podium, winningsText: string?) -> (),
	setPlayVisible: (visible: boolean) -> (),
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
	local safe = Kit.safeArea(gui)
	local play = Kit.new("Frame", { Name = "Play", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = safe }) :: Frame
	local clubPick, clubStep, clubAuto, aimStep, leave, forfeit = Signal.new(), Signal.new(), Signal.new(), Signal.new(), Signal.new(), Signal.new()
	local confirmAim, backToAim, toggleView = Signal.new(), Signal.new(), Signal.new()

	-- ---- hole card + wind (top-left) -------------------------------------------------
	local holeCard = Kit.panel({ Size = UDim2.fromOffset(230, 100), Parent = play })
	local holeTitle = text(holeCard, "HOLE 1", { Size = UDim2.new(1, -20, 0, 34), Position = UDim2.fromOffset(14, 8), Font = Theme.Fonts.Title, TextSize = 30 })
	local holeSub = text(holeCard, "PAR 4  ·  380 YDS", { Size = UDim2.new(1, -20, 0, 22), Position = UDim2.fromOffset(14, 44), TextSize = 16, TextColor3 = C.TextDim })
	local holeProgress = text(holeCard, "1 / 3", { Size = UDim2.new(1, -20, 0, 20), Position = UDim2.fromOffset(14, 70), TextSize = 14, TextColor3 = C.TextDim })

	local windCard = Kit.panel({ Size = UDim2.fromOffset(150, 70), Position = UDim2.fromOffset(0, 110), Parent = play })
	local windArrow = text(windCard, "▲", { Size = UDim2.fromOffset(44, 44), Position = UDim2.fromOffset(12, 13), TextSize = 34, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.Accent, Rotation = 0 })
	text(windCard, "WIND", { Size = UDim2.fromOffset(70, 18), Position = UDim2.fromOffset(66, 10), TextSize = 12, TextColor3 = C.TextDim })
	local windText = text(windCard, "8 MPH", { Size = UDim2.fromOffset(80, 26), Position = UDim2.fromOffset(66, 30), TextSize = 18, Font = Theme.Fonts.Title })

	-- ---- banner + timer (top-centre) --------------------------------------------------
	local banner = Kit.panel({ Size = UDim2.fromOffset(380, 56), Position = UDim2.fromScale(0.5, 0), AnchorPoint = Vector2.new(0.5, 0), Parent = play })
	local bannerText = text(banner, "YOUR SHOT", { Size = UDim2.new(1, -90, 1, 0), Position = UDim2.fromOffset(16, 0), Font = Theme.Fonts.Title, TextSize = 22, TextTruncate = Enum.TextTruncate.AtEnd })
	local timerText = text(banner, "0:40", { Size = UDim2.fromOffset(70, 56), Position = UDim2.new(1, -78, 0, 0), TextSize = 26, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = C.Gold })

	-- ---- scoreboard (left) --------------------------------------------------------------
	local board = Kit.panel({ Size = UDim2.fromOffset(230, 160), Position = UDim2.fromOffset(0, 190), Parent = play }, {
		Kit.padding(8),
		Kit.list(Enum.FillDirection.Vertical, 6),
	})
	text(board, "SCORECARD", { Size = UDim2.new(1, 0, 0, 16), TextSize = 12, TextColor3 = C.TextDim, LayoutOrder = 0 })

	-- ---- mini map (right) ------------------------------------------------------------------
	local MAP_W, MAP_H = 140, 250
	local mapPanel = Kit.panel({ Size = UDim2.fromOffset(MAP_W + 16, MAP_H + 50), Position = UDim2.fromScale(1, 0), AnchorPoint = Vector2.new(1, 0), Parent = play })
	local mapCanvas = Kit.new("Frame", {
		Size = UDim2.fromOffset(MAP_W, MAP_H), Position = UDim2.fromOffset(8, 8), BackgroundColor3 = C.PanelDark,
		BorderSizePixel = 0, ClipsDescendants = true, Parent = mapPanel,
	}, { Kit.corner(8) }) :: Frame
	local yardsLabel = text(mapPanel, "380 YDS", { Size = UDim2.new(1, -16, 0, 28), Position = UDim2.fromOffset(8, MAP_H + 12), TextSize = 22, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center })
	local mapLayout: MiniMap.Layout? = nil
	local dotFrames: { Frame } = {}
	local elevationText = "" -- "  ·  ▼ 39 FT DOWNHILL" for the current hole
	local targetRing: Frame? = nil
	local targetLine: Frame? = nil

	-- ---- telemetry (right, under the map) --------------------------------------------------------
	local telemetry = Kit.panel({ Size = UDim2.fromOffset(MAP_W + 16, 190), Position = UDim2.new(1, 0, 0, MAP_H + 60), AnchorPoint = Vector2.new(1, 0), Visible = false, Parent = play }, {
		Kit.padding(10),
		Kit.list(Enum.FillDirection.Vertical, 4),
	})
	local telemetryValues: { [string]: TextLabel } = {}
	for index, row in { { "TOTAL DISTANCE", "Total" }, { "CARRY", "Carry" }, { "ROLL", "Roll" }, { "APEX", "Apex" }, { "SPIN", "Spin" } } do
		local line = Kit.new("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, LayoutOrder = index, Parent = telemetry }) :: Frame
		text(line, row[1], { Size = UDim2.new(1, 0, 0, 12), TextSize = 10, TextColor3 = C.TextDim })
		telemetryValues[row[2]] = text(line, "0", { Size = UDim2.new(1, 0, 0, 18), Position = UDim2.fromOffset(0, 12), TextSize = 17, Font = Theme.Fonts.Title })
	end

	-- ---- timing bar + aim stage panel (bottom-centre, above the club row) ----------------------------
	local bar = TimingBar.new({ Position = UDim2.new(0.5, 0, 1, -102), AnchorPoint = Vector2.new(0.5, 1), Parent = play })
	local aimPanel = Kit.panel({ Size = UDim2.fromOffset(560, 58), Position = UDim2.new(0.5, 0, 1, -102), AnchorPoint = Vector2.new(0.5, 1), Visible = false, Parent = play })
	local aimInfo = text(aimPanel, "", { Size = UDim2.new(1, -310, 1, 0), Position = UDim2.fromOffset(16, 0), TextSize = 15, Font = Theme.Fonts.Bold, TextWrapped = true })
	local viewButton = Kit.button("VIEW: AERIAL", "ghost", function()
		toggleView.fire()
	end, { Size = UDim2.fromOffset(104, 42), Position = UDim2.new(1, -290, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), TextSize = 12, Parent = aimPanel })
	local aimStage: AimStage? = nil
	local stageButton = Kit.button("SWING ▶", "primary", function()
		if aimStage == "Aim" then
			confirmAim.fire()
		elseif aimStage == "Swing" then
			backToAim.fire()
		end
	end, { Size = UDim2.fromOffset(170, 42), Position = UDim2.new(1, -180, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), TextSize = 18, Parent = aimPanel })
	-- In the swing stage the panel shrinks to a small "back to aim" chip beside the bar.
	local function setAimStage(stage: AimStage?, info: string?)
		aimStage = stage
		aimPanel.Visible = stage ~= nil
		if stage == "Aim" then
			aimPanel.Size = UDim2.fromOffset(560, 58)
			aimPanel.Position = UDim2.new(0.5, 0, 1, -102)
			aimPanel.AnchorPoint = Vector2.new(0.5, 1)
			aimInfo.Visible = true
			viewButton.Visible = true
			aimInfo.Text = info or "DRAG THE TARGET  ·  SPACE TO SWING"
			stageButton.Text = "SWING ▶"
			stageButton.Size = UDim2.fromOffset(170, 42)
			stageButton.Position = UDim2.new(1, -180, 0.5, 0)
		elseif stage == "Swing" then
			aimPanel.Size = UDim2.fromOffset(120, 50)
			aimPanel.Position = UDim2.new(0.5, 300, 1, -102)
			aimPanel.AnchorPoint = Vector2.new(0, 1)
			aimInfo.Visible = false
			viewButton.Visible = false
			stageButton.Text = "◀ AIM"
			stageButton.Size = UDim2.fromOffset(104, 38)
			stageButton.Position = UDim2.new(0, 8, 0.5, 0)
		end
	end

	-- ---- clubs + aim (bottom-centre) --------------------------------------------------------------------
	local controls = Kit.panel({ Size = UDim2.fromOffset(640, 92), Position = UDim2.fromScale(0.5, 1), AnchorPoint = Vector2.new(0.5, 1), Parent = play })
	local chipRow = Kit.new("Frame", { Size = UDim2.fromOffset(396, 72), Position = UDim2.fromOffset(10, 10), BackgroundTransparency = 1, Parent = controls }, {
		Kit.list(Enum.FillDirection.Horizontal, 6),
	}) :: Frame
	local puttTag = text(controls, "", { Size = UDim2.fromOffset(110, 16), Position = UDim2.fromOffset(414, 4), TextSize = 11, Font = Theme.Fonts.Title, TextColor3 = C.Good, TextXAlignment = Enum.TextXAlignment.Center })
	Kit.button("AUTO", "secondary", function()
		clubAuto.fire()
	end, { Size = UDim2.fromOffset(64, 40), Position = UDim2.fromOffset(414, 26), TextSize = 14, Parent = controls })
	Kit.button("◀", "ghost", function()
		aimStep.fire(-2)
	end, { Size = UDim2.fromOffset(36, 40), Position = UDim2.fromOffset(488, 26), Parent = controls })
	local aimText = text(controls, "AIM 0°", { Size = UDim2.fromOffset(64, 40), Position = UDim2.fromOffset(526, 26), TextSize = 15, Font = Theme.Fonts.Bold, TextXAlignment = Enum.TextXAlignment.Center })
	Kit.button("▶", "ghost", function()
		aimStep.fire(2)
	end, { Size = UDim2.fromOffset(36, 40), Position = UDim2.fromOffset(594, 26), Parent = controls })
	text(controls, "Q/E club  ·  ←/→ aim  ·  V view  ·  TAB", { Size = UDim2.fromOffset(220, 14), Position = UDim2.fromOffset(414, 72), TextSize = 11, TextColor3 = C.TextDim })

	local forfeitButton = Kit.button("FORFEIT", "ghost", function()
		forfeit.fire()
	end, { Size = UDim2.fromOffset(110, 36), Position = UDim2.fromScale(0, 1), AnchorPoint = Vector2.new(0, 1), TextSize = 13, Parent = play })

	-- ---- shot feedback (centre) ----------------------------------------------------------------
	local feedbackLabel = text(gui, "", {
		Size = UDim2.fromOffset(600, 70), Position = UDim2.new(0.5, -300, 0.5, -170), TextSize = 56, Font = Theme.Fonts.Title,
		TextXAlignment = Enum.TextXAlignment.Center, TextTransparency = 1, TextStrokeTransparency = 1, TextStrokeColor3 = Color3.new(0, 0, 0),
	})
	local summaryPanel: Frame? = nil

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

	local function rebuildClubs(model: MatchView.HudModel)
		Kit.clear(chipRow)
		local onGreen = model.Lie == "Green"
		for index, option in model.ClubOptions do
			local locked = onGreen and option.Label ~= "PT"
			local chip = Kit.button("", if option.Selected then "secondary" else "ghost", function()
				if not locked and not option.Selected then
					clubPick.fire(option.Label)
				end
			end, { Size = UDim2.fromOffset(61, 72), LayoutOrder = index, AutoButtonColor = not locked, Parent = chipRow })
			if locked then
				chip.BackgroundTransparency = 0.6
			end
			text(chip, option.Label, { Size = UDim2.new(1, 0, 0, 26), Position = UDim2.fromOffset(0, 6), TextSize = 20, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center, TextTransparency = if locked then 0.6 else 0 })
			local reach = if option.ReachYds > 0 then `{math.floor(option.ReachYds + 0.5)}y` else "putt"
			text(chip, reach, { Size = UDim2.new(1, 0, 0, 16), Position = UDim2.fromOffset(0, 32), TextSize = 12, TextColor3 = C.TextDim, TextXAlignment = Enum.TextXAlignment.Center, TextTransparency = if locked then 0.6 else 0 })
			if option.Recommended then
				text(chip, "★", { Size = UDim2.new(1, 0, 0, 16), Position = UDim2.fromOffset(0, 50), TextSize = 14, TextColor3 = C.Gold, TextXAlignment = Enum.TextXAlignment.Center })
			end
		end
		puttTag.Text = if onGreen then "PUTTING" else ""
	end

	local function update(model: MatchView.HudModel)
		holeTitle.Text = model.HoleText
		holeSub.Text = `{model.ParText}  ·  {model.YardsText}`
		holeProgress.Text = model.ProgressText .. elevationText
		windText.Text = model.WindText
		windArrow.Rotation = model.WindRotationDeg
		bannerText.Text = model.Banner
		bannerText.TextColor3 = if model.IsMyTurn then C.Accent else C.Text
		timerText.Text = if model.Phase == "Swing" then model.TimerText else ""
		timerText.TextColor3 = if model.TimerSeconds <= 10 and model.Phase == "Swing" then C.Danger else C.Gold
		yardsLabel.Text = model.YardsToPinText
		rebuildScoreboard(model.Rows)
		rebuildClubs(model)
		aimText.Text = `AIM {if model.AimDeg > 0 then "+" else ""}{math.floor(model.AimDeg + 0.5)}°`
		controls.Visible = model.IsMyTurn
		if not model.IsMyTurn then
			setAimStage(nil)
		end
	end

	-- Cheap per-frame countdown (the full `update` rebuilds the scoreboard).
	local function setTimer(seconds: number, running: boolean)
		timerText.Text = if running then Format.clock(seconds) else ""
		timerText.TextColor3 = if seconds <= 10 and running then C.Danger else C.Gold
	end

	local function setHole(hole: CourseDatabase.HoleDef)
		local feet = math.floor(CourseDatabase.elevationChange(hole) * 3.281 + 0.5)
		elevationText = if math.abs(feet) < 3 then "  ·  FLAT" elseif feet > 0 then `  ·  ▲ {feet} FT UPHILL` else `  ·  ▼ {-feet} FT DOWNHILL`
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
		-- Out-of-bounds zones (a road) as dark strips.
		local zones: { CourseDatabase.Bounds } = hole.OutOfBounds or {}
		for _, zone in zones do
			local ax, ay = layout.project(zone.MinX, zone.MinZ)
			local bx, by = layout.project(zone.MaxX, zone.MaxZ)
			Kit.new("Frame", {
				Position = UDim2.fromOffset(math.min(ax, bx), math.min(ay, by)), Size = UDim2.fromOffset(math.abs(bx - ax), math.abs(by - ay)),
				BackgroundColor3 = Color3.fromRGB(110, 92, 72), BorderSizePixel = 0, Parent = mapCanvas,
			})
		end
		-- My aim: a line from my ball to a yellow target reticle (hidden until aiming).
		targetLine = Kit.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Color3.fromRGB(255, 226, 92), BackgroundTransparency = 0.25,
			BorderSizePixel = 0, Visible = false, ZIndex = 6, Parent = mapCanvas,
		}) :: Frame
		targetRing = Kit.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(14, 14), BackgroundTransparency = 1, Visible = false, ZIndex = 7, Parent = mapCanvas,
		}, {
			Kit.new("UICorner", { CornerRadius = UDim.new(1, 0) }),
			Kit.glow(Color3.fromRGB(255, 226, 92), 2.5, 0),
			Kit.new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(4, 4),
				BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ZIndex = 8,
			}, { Kit.new("UICorner", { CornerRadius = UDim.new(1, 0) }) }),
		}) :: Frame
	end

	-- Project the 3D landing target onto the minimap (with an aim line from the ball).
	local function setTarget(ballX: number, ballZ: number, targetX: number, targetZ: number)
		local layout, ring, line = mapLayout, targetRing, targetLine
		if layout == nil or ring == nil or line == nil then
			return
		end
		local bx, by = layout.project(ballX, ballZ)
		local tx, ty = layout.project(targetX, targetZ)
		ring.Position = UDim2.fromOffset(tx, ty)
		ring.Visible = true
		local dx, dy = tx - bx, ty - by
		line.Position = UDim2.fromOffset((bx + tx) / 2, (by + ty) / 2)
		line.Size = UDim2.fromOffset(math.sqrt(dx * dx + dy * dy), 2)
		line.Rotation = math.deg(math.atan2(dy, dx))
		line.Visible = true
	end

	local function clearTarget()
		if targetRing then
			targetRing.Visible = false
		end
		if targetLine then
			targetLine.Visible = false
		end
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

	-- End of match: hide the play HUD and dock a scoreboard on the left so the 3D
	-- podium (winner / loser avatars) fills the rest of the screen.
	local function showSummary(summary: MatchView.Summary, podium: PodiumView.Podium, winningsText: string?)
		if summaryPanel then
			summaryPanel:Destroy()
		end
		play.Visible = false
		local height = 150 + #summary.Rows * 56 + (if winningsText then 40 else 0) + 70
		local card = Kit.panel({ Size = UDim2.fromOffset(420, height), Position = UDim2.fromScale(0, 0.5), AnchorPoint = Vector2.new(0, 0.5), BackgroundTransparency = 0, Parent = safe })
		summaryPanel = card
		local titleColor = if summary.Won then C.Good elseif summary.Draw then C.Gold else C.Poor
		text(card, podium.Title, { Size = UDim2.new(1, 0, 0, 64), Position = UDim2.fromOffset(0, 12), TextSize = 54, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = titleColor })
		text(card, podium.Subtitle, { Size = UDim2.new(1, -20, 0, 22), Position = UDim2.fromOffset(10, 76), TextSize = 16, Font = Theme.Fonts.Bold, TextColor3 = C.TextDim, TextXAlignment = Enum.TextXAlignment.Center })
		text(card, "FINAL SCOREBOARD", { Size = UDim2.new(1, -40, 0, 18), Position = UDim2.fromOffset(20, 112), TextSize = 12, TextColor3 = C.TextDim })
		for index, row in summary.Rows do
			local line = Kit.new("Frame", { Size = UDim2.new(1, -40, 0, 48), Position = UDim2.fromOffset(20, 134 + (index - 1) * 56), BackgroundColor3 = if row.IsMe then C.PanelLight else C.PanelDark, BorderSizePixel = 0, Parent = card }, { Kit.corner(8) }) :: Frame
			local holes = {}
			for _, strokes in row.HoleScores do
				table.insert(holes, tostring(strokes))
			end
			text(line, (if index == 1 and not summary.Draw then "🏆 " else "") .. row.Name .. (if row.Forfeited then "  (forfeit)" else ""), { Size = UDim2.new(0.55, 0, 1, 0), Position = UDim2.fromOffset(12, 0), TextSize = 17, Font = Theme.Fonts.Bold, TextTruncate = Enum.TextTruncate.AtEnd })
			text(line, table.concat(holes, " · "), { Size = UDim2.new(0.25, 0, 1, 0), Position = UDim2.fromScale(0.57, 0), TextSize = 14, TextColor3 = C.TextDim })
			text(line, tostring(row.Total), { Size = UDim2.fromOffset(56, 48), Position = UDim2.new(1, -60, 0, 0), TextSize = 26, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.Gold })
		end
		if winningsText then
			text(card, winningsText, { Size = UDim2.new(1, 0, 0, 28), Position = UDim2.new(0, 0, 1, -110), TextSize = 22, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.Gold })
		end
		Kit.button("RETURN TO LOBBY", "primary", function()
			leave.fire()
		end, { Size = UDim2.new(1, -40, 0, 50), Position = UDim2.new(0, 20, 1, -66), TextSize = 20, Parent = card })
	end

	return {
		Gui = gui,
		onClubPick = clubPick,
		onClubStep = clubStep,
		onClubAuto = clubAuto,
		onAimStep = aimStep,
		onLeave = leave,
		onForfeit = forfeit,
		onConfirmAim = confirmAim,
		onToggleView = toggleView,
		setViewLabel = function(view: string)
			viewButton.Text = if view == "Behind" then "VIEW: BEHIND" else "VIEW: AERIAL"
		end,
		setTarget = setTarget,
		clearTarget = clearTarget,
		onBackToAim = backToAim,
		setAimStage = setAimStage,
		setTimer = setTimer,
		update = update,
		setHole = setHole,
		setDots = setDots,
		setGauge = bar.set,
		feedback = feedback,
		showTelemetry = showTelemetry,
		hideTelemetry = function()
			telemetry.Visible = false
		end,
		showSummary = showSummary,
		setPlayVisible = function(visible: boolean)
			play.Visible = visible
			forfeitButton.Visible = visible
		end,
		destroy = function()
			gui:Destroy()
		end,
	}
end

return MatchHud
