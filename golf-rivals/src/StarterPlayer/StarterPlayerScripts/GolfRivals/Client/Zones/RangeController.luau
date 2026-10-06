--!strict
--[[
	RangeController.luau  (Client/Zones)

	The driving range, from the player's side.

	  1. Walk up to a hitting bay and press the "Hit balls" prompt (E) - the server
	     checks the bay is free and you are standing at it (RangeJoin).
	  2. Your golfer addresses a ball on the mat, the camera frames the range, and the
	     range HUD shows: club chips (no putter), aim, the vertical power meter and
	     today's range earnings. An aim arc shows where a flushed ball flies.
	  3. Three clicks: your swing starts at once; the server simulates the ball with
	     your EQUIPPED club stats (RangeSwing) and pays coins if it comes to rest on a
	     target green (double on the bullseye), up to the daily cap. The ball launches
	     on the club's impact frame and the chase camera follows it.
	  4. The next ball is teed up when the server says it's ready. LEAVE (or walking
	     into a match) gives the bay back.

	Nothing here decides a payout: the reply carries the server's shot and coins.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage.GolfRivals.Shared
local AimGuide = require(Shared.AimGuide)
local ClubStats = require(Shared.ClubStats)
local Config = require(Shared.Config)
local CourseLayout = require(Shared.CourseLayout)
local Format = require(Shared.Format)
local GaugeView = require(Shared.GaugeView)
local ItemDatabase = require(Shared.ItemDatabase)
local ProfileOps = require(Shared.ProfileOps)
local RangeRules = require(Shared.RangeRules)
local Remotes = require(Shared.Remotes)
local SwingMath = require(Shared.SwingMath)
local SwingStateMachine = require(Shared.SwingStateMachine)
local TelemetryView = require(Shared.TelemetryView)

local Bus = require(script.Parent.Parent.Bus)
local ClientState = require(script.Parent.Parent.ClientState)
local SwingController = require(script.Parent.Parent.SwingController)
local Kit = require(script.Parent.Parent.UI.Kit)
local PowerMeter = require(script.Parent.Parent.UI.PowerMeter)
local Theme = require(script.Parent.Parent.UI.Theme)
local Toast = require(script.Parent.Parent.UI.Toast)
local AimVisual = require(script.Parent.Parent.Golf.AimVisual)
local ClubLook = require(script.Parent.Parent.Golf.ClubLook)
local GolferRig = require(script.Parent.Parent.Golf.GolferRig)
local BallAnimator = require(script.Parent.Parent.Match.BallAnimator)
local CameraController = require(script.Parent.Parent.Match.CameraController)
local Reasons = require(script.Parent.Parent.Lobby.Reasons)

local RangeController = {}

local C = Theme.Colors
local SPM = CourseLayout.STUDS_PER_METER
local FIELD_Y = 0.1 -- studs: top of the range field
local MAT_LIFT = 0.7 -- the hitting mat sits this much higher; blended out over the first few studs
local localPlayer = Players.LocalPlayer

type Session = {
	Bay: RangeRules.Bay,
	Folder: Folder,
	Gui: ScreenGui,
	Rig: GolferRig.Rig?,
	Ball: BallAnimator.Animator,
	Aim: AimVisual.Visual,
	Meter: PowerMeter.Meter,
	Swing: SwingController.Controller,
	ClubLabel: string,
	AimDeg: number,
	Busy: boolean, -- a ball is being struck / flying
	Gauge: SwingStateMachine.Gauge?,
	Connections: { RBXScriptConnection },
	setEarnings: (earned: number, cap: number) -> (),
	setResult: (text: string, color: Color3) -> (),
	rebuildClubs: () -> (),
}

local session: Session? = nil
local savedWalkSpeed: number? = nil
local savedJump: number? = nil

-- Range frame (metres, y up from the ground) -> world studs, for balls hit from
-- `bay`: on the mat at the tee, blending down to the field level within 8 studs.
local function worldFor(bay: RangeRules.Bay): (number, number, number) -> Vector3
	local teeX, teeZ = RangeRules.teeOf(bay)
	return function(x: number, y: number, z: number): Vector3
		local wx, wz = RangeRules.toWorld(x, z)
		local fromTee = math.sqrt((x - teeX) ^ 2 + (z - teeZ) ^ 2) * SPM
		local lift = MAT_LIFT * math.clamp(1 - fromTee / 8, 0, 1)
		return Vector3.new(wx, FIELD_Y + lift + y * SPM, wz)
	end
end

local function statsFor(label: string): ClubStats.Stats
	local profile = ClientState.get()
	local clubId = if profile then profile.EquippedClubs[label] else nil
	return (profile and clubId and ProfileOps.clubStats(profile, clubId)) or ClubStats.baseline()
end

local function freeze(on: boolean)
	local character = localPlayer.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid == nil then
		return
	end
	if on then
		savedWalkSpeed, savedJump = humanoid.WalkSpeed, humanoid.JumpHeight
		humanoid.WalkSpeed, humanoid.JumpHeight = 0, 0
	else
		humanoid.WalkSpeed, humanoid.JumpHeight = savedWalkSpeed or 16, savedJump or 7.2
	end
end

-- World direction of an aim angle (range frame +X = downrange = world -X).
local function aimDirection(aimDeg: number): Vector3
	local a = math.rad(aimDeg)
	local wx, wz = RangeRules.toWorld(math.cos(a), math.sin(a))
	local ox, oz = RangeRules.toWorld(0, 0)
	return Vector3.new(wx - ox, 0, wz - oz).Unit
end

local function teeWorld(bay: RangeRules.Bay): Vector3
	local tx, tz = RangeRules.teeOf(bay)
	return worldFor(bay)(tx, 0, tz)
end

local function greenFor(s: Session): number
	local stats = statsFor(s.ClubLabel)
	return SwingMath.greenHalfWidth(stats.Accuracy, SwingMath.effectivePenalty("Tee", stats.Spin))
end

local function refreshAim(s: Session)
	if s.Busy then
		s.Aim.hide()
		return
	end
	local category = ClubStats.get(s.ClubLabel)
	if category == nil then
		return
	end
	local g = s.Gauge
	local power = 100
	if g and g.Phase == "PowerRising" then
		power = math.clamp(g.Marker, 0, 1) * 100
	elseif g and g.LockedPower then
		power = math.clamp(g.LockedPower, 0, 1) * 100
	end
	local tx, tz = RangeRules.teeOf(s.Bay)
	local guide = AimGuide.compute({
		Terrain = RangeRules.terrain(), X = tx, Z = tz, HeadingRad = math.rad(s.AimDeg),
		Slot = category, Stats = statsFor(s.ClubLabel), Lie = "Tee", Power = power,
	})
	local points: { Vector3 } = {}
	local toWorld = worldFor(s.Bay)
	for _, p in guide.Points do
		table.insert(points, toWorld(p.X, p.Y, p.Z) + Vector3.new(0, 0.85, 0))
	end
	s.Aim.show(points, false, Color3.fromRGB(120, 230, 255))
end

-- Golfer at the tee with the right club, camera behind, gauge armed.
local function readyBall(s: Session)
	local tee = teeWorld(s.Bay)
	s.Ball.placeAt(tee)
	s.Ball.setVisible(true)
	local dir = aimDirection(s.AimDeg)
	local rig = s.Rig
	if rig then
		local profile = ClientState.get()
		local color, material = ClubLook.forLabel(if profile then profile.EquippedItems else nil, s.ClubLabel)
		rig.setClub(color, material, false)
		rig.address(tee, dir, false)
	end
	CameraController.golfer(tee, dir.X, dir.Z, false)
	s.Busy = false
	s.Gauge = nil
	s.Swing.enable()
	s.Meter.set(GaugeView.layout({ Phase = "Idle", Marker = 0, LockedPower = nil }, greenFor(s)), nil)
	refreshAim(s)
end

local function targetName(targetId: string?): string?
	for _, target in RangeRules.Targets do
		if target.Id == targetId then
			return `{target.DistanceYds}-yard green`
		end
	end
	return nil
end

-- Third click.
local function strike(s: Session, power: number, offset: number)
	s.Busy = true
	s.Meter.set(nil, nil)
	s.Aim.hide()
	local impactReached = false
	local pendingLaunch: (() -> ())? = nil
	local function impact()
		impactReached = true
		local go = pendingLaunch
		if go then
			pendingLaunch = nil
			go()
		end
	end
	if s.Rig then
		(s.Rig :: GolferRig.Rig).play("Swing", power, impact)
	else
		task.delay(Config.Match.SwingLeadSeconds, impact)
	end

	task.spawn(function()
		local reply = Remotes.invoke("RangeSwing", s.ClubLabel, s.AimDeg, power, offset)
		if session ~= s then
			return
		end
		if type(reply) ~= "table" or not reply.ok or type(reply.Shot) ~= "table" then
			Toast.show(Reasons.text(if type(reply) == "table" then reply.reason else nil), "error")
			task.delay(1, function()
				if session == s then
					readyBall(s)
				end
			end)
			return
		end
		local shot = reply.Shot
		local receivedAt = os.clock()
		if type(reply.Earned) == "number" and type(reply.Cap) == "number" then
			s.setEarnings(reply.Earned, reply.Cap)
		end
		local function launch()
			if session ~= s then
				return
			end
			local quality = string.upper(tostring(shot.Quality or ""))
			s.setResult(if quality == "PERFECT" then "PERFECT!" else quality, if quality == "PERFECT" then C.Good elseif quality == "GOOD" then C.Gold else C.Poor)
			local tee = teeWorld(s.Bay)
			local dir = aimDirection(s.AimDeg)
			CameraController.follow(tee, dir.X, dir.Z, function(): Vector3?
				return s.Ball.Part.Position
			end)
			s.Ball.play(shot, worldFor(s.Bay), nil, function()
				if session ~= s then
					return
				end
				local live = TelemetryView.at(shot, TelemetryView.duration(shot) + 1)
				local name = targetName(shot.TargetId)
				local paid = if type(reply.Paid) == "number" then reply.Paid else 0
				if name and paid > 0 then
					s.setResult(`{if shot.Bullseye then "BULLSEYE! " else ""}{name}  +{Format.commas(paid)} coins`, C.Gold)
					BallAnimator.burst(s.Ball.Part.Position, if shot.Bullseye then C.Gold else C.Good, if shot.Bullseye then 90 else 50)
				elseif name then
					s.setResult(`{name} - daily range limit reached`, C.TextDim)
				else
					s.setResult(`{Format.yards(live.CarryYds)} carry · {Format.yards(live.TotalYds)} total`, C.Text)
				end
				-- The server's next-ball time: impact lead + flight + pad after the reply.
				local readyAt = receivedAt + (reply.ImpactDelay or Config.Match.SwingLeadSeconds) + (shot.TotalSeconds or 0) + Config.Range.ReadyPadSeconds
				task.delay(math.max(0.8, readyAt - os.clock() + 0.2), function()
					if session == s then
						readyBall(s)
					end
				end)
			end)
		end
		if impactReached then
			launch()
		else
			pendingLaunch = launch
		end
	end)
end

-- ---- HUD ---------------------------------------------------------------------------------------------

local function buildHud(s: Session, onLeave: () -> ())
	local safe = Kit.safeArea(s.Gui)
	local header = Kit.panel({ Size = UDim2.fromOffset(420, 64), Position = UDim2.fromScale(0.5, 0), AnchorPoint = Vector2.new(0.5, 0), Parent = safe })
	Kit.label(`DRIVING RANGE  ·  BAY {s.Bay.Id}`, { Size = UDim2.new(1, -24, 0, 26), Position = UDim2.fromOffset(12, 6), TextSize = 20, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center, Parent = header })
	local earnings = Kit.label("", { Size = UDim2.new(1, -24, 0, 22), Position = UDim2.fromOffset(12, 34), TextSize = 14, Font = Theme.Fonts.Bold, TextColor3 = C.Gold, TextXAlignment = Enum.TextXAlignment.Center, Parent = header })
	local result = Kit.label("Land on a target green to earn coins", {
		Size = UDim2.fromOffset(640, 40), Position = UDim2.new(0.5, 0, 0, 74), AnchorPoint = Vector2.new(0.5, 0), TextSize = 24, Font = Theme.Fonts.Title,
		TextXAlignment = Enum.TextXAlignment.Center, TextStrokeTransparency = 0.5, Parent = safe,
	})

	-- Target legend (left).
	local legend = Kit.panel({ Size = UDim2.fromOffset(200, 40 + #RangeRules.Targets * 30), Position = UDim2.fromScale(0, 0.5), AnchorPoint = Vector2.new(0, 0.5), Parent = safe }, {
		Kit.padding(10),
		Kit.list(Enum.FillDirection.Vertical, 4),
	})
	Kit.label("TARGETS", { Size = UDim2.new(1, 0, 0, 18), TextSize = 13, TextColor3 = C.TextDim, LayoutOrder = 0, Parent = legend })
	for index, target in RangeRules.Targets do
		local row = Kit.new("Frame", { Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1, LayoutOrder = index, Parent = legend }) :: Frame
		Kit.new("Frame", { Size = UDim2.fromOffset(12, 12), Position = UDim2.fromOffset(0, 7), BackgroundColor3 = Theme.rgb(target.Color), BorderSizePixel = 0, Parent = row }, { Kit.corner(6) })
		Kit.label(`{target.DistanceYds} yds`, { Size = UDim2.fromOffset(70, 26), Position = UDim2.fromOffset(20, 0), TextSize = 15, Font = Theme.Fonts.Bold, Parent = row })
		Kit.amount("Coins", tostring(target.Coins), { TextSize = 15, Position = UDim2.fromOffset(96, 2), Parent = row })
	end

	-- Power meter (right).
	s.Meter.Frame.Position = UDim2.new(1, 0, 0.5, 0)
	s.Meter.Frame.AnchorPoint = Vector2.new(1, 0.5)
	s.Meter.Frame.Parent = safe

	-- Clubs + aim + leave (bottom).
	local controls = Kit.panel({ Size = UDim2.fromOffset(600, 92), Position = UDim2.fromScale(0.5, 1), AnchorPoint = Vector2.new(0.5, 1), Parent = safe })
	local chips = Kit.new("Frame", { Size = UDim2.fromOffset(330, 72), Position = UDim2.fromOffset(10, 10), BackgroundTransparency = 1, Parent = controls }, {
		Kit.list(Enum.FillDirection.Horizontal, 6),
	}) :: Frame
	local function rebuildClubs()
		Kit.clear(chips)
		for index, category in ClubStats.Categories do
			if category.Class ~= "Putter" then
				local selected = category.Label == s.ClubLabel
				local chip = Kit.button("", if selected then "secondary" else "ghost", function()
					if s.Busy or category.Label == s.ClubLabel then
						return
					end
					s.ClubLabel = category.Label
					rebuildClubs()
					readyBall(s)
				end, { Size = UDim2.fromOffset(60, 72), LayoutOrder = index, Parent = chips })
				Kit.label(category.Label, { Size = UDim2.new(1, 0, 0, 28), Position = UDim2.fromOffset(0, 10), TextSize = 20, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center, Parent = chip })
				Kit.label(category.DisplayName, { Size = UDim2.new(1, -4, 0, 26), Position = UDim2.fromOffset(2, 38), TextSize = 10, TextColor3 = C.TextDim, TextXAlignment = Enum.TextXAlignment.Center, Parent = chip })
			end
		end
	end
	rebuildClubs()
	local aimLabel = Kit.label("AIM 0°", { Size = UDim2.fromOffset(70, 40), Position = UDim2.fromOffset(386, 26), TextSize = 15, Font = Theme.Fonts.Bold, TextXAlignment = Enum.TextXAlignment.Center, Parent = controls })
	local function nudge(delta: number)
		if s.Busy then
			return
		end
		s.AimDeg = math.clamp(s.AimDeg + delta, -RangeRules.MaxAimDegrees, RangeRules.MaxAimDegrees)
		aimLabel.Text = `AIM {if s.AimDeg > 0 then "+" else ""}{s.AimDeg}°`
		local rig = s.Rig
		local dir = aimDirection(s.AimDeg)
		if rig then
			rig.address(teeWorld(s.Bay), dir, false)
		end
		CameraController.golfer(teeWorld(s.Bay), dir.X, dir.Z, false)
		refreshAim(s)
	end
	Kit.button("◀", "ghost", function()
		nudge(-1)
	end, { Size = UDim2.fromOffset(36, 40), Position = UDim2.fromOffset(348, 26), Parent = controls })
	Kit.button("▶", "ghost", function()
		nudge(1)
	end, { Size = UDim2.fromOffset(36, 40), Position = UDim2.fromOffset(458, 26), Parent = controls })
	Kit.button("LEAVE", "danger", onLeave, { Size = UDim2.fromOffset(90, 40), Position = UDim2.fromOffset(502, 26), TextSize = 15, Parent = controls })

	table.insert(s.Connections, UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Left then
			nudge(-1)
		elseif input.KeyCode == Enum.KeyCode.Right then
			nudge(1)
		end
	end))

	s.setEarnings = function(earned: number, cap: number)
		earnings.Text = `Range earnings today: {Format.commas(earned)} / {Format.commas(cap)}`
	end
	s.setResult = function(textValue: string, color: Color3)
		result.Text = textValue
		result.TextColor3 = color
	end
	s.rebuildClubs = rebuildClubs
end

-- ---- enter / leave --------------------------------------------------------------------------------------

local function leave()
	local s = session
	if s == nil then
		return
	end
	session = nil
	Remotes.fire("RangeLeave")
	s.Swing.destroy()
	for _, connection in s.Connections do
		connection:Disconnect()
	end
	if s.Rig then
		(s.Rig :: GolferRig.Rig).destroy()
	end
	s.Ball.destroy()
	s.Aim.destroy()
	s.Gui:Destroy()
	s.Folder:Destroy()
	CameraController.release()
	freeze(false)
	-- Step back off the mat.
	local character = localPlayer.Character
	if character then
		local spot = Vector3.new(RangeRules.ORIGIN.X + 18, 4, s.Bay.WorldZ)
		character:PivotTo(CFrame.lookAt(spot, spot + Vector3.new(1, 0, 0)))
	end
	Bus.RangeExited.fire()
end

local function enter(bay: RangeRules.Bay, earned: number, cap: number)
	local folder = Instance.new("Folder")
	folder.Name = "GolfRivalsRange"
	folder.Parent = workspace
	local profile = ClientState.get()
	local equipped = if profile then profile.EquippedItems else nil
	local ballItem = if equipped then ItemDatabase.get(equipped.BallModel) else nil
	local trailItem = if equipped then ItemDatabase.get(equipped.BallTrail) else nil
	local ball = BallAnimator.new(folder, {
		Color = if ballItem and ballItem.Visual.Primary then Theme.rgb(ballItem.Visual.Primary) else Color3.fromRGB(240, 240, 245),
		TrailColor = if trailItem and trailItem.Visual.Primary then Theme.rgb(trailItem.Visual.Primary) else Color3.fromRGB(240, 240, 240),
		Neon = false,
	}, "RangeBall")
	local character = localPlayer.Character
	local s: Session
	s = {
		Bay = bay,
		Folder = folder,
		Gui = Kit.screenGui("GolfRivalsRangeHud", 6),
		Rig = if character then GolferRig.forCharacter(character) else nil,
		Ball = ball,
		Aim = AimVisual.new(folder),
		Meter = PowerMeter.new({}),
		Swing = SwingController.new(function(g: SwingStateMachine.Gauge)
			s.Gauge = g
			s.Meter.set(GaugeView.layout(g, greenFor(s)), nil)
			refreshAim(s)
		end, function(power: number, offset: number)
			strike(s, power, offset)
		end),
		ClubLabel = ClubStats.DRIVER,
		AimDeg = 0,
		Busy = false,
		Gauge = nil,
		Connections = {},
		setEarnings = function(_earned: number, _cap: number) end,
		setResult = function(_text: string, _color: Color3) end,
		rebuildClubs = function() end,
	}
	session = s
	Bus.RangeEntered.fire()
	freeze(true)
	buildHud(s, leave)
	s.setEarnings(earned, cap)
	readyBall(s)
end

function RangeController.start()
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, player: Player)
		if player ~= localPlayer or prompt.Name ~= "RangeBayPrompt" or session ~= nil then
			return
		end
		local bay = RangeRules.bay(prompt:GetAttribute("BayId"))
		if bay == nil then
			return
		end
		local reply = Remotes.invoke("RangeJoin", bay.Id)
		if type(reply) == "table" and reply.ok then
			enter(bay, tonumber(reply.Earned) or 0, tonumber(reply.Cap) or Config.Range.DailyCoinCap)
			Toast.show("Three clicks to swing. Land on a green to earn coins!", "info")
		else
			Toast.show(Reasons.text(if type(reply) == "table" then reply.reason else nil), "error")
		end
	end)
	-- A match (or the queue popping) always wins over the range.
	Bus.MatchEntered.connect(function()
		leave()
	end)
	localPlayer.CharacterRemoving:Connect(function()
		leave()
	end)
end

function RangeController.active(): boolean
	return session ~= nil
end

return RangeController
