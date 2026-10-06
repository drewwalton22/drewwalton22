--!strict
--[[
	MatchController.luau  (Client/Match)

	Runs the in-match experience on the client. The server is authoritative; this
	module listens to two remotes and turns them into what the player sees:

	  MatchState  -> hole changes, scoreboard, whose turn, club/aim, timer
	  ShotResult  -> golfer swing -> club impact -> ball flight, chase camera,
	                 live telemetry, effects

	EVERY SHOT (yours, your opponent's, the bot's) plays in the same order:
	  1. the shooter's golfer (your avatar, the opponent's avatar, or the bot rig)
	     stands side-on at the ball with the club from their equipped skin
	  2. the swing animation plays (GolferRig; uploaded asset or procedural)
	  3. on the IMPACT frame the ball starts flying - the server already waited
	     Config.Match.SwingLeadSeconds before its flight clock, so client and
	     server stay in step
	  Your own swing starts the moment your second click lands (no network wait);
	  the ball still launches only once the server's result has arrived AND the
	  club has reached the ball.

	YOUR TURN = two stages
	  1. AIM (AerialAim): the camera smooth-tweens to an overhead view above the
	     landing area; drag the glowing target reticle on the ground (clamped to the
	     club's max distance, ClubStats.maxDistanceYds). SetAim follows it live.
	     SWING button / Space -> stage 2.
	  2. SWING: the camera tweens back behind your golfer and the 2-STAGE TIMING BAR
	     arms (power, then accuracy; slower putting bar on the green). A white tick
	     on the power track marks the power the target needs. "◀ AIM" / Tab goes back
	     while power isn't locked yet.
	  * an AIM ARC (or, on the green, a PUTTING LINE on the ground) shows where a
	    perfectly struck ball goes with the selected club and aim, at the target
	    power while aiming and live with the power bar while swinging (AimGuide = the
	    same physics the server runs, minus wind)
	  * on the green the putter is selected automatically and locked in

	COURSES: the hole is wherever the server put it (snapshot.Course): Smooth
	Terrain holes and hand-built maps replicate by themselves and are measured by
	raycast (CourseView / TerrainSurface), classic part holes are built locally.

	COSMETICS: balls, trails, club meshes, swing animations and hole effects come
	from CosmeticsData via CosmeticBuilder, for every golfer in the match.

	INTRO: each hole opens with a fly-over that the SERVER times (Intro phase), so
	nobody - bots included - can shoot while it plays, and nothing here waits on a
	camera callback (the old bug: a bot shot during the fly-over cancelled the intro
	callback and the gauge never armed).

	SHOT QUEUE: results that arrive while a shot is still animating wait their turn,
	so two shots never overlap and a ball is never teleported mid-flight.

	END: the podium (PodiumStage) shows the winner and loser avatars with victory /
	defeat animations, next to the final scoreboard.

	ARENAS: each match plays at its own world offset (snapshot.Course.Origin).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage.GolfRivals.Shared
local AimGuide = require(Shared.AimGuide)
local AimMath = require(Shared.AimMath)
local ClubAdvisor = require(Shared.ClubAdvisor)
local ClubDatabase = require(Shared.ClubDatabase)
local ClubStats = require(Shared.ClubStats)
local Config = require(Shared.Config)
local CosmeticsData = require(Shared.CosmeticsData)
local Format = require(Shared.Format)
local GaugeView = require(Shared.GaugeView)
local MatchView = require(Shared.MatchView)
local PodiumView = require(Shared.PodiumView)
local ProfileOps = require(Shared.ProfileOps)
local Remotes = require(Shared.Remotes)
local SwingMath = require(Shared.SwingMath)
local SwingPose = require(Shared.SwingPose)
local SwingStateMachine = require(Shared.SwingStateMachine)
local TelemetryView = require(Shared.TelemetryView)

local Bus = require(script.Parent.Parent.Bus)
local ClientState = require(script.Parent.Parent.ClientState)
local SwingController = require(script.Parent.Parent.SwingController)
local Theme = require(script.Parent.Parent.UI.Theme)
local AerialAim = require(script.Parent.Parent.Golf.AerialAim)
local AimVisual = require(script.Parent.Parent.Golf.AimVisual)
local CosmeticBuilder = require(script.Parent.Parent.Golf.CosmeticBuilder)
local GolferRig = require(script.Parent.Parent.Golf.GolferRig)
local BallAnimator = require(script.Parent.BallAnimator)
local CameraController = require(script.Parent.CameraController)
local CourseView = require(script.Parent.CourseView)
local MatchHud = require(script.Parent.MatchHud)
local PodiumStage = require(script.Parent.PodiumStage)

local MatchController = {}

local PODIUM_HEIGHT = 900 -- the podium stage floats above the arena
local AIM_REFRESH_SECONDS = 0.05
local SET_AIM_INTERVAL = 0.25 -- seconds between SetAim sends while dragging
local ARM_DELAY = 0.35 -- seconds between SWING and the power marker starting
local localPlayer = Players.LocalPlayer

type Stage = "Aim" | "Swing"

type LocalSwing = {
	ImpactReached: boolean,
	Launch: (() -> ())?,
	Consumed: boolean,
}

-- ---- session state (nil / false while in the lobby) --------------------------------------
local active = false
local myId = ""
local hud: MatchHud.Hud? = nil
local course: CourseView.View? = nil
local aerial: AerialAim.Aim? = nil
local stage: Stage? = nil -- my turn's stage (nil when it isn't my turn)
local myAimDeg: number? = nil -- my live aim while I'm aiming (ahead of the server)
local aimSentAt = 0.0
local aimSent: number? = nil
local armToken = 0
local limitsKey = ""
local matchFolder: Folder? = nil
local balls: { [string]: BallAnimator.Animator } = {}
local rigs: { [string]: GolferRig.Rig } = {}
local cosmeticsById: { [string]: { [string]: string } } = {}
local aim: AimVisual.Visual? = nil
local swing: SwingController.Controller? = nil
local podium: PodiumStage.Stage? = nil
local armed = false
local animating = false
local shotQueue: { any } = {}
local localSwing: LocalSwing? = nil
local gauge: SwingStateMachine.Gauge? = nil
local currentHoleId = 0
local lastSnapshot: any = nil
local snapshotAt = 0.0
local coinsAtStart = 0
local summaryShown = false
local savedWalkSpeed: number? = nil
local savedJump: number? = nil
local aimKey = ""
local aimRefreshedAt = 0.0
local connections: { RBXScriptConnection } = {}

-- ---- helpers --------------------------------------------------------------------------------

local function statsFor(label: string): ClubDatabase.Stats
	local profile = ClientState.get()
	if profile == nil then
		return ClubStats.baseline()
	end
	local clubId = profile.EquippedClubs[label]
	return (clubId and ProfileOps.clubStats(profile, clubId)) or ClubStats.baseline()
end

local function viewOf(id: string?): any
	if lastSnapshot == nil or id == nil then
		return nil
	end
	for _, view in lastSnapshot.Players do
		if view.Id == id then
			return view
		end
	end
	return nil
end

local function myView(): any
	return viewOf(myId)
end

-- Direction from a player's ball to the pin (radians, hole frame).
local function pinHeadingOf(view: any): number
	local pin = lastSnapshot.Hole.Pin
	return math.atan2(pin.Z - view.Position.Z, pin.X - view.Position.X)
end

-- Aim heading for a player: pin direction + aim offset (mine is live while aiming).
local function headingOf(view: any): number
	local aimDeg = if view.Id == myId and myAimDeg ~= nil then myAimDeg else view.AimDeg
	return pinHeadingOf(view) + math.rad(aimDeg)
end

local function equippedOf(playerId: string): { [string]: string }
	return cosmeticsById[playerId] or {}
end

local function appearanceFor(playerId: string): BallAnimator.Appearance
	local equipped = equippedOf(playerId)
	return {
		Ball = CosmeticsData.ball(equipped.BallModel),
		Trail = CosmeticsData.trail(equipped.BallTrail),
	}
end

-- The player's equipped swing animation (nil = procedural), full swings only.
local function animationFor(playerId: string, kind: string): string?
	if kind ~= "Swing" then
		return nil
	end
	local id = CosmeticsData.animation(equippedOf(playerId).Swing).AnimationId
	return if id ~= "" then id else nil
end

local function lobbyCFrame(): CFrame?
	local spawn = workspace:FindFirstChild("LobbySpawn")
	if spawn and spawn:IsA("BasePart") then
		return spawn.CFrame + Vector3.new(0, 5, 0)
	end
	return nil
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
	local c = course :: CourseView.View
	return c.ground(view.Position.X, view.Position.Z)
end

-- ---- golfers -------------------------------------------------------------------------------------

-- The rig for a player: my avatar, the bot rig, or an opponent's avatar (animated
-- locally; their own client positions it).
local function rigFor(view: any): GolferRig.Rig?
	local existing = rigs[view.Id]
	if existing and existing.Model.Parent ~= nil then
		return existing
	end
	local rig: GolferRig.Rig? = nil
	if view.IsBot then
		rig = GolferRig.newBot(view.Name, matchFolder :: Folder, nil)
	else
		local player = Players:GetPlayerByUserId(tonumber(view.Id) or 0)
		local character = if player then player.Character else nil
		if character then
			rig = GolferRig.forCharacter(character)
		end
	end
	if rig then
		rigs[view.Id] = rig
	end
	return rig
