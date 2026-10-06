--!strict
--[[
	MatchController.luau  (Client/Match)

	Runs the in-match experience on the client. The server is authoritative; this
	module listens to two remotes and turns them into what the player sees:

	  MatchState  -> hole changes, scoreboard, whose turn, club/aim, timer
	  ShotResult  -> ball flight animation, chase camera, live telemetry, effects

	TURN FLOW (my turn):  MatchState(Swing, active = me)
	    -> address camera behind the ball, gauge armed (SwingController)
	    -> three clicks -> SubmitSwing(power, offset) to the server
	    -> ShotResult arrives: gauge disarmed, ball flies, camera chases it, telemetry
	       counts up until the ball is at rest, then feedback / effects
	    -> next MatchState (someone's turn) -> repeat.

	While a ball is flying (`animating`) state updates still refresh the text HUD but
	do not move balls, rebuild holes or arm the gauge; when the animation ends the
	latest state is applied. That keeps a late/early packet from teleporting a ball
	mid-flight.

	ARENAS: each match renders at its own world offset (`MatchId` x ARENA_SPACING),
	far from the lobby and from other matches, so players in different matches never
	see each other's course or characters.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.GolfRivals.Shared
local ClubAdvisor = require(Shared.ClubAdvisor)
local ClubDatabase = require(Shared.ClubDatabase)
local Config = require(Shared.Config)
local CourseDatabase = require(Shared.CourseDatabase)
local Format = require(Shared.Format)
local GaugeView = require(Shared.GaugeView)
local ItemDatabase = require(Shared.ItemDatabase)
local MatchView = require(Shared.MatchView)
local ProfileOps = require(Shared.ProfileOps)
local Remotes = require(Shared.Remotes)
local SwingMath = require(Shared.SwingMath)
local TelemetryView = require(Shared.TelemetryView)

local Bus = require(script.Parent.Parent.Bus)
local ClientState = require(script.Parent.Parent.ClientState)
local SwingController = require(script.Parent.Parent.SwingController)
local Theme = require(script.Parent.Parent.UI.Theme)
local BallAnimator = require(script.Parent.BallAnimator)
local CameraController = require(script.Parent.CameraController)
local CourseBuilder = require(script.Parent.CourseBuilder)
local MatchHud = require(script.Parent.MatchHud)

local MatchController = {}

local ARENA_BASE = Vector3.new(30000, 0, 0)
local ARENA_SPACING = 6000
local localPlayer = Players.LocalPlayer
local DEFAULT_STATS: ClubDatabase.Stats = { Distance = 50, Accuracy = 50, Forgiveness = 50 }

-- ---- session state (nil / false while in the lobby) --------------------------------------
local active = false
local myId = ""
local hud: MatchHud.Hud? = nil
local course: CourseBuilder.Course? = nil
local balls: { [string]: BallAnimator.Animator } = {}
local cosmeticsById: { [string]: { [string]: string } } = {}
local swing: SwingController.Controller? = nil
local armed = false
local animating = false
local introActive = false
local currentHoleId = 0
local lastSnapshot: any = nil
local snapshotAt = 0.0
local arenaOrigin = ARENA_BASE
local coinsAtStart = 0
local summaryShown = false
local savedWalkSpeed: number? = nil
local savedJump: number? = nil
local connections: { RBXScriptConnection } = {}

-- ---- helpers --------------------------------------------------------------------------------

-- Effective stats of the club in a bag slot, from my (server-synced) profile.
local function statsFor(label: string): ClubDatabase.Stats
	local profile = ClientState.get()
	if profile == nil then
		return DEFAULT_STATS
	end
	local clubId = profile.EquippedClubs[label]
	return (clubId and ProfileOps.clubStats(profile, clubId)) or DEFAULT_STATS
end

local function myView(): any
	if lastSnapshot == nil then
		return nil
	end
	for _, view in lastSnapshot.Players do
		if view.Id == myId then
			return view
		end
	end
	return nil
end

-- Unit aim direction in the hole frame for a player (pin direction + aim offset).
local function aimDirection(view: any): (number, number)
	local pin = lastSnapshot.Hole.Pin
	local heading = math.atan2(pin.Z - view.Position.Z, pin.X - view.Position.X) + math.rad(view.AimDeg)
	return math.cos(heading), math.sin(heading)
end

local function appearanceFor(playerId: string): BallAnimator.Appearance
	local equipped = cosmeticsById[playerId]
	local model = if equipped then ItemDatabase.get(equipped.BallModel) else nil
	local trail = if equipped then ItemDatabase.get(equipped.BallTrail) else nil
	local modelColor = if model and model.Visual.Primary then model.Visual.Primary else { 240, 240, 245 }
	local trailColor = if trail and trail.Visual.Primary then trail.Visual.Primary else { 240, 240, 240 }
	return {
		Color = Theme.rgb(modelColor),
		TrailColor = Theme.rgb(trailColor),
		Neon = model ~= nil and (model.Rarity == "Mythical" or model.Rarity == "Legendary"),
	}
end

local function holeEffectColor(playerId: string): Color3
	local equipped = cosmeticsById[playerId]
	local effect = if equipped then ItemDatabase.get(equipped.HoleEffect) else nil
	if effect and effect.Visual.Primary then
		return Theme.rgb(effect.Visual.Primary)
	end
	return Theme.Colors.Gold
end

local function lobbyCFrame(): CFrame?
	local spawn = workspace:FindFirstChild("LobbySpawn")
	if spawn and spawn:IsA("BasePart") then
		return spawn.CFrame + Vector3.new(0, 5, 0)
	end
	return nil
end

-- Stand the golfer beside their ball, facing down the aim line.
local function placeCharacter(ballWorld: Vector3, dirX: number, dirZ: number)
	local character = localPlayer.Character
	if character == nil then
		return
	end
	local forward = Vector3.new(dirX, 0, dirZ)
	local right = Vector3.new(-dirZ, 0, dirX)
	local position = ballWorld - forward * 3 - right * 4 + Vector3.new(0, 3.5, 0)
	character:PivotTo(CFrame.lookAt(position, position + forward))
end

local function freezeCharacter(freeze: boolean)
	local character = localPlayer.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid == nil then
		return
	end
	if freeze then
		savedWalkSpeed, savedJump = humanoid.WalkSpeed, humanoid.JumpHeight
		humanoid.WalkSpeed = 0
		humanoid.JumpHeight = 0
	else
		humanoid.WalkSpeed = savedWalkSpeed or 16
		humanoid.JumpHeight = savedJump or 7.2
	end
end

local function ballWorld(view: any): Vector3
	local c = course :: CourseBuilder.Course
	return c.toWorld(view.Position.X, 0, view.Position.Z)
end

-- ---- gauge ---------------------------------------------------------------------------------------

local function onGauge(gauge: any)
	local view = myView()
	if hud == nil or view == nil then
		return
	end
	local stats = statsFor(view.ClubLabel)
	local penalty = SwingMath.effectivePenalty(view.Lie, stats.Forgiveness)
	local green = SwingMath.greenHalfWidth(stats.Accuracy, penalty)
	hud.setGauge(GaugeView.layout(gauge, green), nil)
end

local function arm()
	if armed or swing == nil or hud == nil then
		return
	end
	armed = true
	swing.enable()
	hud.setGauge(GaugeView.layout({ Phase = "Idle", Marker = 0, LockedPower = nil }, SwingMath.greenHalfWidth(50, 0)), nil)
end

local function disarm()
	if swing then
		swing.disable()
	end
	armed = false
	if hud then
		hud.setGauge(nil, nil)
	end
end

-- ---- applying a snapshot ----------------------------------------------------------------------------------

local function buildHole(snapshot: any)
	if course then
		course.destroy()
	end
	for _, ball in balls do
		ball.destroy()
	end
	balls = {}

	local hole: CourseDatabase.HoleDef = CourseDatabase.Holes[1]
	for _, candidate in CourseDatabase.Holes do
		if candidate.Id == snapshot.Hole.Id then
			hole = candidate
		end
	end
	currentHoleId = hole.Id
	course = CourseBuilder.build(hole, arenaOrigin)
	local built = course :: CourseBuilder.Course
	for _, view in snapshot.Players do
		balls[view.Id] = BallAnimator.new(built.Folder, appearanceFor(view.Id), `Ball_{view.Id}`)
	end
	if hud then
		hud.setHole(hole)
	end

	-- Fly over the hole, then settle behind the tee.
	introActive = true
	CameraController.intro(built.Tee, built.Pin, 4, function()
		introActive = false
		MatchController.apply(lastSnapshot)
	end)
end

-- Bring everything in line with the latest server state.
function MatchController.apply(snapshot: any)
	if not active or snapshot == nil or hud == nil then
		return
	end
	if snapshot.Hole.Id ~= currentHoleId and not animating then
		buildHole(snapshot)
	end
	local model = MatchView.hud(snapshot, myId, statsFor)
	hud.update(model)

	if animating or course == nil then
		return -- text is fresh; balls, camera and gauge wait for the animation to end
	end
	local built = course :: CourseBuilder.Course

	local dots: { MatchHud.Dot } = {}
	for _, view in snapshot.Players do
		local ball = balls[view.Id]
		if ball then
			ball.placeAt(built.toWorld(view.Position.X, 0, view.Position.Z))
			ball.setVisible(not view.Holed)
		end
		table.insert(dots, { X = view.Position.X, Z = view.Position.Z, IsMe = view.Id == myId, Holed = view.Holed })
	end
	hud.setDots(dots)

	local mine = myView()
	if model.IsMyTurn and mine and not introActive then
		local dirX, dirZ = aimDirection(mine)
		local position = ballWorld(mine)
		CameraController.address(position, dirX, dirZ)
		placeCharacter(position, dirX, dirZ)
		arm()
	elseif armed then
		disarm()
	end

	if snapshot.Finished and not summaryShown then
		summaryShown = true
		disarm()
		local function show()
			local profile = ClientState.get()
			local delta = if profile then profile.Coins - coinsAtStart else 0
			(hud :: MatchHud.Hud).showSummary(MatchView.summary(snapshot, myId), if delta > 0 then `+{Format.commas(delta)} COINS` else nil)
		end
		show()
		-- The payout reaches the profile just after the final state: refresh the text once.
		task.delay(1.5, function()
			if active and hud then
				show()
			end
		end)
	end
end

-- ---- shots -------------------------------------------------------------------------------------------------

local function onShot(shot: any)
	if not active or course == nil or hud == nil then
		return
	end
	local built = course :: CourseBuilder.Course
	local ball = balls[shot.PlayerId]
	if ball == nil then
		return
	end
	animating = true
	disarm()

	local startX, startZ = shot.Start.X, shot.Start.Z
	local aimX, aimZ = shot.End.X - startX, shot.End.Z - startZ
	if math.abs(aimX) + math.abs(aimZ) < 1e-6 then
		local sample = shot.Samples[#shot.Samples]
		aimX, aimZ = sample[2] - startX, sample[4] - startZ
	end
	local length = math.sqrt(aimX * aimX + aimZ * aimZ)
	if length > 1e-6 then
		aimX, aimZ = aimX / length, aimZ / length
	else
		aimX, aimZ = 1, 0
	end

	if shot.Quality then
		local quality = string.upper(shot.Quality)
		local color = if quality == "PERFECT" then Theme.Colors.Good elseif quality == "GOOD" then Theme.Colors.Gold else Theme.Colors.Poor
		hud.feedback(if shot.Auto then "TIME OUT" else (if quality == "PERFECT" then "PERFECT!" else quality), color)
	end

	ball.setVisible(true)
	local startWorld = built.toWorld(startX, 0, startZ)
	CameraController.follow(startWorld, aimX, aimZ, function(): Vector3?
		return ball.Part.Position
	end)

	ball.play(shot, built.toWorld, function(t: number, _position: Vector3)
		if hud then
			hud.showTelemetry(TelemetryView.at(shot, t))
		end
	end, function()
		local endView = lastSnapshot
		if hud then
			hud.showTelemetry(TelemetryView.at(shot, TelemetryView.duration(shot) + 1))
			local par = if endView then endView.Hole.Par else 4
			if shot.Holed then
				BallAnimator.burst(built.Pin, holeEffectColor(shot.PlayerId), 80)
				hud.feedback(string.upper(Format.scoreName(shot.Stroke, par)), Theme.Colors.Gold)
			elseif shot.Penalty then
				BallAnimator.burst(built.toWorld(shot.Samples[#shot.Samples][2], 0, shot.Samples[#shot.Samples][4]), Theme.Colors.Blue, 50)
				hud.feedback("PENALTY STROKE", Theme.Colors.Poor)
			end
		end
		task.delay(2.2, function()
			if not active then
				return
			end
			animating = false
			if hud then
				hud.hideTelemetry()
			end
			MatchController.apply(lastSnapshot)
		end)
	end)
end

-- ---- entering / leaving a match ------------------------------------------------------------------------------

local function exitMatch()
	if not active then
		return
	end
	active = false
	armed = false
	animating = false
	introActive = false
	summaryShown = false
	currentHoleId = 0
	for _, connection in connections do
		connection:Disconnect()
	end
	connections = {}
	if swing then
		swing.destroy()
		swing = nil
	end
	for _, ball in balls do
		ball.destroy()
	end
	balls = {}
	if course then
		course.destroy()
		course = nil
	end
	if hud then
		hud.destroy()
		hud = nil
	end
	CameraController.release()
	freezeCharacter(false)
	local home = lobbyCFrame()
	local character = localPlayer.Character
	if home and character then
		character:PivotTo(home)
	end
	Bus.MatchExited.fire()
end

local function stepClub(delta: number)
	local view = myView()
	if view == nil or lastSnapshot == nil then
		return
	end
	local labels = ClubDatabase.BagSlots
	local index = 1
	for i, slot in labels do
		if slot.Label == view.ClubLabel then
			index = i
		end
	end
	local nextIndex = (index - 1 + delta) % #labels + 1
	Remotes.fire("SelectClub", labels[nextIndex].Label)
end

local function stepAim(delta: number)
	local view = myView()
	if view == nil then
		return
	end
	Remotes.fire("SetAim", math.clamp(view.AimDeg + delta, -Config.Match.MaxAimDegrees, Config.Match.MaxAimDegrees))
end

local function enter(snapshot: any)
	active = true
	summaryShown = false
	myId = tostring(localPlayer.UserId)
	arenaOrigin = ARENA_BASE + Vector3.new((snapshot.MatchId or 0) * ARENA_SPACING, 0, 0)
	local profile = ClientState.get()
	coinsAtStart = if profile then profile.Coins else 0
	cosmeticsById = {}
	for _, view in snapshot.Players do
		cosmeticsById[view.Id] = view.Cosmetics
	end

	Bus.MatchEntered.fire()
	local newHud = MatchHud.new()
	hud = newHud
	swing = SwingController.new(onGauge)
	freezeCharacter(true)

	newHud.onClubStep.connect(stepClub)
	newHud.onAimStep.connect(stepAim)
	newHud.onClubAuto.connect(function()
		local view = myView()
		if view then
			Remotes.fire("SelectClub", ClubAdvisor.recommendClub(view.YardsToPin, view.Lie, statsFor))
		end
	end)
	newHud.onForfeit.connect(function()
		Remotes.invoke("LeaveMatch")
	end)
	newHud.onLeave.connect(exitMatch)

	-- Keyboard: Q / E change club, left / right arrows nudge the aim.
	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
			if processed or not armed then
				return
			end
			if input.KeyCode == Enum.KeyCode.Q then
				stepClub(-1)
			elseif input.KeyCode == Enum.KeyCode.E then
				stepClub(1)
			elseif input.KeyCode == Enum.KeyCode.Left then
				stepAim(-1)
			elseif input.KeyCode == Enum.KeyCode.Right then
				stepAim(1)
			end
		end)
	)
	-- Smooth turn countdown between server updates.
	table.insert(
		connections,
		RunService.RenderStepped:Connect(function()
			if hud and lastSnapshot and lastSnapshot.Phase == "Swing" then
				hud.setTimer(math.max(0, lastSnapshot.TurnSecondsLeft - (os.clock() - snapshotAt)), true)
			end
		end)
	)
end

function MatchController.start()
	Remotes.onClientEvent("MatchState", function(snapshot: any)
		lastSnapshot = snapshot
		snapshotAt = os.clock()
		if not active then
			enter(snapshot)
		end
		MatchController.apply(snapshot)
	end)
	Remotes.onClientEvent("ShotResult", onShot)
end

return MatchController