end

-- Who may this client move? Its own character and bots; other humans are placed
-- by their own clients (we only animate them).
local function weControl(view: any): boolean
	return view.IsBot or view.Id == myId
end

-- The club from the player's equipped skin for that category (mesh / template /
-- procedural head), welded into the golfer's hand.
local function dressClub(rig: GolferRig.Rig, view: any, label: string)
	local category = ClubStats.get(label)
	local class = if category then category.Class else "Driver"
	rig.setClub(CosmeticsData.club(equippedOf(view.Id)[class], class), class == "Putter")
end

-- Address the ball (active golfer) or wait to the side (everyone else).
local function placeGolfers(snapshot: any)
	if course == nil then
		return
	end
	for _, view in snapshot.Players do
		local rig = rigFor(view)
		if rig and weControl(view) and not (view.Id == myId and localSwing ~= nil) then
			local heading = headingOf(view)
			local dir = Vector3.new(math.cos(heading), 0, math.sin(heading))
			local position = ballWorld(view)
			if snapshot.Phase == "Swing" and snapshot.ActiveId == view.Id then
				dressClub(rig, view, view.ClubLabel)
				rig.address(position, dir, view.Lie == "Green")
			else
				-- Out of the way: behind and to the side of their own ball.
				rig.removeClub()
				rig.stop()
				local right = Vector3.new(-dir.Z, 0, dir.X)
				local spot = position - dir * 7 - right * 5
				rig.standAt(CFrame.lookAt(spot, spot + dir))
			end
		end
	end
end

-- ---- aim arc / putting line --------------------------------------------------------------------------

local function hideAim()
	aimKey = ""
	if aim then
		aim.hide()
	end
end

-- The club's full distance (yards) for a player's current club and stats.
local function maxYdsFor(view: any): number
	local category = ClubStats.get(view.ClubLabel)
	if category == nil then
		return 1
	end
	return ClubStats.maxDistanceYds(category, statsFor(view.ClubLabel))
end

-- Power (0..1) a perfect strike needs to reach my reticle; nil without a reticle.
local function targetPower(view: any): number?
	local r = if aerial then aerial.reticle() else nil
	if r == nil then
		return nil
	end
	return AimMath.targetPower(r.DistanceYds, maxYdsFor(view))
end

local function currentPower(view: any): number
	local g = gauge
	if stage == "Aim" or g == nil or g.Phase == "Idle" then
		return (targetPower(view) or 1) * 100 -- while aiming: what the target needs
	end
	if g.Phase == "Power" then
		return math.clamp(g.Power, 0, 1) * 100
	end
	return math.clamp(g.LockedPower or g.Power, 0, 1) * 100
end

local function refreshAim(force: boolean)
	local view = myView()
	local built = course
	local visual = aim
	if not armed or view == nil or built == nil or visual == nil then
		return
	end
	local category = ClubStats.get(view.ClubLabel)
	if category == nil then
		return
	end
	local power = math.floor(currentPower(view) + 0.5)
	local key = `{view.ClubLabel}|{myAimDeg or view.AimDeg}|{view.Lie}|{power}|{view.Position.X}|{view.Position.Z}`
	local now = os.clock()
	if not force and (key == aimKey or now - aimRefreshedAt < AIM_REFRESH_SECONDS) then
		return
	end
	aimKey, aimRefreshedAt = key, now
	local guide = AimGuide.compute({
		Terrain = built.Terrain,
		X = view.Position.X,
		Z = view.Position.Z,
		HeadingRad = headingOf(view),
		Slot = category,
		Stats = statsFor(view.ClubLabel),
		Lie = view.Lie,
		Power = power,
	})
	local points: { Vector3 } = {}
	for _, p in guide.Points do
		table.insert(points, built.toWorld(p.X, p.Y, p.Z) + Vector3.new(0, if guide.IsPutt then 0.14 else 0.85, 0))
	end
	local tint = if guide.IsPutt then Color3.fromRGB(255, 255, 255) else Color3.fromRGB(120, 230, 255)
	visual.show(points, guide.IsPutt, tint)
end

-- ---- gauge -------------------------------------------------------------------------------------------

local function greenFor(view: any): number
	local stats = statsFor(view.ClubLabel)
	local penalty = SwingMath.effectivePenalty(view.Lie, stats.Spin)
	return SwingMath.greenHalfWidth(stats.Accuracy, penalty)
end

local function onGauge(g: SwingStateMachine.Gauge)
	gauge = g
	local view = myView()
	if hud == nil or view == nil or stage ~= "Swing" then
		return
	end
	hud.setGauge(GaugeView.layout(g, greenFor(view), targetPower(view)), nil)
	refreshAim(false)
end

-- ---- aiming (stage 1) and swinging (stage 2) -------------------------------------------------------

local function limitsFor(view: any): AerialAim.Limits
	return {
		BallX = view.Position.X,
		BallZ = view.Position.Z,
		PinHeadingRad = pinHeadingOf(view),
		MaxMeters = maxYdsFor(view) * Config.Physics.YardsToMeters,
		MaxAimDeg = Config.Match.MaxAimDegrees,
	}
end

local function aimInfo(view: any): string
	local r = if aerial then aerial.reticle() else nil
	if r == nil then
		return ""
	end
	local power = math.floor((targetPower(view) or 1) * 100 + 0.5)
	local sign = if r.AimDeg > 0.05 then "+" else ""
	return `TARGET {math.floor(r.DistanceYds + 0.5)} YDS  ·  AIM {sign}{string.format("%.1f", r.AimDeg)}°  ·  POWER {power}%\nDrag the target  ·  Space to swing`
end

local function sendAim(force: boolean)
	local deg = myAimDeg
	if deg == nil then
		return
	end
	local now = os.clock()
	if aimSent ~= nil and math.abs(deg - aimSent) < 0.05 then
		return
	end
	if force or now - aimSentAt >= SET_AIM_INTERVAL then
		aimSent, aimSentAt = deg, now
		Remotes.fire("SetAim", deg)
	end
end

-- The reticle moved (drag, key, club change).
local function onReticle(r: AimMath.Reticle, final: boolean)
	if not armed then
		return
	end
	myAimDeg = r.AimDeg
	sendAim(final)
	local view = myView()
	if hud and view and stage == "Aim" then
		hud.setAimStage("Aim", aimInfo(view))
	end
	refreshAim(final)
end

-- (A function, so Luau doesn't narrow the upvalue across callbacks.)
local function isStage(value: Stage): boolean
	return stage == value
end

local function golferCamera(view: any)
	local heading = headingOf(view)
	CameraController.golfer(ballWorld(view), math.cos(heading), math.sin(heading), view.ClubLabel == ClubStats.PUTTER)
end

-- Stage 1: overhead camera + draggable reticle.
local function enterAimStage()
	local view = myView()
	local a = aerial
	if view == nil or a == nil or hud == nil then
		return
	end
	armToken += 1
	if swing then
		swing.disable()
	end
	gauge = nil
	stage = "Aim"
	hud.setGauge(nil, nil)
	if a.reticle() then
		a.setInteractive(true)
	else
		local pin = lastSnapshot.Hole.Pin
		a.begin(limitsFor(view), pin.X, pin.Z) -- starts on the pin (or the club's max distance)
	end
	hud.setAimStage("Aim", aimInfo(view))
	refreshAim(true)
end

-- Stage 2: camera behind the golfer, the timing bar arms after a short beat.
local function enterSwingStage()
	local view = myView()
	if not armed or stage ~= "Aim" or view == nil or hud == nil then
		return
	end
	stage = "Swing"
	if aerial then
		aerial.setInteractive(false)
	end
	sendAim(true)
	hud.setAimStage("Swing", nil)
	placeGolfers(lastSnapshot)
	golferCamera(view)
	armToken += 1
	local token = armToken
	local mode: SwingStateMachine.Mode = if view.ClubLabel == ClubStats.PUTTER then "Putt" else "Full"
	hud.setGauge(GaugeView.layout({ Phase = "Idle", Mode = mode, Power = 0, Needle = 0, LockedPower = nil }, greenFor(view), targetPower(view)), nil)
	-- The delay also stops the Space press that chose SWING from counting as click 1.
	task.delay(ARM_DELAY, function()
		if armToken == token and isStage("Swing") and armed and swing then
			swing.enable(mode)
		end
	end)
	refreshAim(true)
end

-- "◀ AIM" / Tab: only before the power is locked.
local function backToAim()
	if stage ~= "Swing" then
		return
	end
	local g = gauge
	if g and g.Phase ~= "Power" and g.Phase ~= "Idle" then
		return
	end
	enterAimStage()
end

local function arm()
	if armed or swing == nil or hud == nil then
		return
	end
	armed = true
	gauge = nil
	myAimDeg = nil
	aimSent = nil
	enterAimStage()
end

local function disarm()
	armToken += 1
	if swing then
		swing.disable()
	end
	armed = false
	gauge = nil
	stage = nil
	myAimDeg = nil
	limitsKey = ""
	if aerial then
		aerial.hide()
	end
	if hud then
		hud.setGauge(nil, nil)
		hud.setAimStage(nil, nil)
	end
	hideAim()
end

-- ---- holes ----------------------------------------------------------------------------------------------

local function buildHole(snapshot: any)
	if course then
		course.destroy()
	end
	for _, ball in balls do
		ball.destroy()
	end
	balls = {}

	if aerial then
		aerial.destroy()
		aerial = nil
	end

	local built = CourseView.build(snapshot)
	course = built
	local hole = built.Hole
	currentHoleId = hole.Id
	local pickable: { Instance } = { workspace.Terrain }
	for _, instance in built.Include do
		table.insert(pickable, instance)
	end
	aerial = AerialAim.new(built.Folder, {
		toWorld = built.toWorld,
		toCourse = built.toCourse,
		groundAt = built.ground,
		Include = pickable,
	}, onReticle)
	for _, view in snapshot.Players do
		balls[view.Id] = BallAnimator.new(built.Folder, appearanceFor(view.Id), `Ball_{view.Id}`)
	end
	if hud then
		hud.setHole(hole)
	end
	-- The server times the fly-over (Intro phase); nothing waits for it to finish.
	local seconds = if snapshot.Phase == "Intro" then math.max(1, snapshot.IntroSecondsLeft or Config.Match.HoleIntroSeconds) else 1.5
	CameraController.intro(built.Tee, built.Pin, seconds, nil)
end

-- ---- podium -----------------------------------------------------------------------------------------------

local function showPodium(snapshot: any)
	disarm()
	for _, ball in balls do
		ball.setVisible(false)
	end
	local view = PodiumView.build(snapshot, myId)
	if podium then
		podium.destroy()
	end
	local emotes: { [string]: string } = {}
	for id, equipped in cosmeticsById do
		local look = CosmeticsData.animation(equipped.Emote)
		if look.AnimationId ~= "" then
			emotes[id] = look.AnimationId
		end
	end
	local base = if course then course.Origin else Vector3.new(30000, 0, 0)
	local built = PodiumStage.build(view, base + Vector3.new(0, PODIUM_HEIGHT, 0), emotes)
	podium = built
	CameraController.static(built.CameraPosition, built.CameraLook, 55)
	local function show()
		local profile = ClientState.get()
		local delta = if profile then profile.Coins - coinsAtStart else 0
		if hud then
			hud.showSummary(MatchView.summary(snapshot, myId), view, if delta > 0 then `+{Format.commas(delta)} COINS` else nil)
		end
	end
	show()
	-- The payout reaches the profile just after the final state: refresh the text once.
	task.delay(1.5, function()
		if active and hud then
			show()
		end
	end)
end

-- ---- applying a snapshot ----------------------------------------------------------------------------------

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
		return -- text is fresh; balls, golfers, camera and gauge wait for the animation
	end

	local built = course :: CourseView.View
	built.refresh() -- Smooth Terrain may have finished streaming in since last time
	local dots: { MatchHud.Dot } = {}
	for _, view in snapshot.Players do
		local ball = balls[view.Id]
		if ball then
			ball.placeAt(ballWorld(view))
			ball.setVisible(not view.Holed)
		end
		table.insert(dots, { X = view.Position.X, Z = view.Position.Z, IsMe = view.Id == myId, Holed = view.Holed })
	end
	hud.setDots(dots)

	if snapshot.Finished then
		if not summaryShown then
			summaryShown = true
			showPodium(snapshot)
		end
		return
	end

	placeGolfers(snapshot)
	if snapshot.Phase == "Swing" then
		local shooter = viewOf(snapshot.ActiveId)
		if model.IsMyTurn and localSwing == nil and shooter then
			if not armed then
				arm()
			else
				-- Club / lie changed: re-clamp the reticle to the new club's reach.
				local key = `{shooter.ClubLabel}|{shooter.Lie}|{shooter.Position.X}|{shooter.Position.Z}`
				if key ~= limitsKey and aerial then
					limitsKey = key
					aerial.setLimits(limitsFor(shooter))
				end
				if stage == "Aim" and hud then
					hud.setAimStage("Aim", aimInfo(shooter))
				end
			end
			if stage == "Swing" then
				golferCamera(shooter)
			end
			refreshAim(true)
		else
			if armed then
				disarm()
			end
			if shooter then
				golferCamera(shooter)
			end
		end
	elseif armed then
		disarm()
	end
end

-- ---- shots ---------------------------------------------------------------------------------------------------

local playNext: () -> ()

local function finishShot()
	task.delay(2.2, function()
		if not active then
			return
		end
		animating = false
		if hud then
			hud.hideTelemetry()
		end
		if #shotQueue > 0 then
			playNext()
		else
			MatchController.apply(lastSnapshot)
		end
	end)
end

-- Ball flight + camera + telemetry, starting at the club's impact.
local function launch(shot: any)
	local built = course
	local ball = balls[shot.PlayerId]
	if built == nil or ball == nil or hud == nil then
		animating = false
		return
	end
	if shot.Quality then
		local quality = string.upper(shot.Quality)
		local color = if quality == "PERFECT" then Theme.Colors.Good elseif quality == "GOOD" then Theme.Colors.Gold else Theme.Colors.Poor
		hud.feedback(if shot.Auto then "TIME OUT" else (if quality == "PERFECT" then "PERFECT!" else quality), color)
	end
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
	ball.setVisible(true)
	CameraController.follow(built.ground(startX, startZ), aimX, aimZ, function(): Vector3?
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
				CosmeticBuilder.holeEffect(built.Pin, CosmeticsData.holeEffect(equippedOf(shot.PlayerId).HoleEffect))
				hud.feedback(string.upper(Format.scoreName(shot.Stroke, par)), Theme.Colors.Gold)
			elseif shot.Penalty then
				local last = shot.Samples[#shot.Samples]
				BallAnimator.burst(built.ground(last[2], last[4]), Theme.Colors.Blue, 50)
				hud.feedback("PENALTY STROKE", Theme.Colors.Poor)
			end
		end
		finishShot()
	end)
end

playNext = function()
	local shot = table.remove(shotQueue, 1)
	if shot == nil or not active or course == nil then
		animating = false
		return
	end
	animating = true
	disarm()
	local built = course :: CourseView.View
	local isPutt = shot.ClubLabel == ClubStats.PUTTER
	local startWorld = built.ground(shot.Start.X, shot.Start.Z)
	local ball = balls[shot.PlayerId]
	if ball then
		ball.placeAt(startWorld)
		ball.setVisible(true)
	end

	-- My own swing may already be under way (it starts on the third click).
	local mine = localSwing
	if shot.PlayerId == myId and mine and not mine.Consumed then
		mine.Consumed = true
		localSwing = nil
		if mine.ImpactReached then
			launch(shot)
		else
			mine.Launch = function()
				launch(shot)
			end
		end
		return
	end

	-- Everyone else: address the ball, swing, launch on impact.
	local view = viewOf(shot.PlayerId)
	local rig = if view then rigFor(view) else nil
	local dx, dz = shot.End.X - shot.Start.X, shot.End.Z - shot.Start.Z
	local heading = math.atan2(dz, dx)
	if math.abs(dx) + math.abs(dz) < 1e-6 and view then
		heading = headingOf(view)
	end
	local dir = Vector3.new(math.cos(heading), 0, math.sin(heading))
	CameraController.golfer(startWorld, dir.X, dir.Z, isPutt)
	local launched = false
	local function go()
		if not launched then
			launched = true
			launch(shot)
		end
	end
	if rig and view then
		dressClub(rig, view, shot.ClubLabel)
		if weControl(view) then
			rig.address(startWorld, dir, isPutt)
		end
		local kind: SwingPose.Kind = if isPutt then "Putt" else "Swing"
		rig.play(kind, shot.Power, go, animationFor(view.Id, kind))
	end
	-- Safety net: the ball always launches, rig or no rig.
	task.delay((shot.ImpactDelay or Config.Match.SwingLeadSeconds) + 0.6, go)
end

local function onShot(shot: any)
	if not active or course == nil then
		return
	end
	table.insert(shotQueue, shot)
	if not animating then
		playNext()
	end
end

-- Second click: start my swing right away, send the swing, launch on impact.
local function onSubmit(power: number, offset: number)
	sendAim(true) -- the server must have my final aim before the swing
	Remotes.fire("SubmitSwing", power, offset)
	local view = myView()
	local rig = if view then rigFor(view) else nil
	local swingState: LocalSwing = { ImpactReached = false, Launch = nil, Consumed = false }
	localSwing = swingState
	disarm()
	local function impact()
		swingState.ImpactReached = true
		local go = swingState.Launch
		if go then
			swingState.Launch = nil
			go()
		end
	end
	if rig and view then
		local kind: SwingPose.Kind = if view.ClubLabel == ClubStats.PUTTER then "Putt" else "Swing"
		rig.play(kind, power, impact, animationFor(myId, kind))
	else
		task.delay(Config.Match.SwingLeadSeconds, impact)
	end
	-- Rejected swing (no ShotResult comes): give the turn back after a moment.
	task.delay(3, function()
		if localSwing == swingState and not swingState.Consumed then
			localSwing = nil
			if rig then
				rig.stop()
			end
			MatchController.apply(lastSnapshot)
		end
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
	summaryShown = false
	localSwing = nil
	shotQueue = {}
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
	for _, rig in rigs do
		rig.destroy() -- bots are deleted; avatars just lose their club and pose
	end
	rigs = {}
	if aim then
		aim.destroy()
		aim = nil
	end
	if aerial then
		aerial.destroy()
		aerial = nil
	end
	stage, myAimDeg = nil, nil
	if podium then
		podium.destroy()
		podium = nil
	end
	if course then
		course.destroy()
		course = nil
	end
	if matchFolder then
		matchFolder:Destroy()
		matchFolder = nil
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

local function selectClub(label: string)
	local view = myView()
	if view == nil or not armed then
		return
	end
	if view.Lie == "Green" and label ~= ClubStats.PUTTER then
		return -- the putter is locked in on the green
	end
	Remotes.fire("SelectClub", label)
end

local function stepClub(delta: number)
	local view = myView()
	if view == nil then
		return
	end
	local labels = ClubDatabase.BagSlots
	local index = 1
	for i, slot in labels do
		if slot.Label == view.ClubLabel then
			index = i
		end
	end
	selectClub(labels[(index - 1 + delta) % #labels + 1].Label)
end

-- ◀ ▶ buttons / arrow keys: rotate the reticle (works in both stages).
local function stepAim(delta: number)
	local a = aerial
	if not armed or a == nil then
		return
	end
	local g = gauge
	if stage == "Swing" and g and g.Phase ~= "Power" and g.Phase ~= "Idle" then
		return -- power locked: the aim is final
	end
	a.nudge(delta, 0)
	if stage == "Swing" then
		local view = myView()
		if view then
			placeGolfers(lastSnapshot)
			golferCamera(view)
		end
	end
end

local function enter(snapshot: any)
	active = true
	summaryShown = false
	shotQueue = {}
	localSwing = nil
	myId = tostring(localPlayer.UserId)
	local profile = ClientState.get()
	coinsAtStart = if profile then profile.Coins else 0
	cosmeticsById = {}
	for _, view in snapshot.Players do
		cosmeticsById[view.Id] = view.Cosmetics
	end
	-- My own cosmetics come from my profile (always complete).
	if profile then
		cosmeticsById[myId] = profile.EquippedItems
	end

	local folder = Instance.new("Folder")
	folder.Name = "GolfRivalsMatch"
	folder.Parent = workspace
	matchFolder = folder
	aim = AimVisual.new(folder)

	Bus.MatchEntered.fire()
	local newHud = MatchHud.new()
	hud = newHud
	swing = SwingController.new(onGauge, onSubmit)
	freezeCharacter(true)

	newHud.onClubPick.connect(function(label: any)
		selectClub(tostring(label))
	end)
	newHud.onClubStep.connect(stepClub)
	newHud.onAimStep.connect(stepAim)
	newHud.onClubAuto.connect(function()
		local view = myView()
		if view then
			selectClub(ClubAdvisor.recommendClub(view.YardsToPin, view.Lie, statsFor))
		end
	end)
	newHud.onConfirmAim.connect(enterSwingStage)
	newHud.onBackToAim.connect(backToAim)
	newHud.onForfeit.connect(function()
		Remotes.invoke("LeaveMatch")
	end)
	newHud.onLeave.connect(exitMatch)

	-- Keyboard: Q / E club, Space = SWING (aim stage), Tab = switch stage, arrows aim.
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
			elseif input.KeyCode == Enum.KeyCode.Space and isStage("Aim") then
				enterSwingStage()
			elseif input.KeyCode == Enum.KeyCode.Tab then
				if isStage("Aim") then
					enterSwingStage()
				else
					backToAim()
				end
			elseif isStage("Swing") and input.KeyCode == Enum.KeyCode.Left then
				stepAim(-1) -- (AerialAim handles the arrows while aiming)
			elseif isStage("Swing") and input.KeyCode == Enum.KeyCode.Right then
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
			if snapshot.Finished then
				return -- a late final state for a match we already left
			end
			enter(snapshot)
		end
		MatchController.apply(snapshot)
	end)
	Remotes.onClientEvent("ShotResult", onShot)
end

return MatchController
