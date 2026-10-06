--!strict
--[[
	MatchEngine.luau  (ServerScriptService.GolfRivals.Server)

	The rules of a stroke-play match as a pure state machine. No Roblox APIs, no
	clock of its own (every call is given `now`), no hidden randomness (a seed
	picks wind and the opening tee), so a whole match is replayable in tests.

	FLOW
	  Intro phase  : every hole opens with HoleIntroSeconds of fly-over. Nobody may
	                 swing (bots included) and no turn clock runs, so a bot can never
	                 shoot while the players are still watching the hole preview.
	  Swing phase  : exactly one player (the "active" player) may swing. The
	                 server timestamps when the turn opened; a swing faster than a
	                 human could click is rejected (SwingMath.validateSubmission).
	  Flight phase : the shot is resolved at once on the server; the engine then
	                 waits SwingLeadSeconds (the golfer's swing animation up to the
	                 club's impact frame) + ball flight + FlightPadSeconds so clients
	                 can play swing -> impact -> flight, then opens the next turn.
	  Finished     : someone won, drew, or the others forfeited.

	RULES
	  * Turn order is "away plays first": among players still on the hole, the one
	    whose ball is FARTHEST from the pin shoots (ties -> the honour order).
	    Honour: coin toss on hole 1, then the lower score on the previous hole.
	  * Water or out of bounds: +PenaltyStrokes and the ball is replayed from the
	    same spot (stroke and distance).
	  * A ball resting on the green within GimmeMeters of the pin is holed and
	    costs one more stroke.
	  * A hole ends for a player at par + MaxStrokesOverPar (pick-up).
	  * Fewest total strokes wins; equal totals draw. A forfeiting player loses.
	  * On the green the putter is selected automatically and is the only club.
	  * Timeouts: a swing not completed within TurnSeconds is played as a
	    deliberately poor automatic shot; MaxTimeouts of them forfeit the match.

	ALL POSITIONS are in the hole frame (metres). Shots are simulated in their
	own aim-aligned frame (see CourseTerrain) and converted back.

	USAGE
	  local engine = MatchEngine.new({ Players = ..., Holes = ..., Seed = ..., Now = ... })
	  engine.submitSwing(playerId, power, offset, now)   -- human
	  engine.submitBotSwing(playerId, label, aim, power, offset, now)  -- bot (no timing check)
	  engine.tick(now)                                   -- call ~every 0.25 s
	  engine.drainEvents()                               -- what to broadcast
	  engine.snapshot(now)                               -- full state for clients
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage") -- OFFLINE-STRIP
local Shared = ReplicatedStorage.GolfRivals.Shared -- OFFLINE-STRIP
local Types = require(Shared.Types)
local Config = require(Shared.Config)
local ClubAdvisor = require(Shared.ClubAdvisor)
local ClubDatabase = require(Shared.ClubDatabase)
local ClubStats = require(Shared.ClubStats)
local CourseDatabase = require(Shared.CourseDatabase)
local CourseTerrain = require(Shared.CourseTerrain)
local Prng = require(Shared.Prng)
local ShotPhysics = require(Shared.ShotPhysics)
local SwingMath = require(Shared.SwingMath)
local Validate = require(Shared.Validate)

local M = Config.Match
local YD = Config.Physics.YardsToMeters

export type PlayerSpec = {
	Id: string,
	Name: string,
	IsBot: boolean,
	-- Effective (upgrade-adjusted) stats for the club in a bag slot label. For
	-- humans this is frozen at match start so mid-match upgrades can't change it.
	StatsFor: (label: string) -> ClubDatabase.Stats,
	Cosmetics: { [string]: string }?, -- equipped items, passed through to clients
}

export type EngineConfig = {
	Players: { PlayerSpec },
	Holes: { CourseDatabase.HoleDef },
	Seed: number,
	Now: number,
	IntroSeconds: number?, -- per-hole fly-over (default Config.Match.HoleIntroSeconds; 0 = none)
	SwingLeadSeconds: number?, -- swing animation lead before impact (default Config.Match.SwingLeadSeconds)
}

export type Phase = "Intro" | "Swing" | "Flight" | "Finished"

export type Event = { Type: string, Data: { [string]: any } }

export type Situation = {
	Position: CourseDatabase.Point,
	DistanceYds: number,
	PinHeadingDeg: number,
	Lie: Types.LieId,
	WindMph: number,
	WindDirDeg: number,
	Par: number,
	Strokes: number,
}

export type MatchResult = {
	Finished: boolean,
	WinnerId: string?,
	Draw: boolean,
	Reason: string, -- "complete" | "forfeit" | "abandoned"
	Totals: { [string]: number },
	HoleScores: { [string]: { number } },
	ForfeitedIds: { string },
}

export type Engine = {
	snapshot: (now: number) -> { [string]: any },
	situation: (playerId: string) -> Situation?,
	preview: (playerId: string, label: string, aimOffsetDeg: number, power: number, offset: number, windScale: number) -> SwingMath.ResolvedShot?,
	-- Where a previewed shot would end: (lie, inBounds). For bot planning.
	landing: (playerId: string, aimOffsetDeg: number, result: ShotPhysics.ShotResult) -> (Types.LieId, boolean),
	setClub: (playerId: string, label: any) -> (boolean, string?),
	setAim: (playerId: string, aimDeg: any) -> (boolean, string?),
	submitSwing: (playerId: string, power: any, offset: any, now: number) -> (boolean, string?),
	submitBotSwing: (playerId: string, label: string, aimOffsetDeg: number, power: number, offset: number, now: number) -> (boolean, string?),
	tick: (now: number) -> (),
	forfeit: (playerId: string, now: number) -> (),
	drainEvents: () -> { Event },
	isFinished: () -> boolean,
	phase: () -> Phase,
	activeId: () -> string?,
	result: () -> MatchResult,
}

local MatchEngine = {}

-- Club advice lives in Shared/ClubAdvisor (the client's club picker uses it too).
MatchEngine.ClubsByReach = ClubAdvisor.ClubsByReach
MatchEngine.estimateCarry = ClubAdvisor.estimateCarry
MatchEngine.recommendClub = ClubAdvisor.recommendClub

-- ---------------------------------------------------------------------------
-- Engine
-- ---------------------------------------------------------------------------

type PlayerState = {
	Spec: PlayerSpec,
	X: number,
	Z: number,
	Lie: Types.LieId,
	Strokes: number, -- this hole, including penalties
	Holed: boolean,
	ClubLabel: string,
	AimDeg: number, -- offset from the pin line
	HoleScores: { number },
	Total: number,
	Timeouts: number,
	Forfeited: boolean,
}

local function distance(ax: number, az: number, bx: number, bz: number): number
	local dx, dz = bx - ax, bz - az
	return math.sqrt(dx * dx + dz * dz)
end

function MatchEngine.new(config: EngineConfig): Engine
	assert(#config.Players >= 2, "a match needs at least two players")
	assert(#config.Holes >= 1, "a match needs at least one hole")

	local players: { PlayerState } = {}
	local byId: { [string]: PlayerState } = {}
	for _, spec in config.Players do
		local ps: PlayerState = {
			Spec = spec, X = 0, Z = 0, Lie = "Tee", Strokes = 0, Holed = false,
			ClubLabel = ClubStats.DRIVER, AimDeg = 0, HoleScores = {}, Total = 0, Timeouts = 0, Forfeited = false,
		}
		table.insert(players, ps)
		byId[spec.Id] = ps
	end

	local seedPrng = Prng.new(config.Seed)
	local order: { PlayerState } = table.clone(players) -- honour order (first = tees off first)
	if seedPrng.next() < 0.5 then
		order[1], order[2] = order[2], order[1] -- opening coin toss
	end

	local holeIndex = 0
	local hole: CourseDatabase.HoleDef = config.Holes[1]
	local terrain: ShotPhysics.Terrain = CourseTerrain.forHole(hole)
	local windMph, windDirDeg = 0.0, 0.0
	local phase: Phase = "Swing"
	local active: PlayerState = players[1]
	local turnStartedAt, turnDeadline, flightUntil, introUntil = config.Now, config.Now, config.Now, config.Now
	local introSeconds = config.IntroSeconds or M.HoleIntroSeconds
	local swingLead = config.SwingLeadSeconds or M.SwingLeadSeconds
	local events: { Event } = {}
	local finished = false
	local resultCache: MatchResult? = nil
	local reason = "complete"

	local function push(eventType: string, data: { [string]: any })
		table.insert(events, { Type = eventType, Data = data })
	end

	local function statsFor(ps: PlayerState, label: string): ClubDatabase.Stats
		return ps.Spec.StatsFor(label)
	end

	local function pinDistanceYds(ps: PlayerState): number
		return distance(ps.X, ps.Z, hole.Pin.X, hole.Pin.Z) / YD
	end

	local function pinHeadingDeg(ps: PlayerState): number
		return math.deg(math.atan2(hole.Pin.Z - ps.Z, hole.Pin.X - ps.X))
	end

	local function livePlayers(): { PlayerState }
		local list: { PlayerState } = {}
		for _, ps in players do
			if not ps.Forfeited then
				table.insert(list, ps)
			end
		end
		return list
	end

	-- ---- result ----------------------------------------------------------
	local function buildResult(): MatchResult
		local totals: { [string]: number } = {}
		local scores: { [string]: { number } } = {}
		local forfeited: { string } = {}
		for _, ps in players do
			totals[ps.Spec.Id] = ps.Total
			scores[ps.Spec.Id] = table.clone(ps.HoleScores)
			if ps.Forfeited then
				table.insert(forfeited, ps.Spec.Id)
			end
		end
		local contenders = livePlayers()
		local winnerId: string? = nil
		local draw = false
		if #contenders == 0 then
			reason = "abandoned"
		elseif #contenders == 1 then
			winnerId = contenders[1].Spec.Id
			reason = "forfeit"
		else
			local best = math.huge
			for _, ps in contenders do
				best = math.min(best, ps.Total)
			end
			local leaders: { PlayerState } = {}
			for _, ps in contenders do
				if ps.Total == best then
					table.insert(leaders, ps)
				end
			end
			if #leaders == 1 then
				winnerId = leaders[1].Spec.Id
			else
				draw = true
			end
		end
		return {
			Finished = finished, WinnerId = winnerId, Draw = draw, Reason = reason,
			Totals = totals, HoleScores = scores, ForfeitedIds = forfeited,
		}
	end

	local function finishMatch()
		if finished then
			return
		end
		finished = true
		phase = "Finished"
		resultCache = buildResult()
		push("MatchComplete", { Result = resultCache })
	end

	-- ---- turn management -------------------------------------------------
	local function beginTurn(ps: PlayerState, now: number)
		active = ps
		phase = "Swing"
		turnStartedAt = now
		turnDeadline = now + M.TurnSeconds
		-- Default club for this turn; the player may change it with setClub.
		ps.ClubLabel = MatchEngine.recommendClub(pinDistanceYds(ps), ps.Lie, function(label: string): ClubDatabase.Stats
			return statsFor(ps, label)
		end)
		ps.AimDeg = 0
		push("TurnStart", { PlayerId = ps.Spec.Id, ClubLabel = ps.ClubLabel })
	end

	-- Farthest ball from the pin plays; ties go to the honour order.
	local function chooseNext(): PlayerState?
		local best: PlayerState? = nil
		local bestDistance = -1.0
		for _, ps in order do
			if not ps.Holed and not ps.Forfeited then
				local d = pinDistanceYds(ps)
				if d > bestDistance + 1e-9 then
					best, bestDistance = ps, d
				end
			end
		end
		return best
	end

	local function startHole(index: number, now: number)
		holeIndex = index
		hole = config.Holes[index]
		terrain = CourseTerrain.forHole(hole)
		local wind = Prng.new(config.Seed * 31 + index * 17 + 5)
		windMph = wind.next() * M.MaxWindMph
		windDirDeg = wind.next() * 360
		for _, ps in players do
			ps.X, ps.Z, ps.Lie, ps.Strokes, ps.Holed = hole.Tee.X, hole.Tee.Z, "Tee", 0, false
		end
		push("HoleStart", { HoleIndex = index, Par = hole.Par, Wind = { Mph = windMph, DirDeg = windDirDeg }, IntroSeconds = introSeconds })
		local first = chooseNext()
		if first == nil then
			return
		end
		if introSeconds > 0 then
			-- Fly-over: show who tees off first, but nobody may swing yet.
			phase = "Intro"
			active = first
			introUntil = now + introSeconds
		else
			beginTurn(first, now)
		end
	end

	local function finishHole(now: number)
		for _, ps in players do
			if not ps.Forfeited then
				table.insert(ps.HoleScores, ps.Strokes)
				ps.Total += ps.Strokes
			end
		end
		push("HoleComplete", { HoleIndex = holeIndex })
		if holeIndex >= #config.Holes then
			finishMatch()
			return
		end
		-- Honour for the next tee: lower score on this hole goes first; ties keep order.
		local ranked = table.clone(order)
		table.sort(ranked, function(a: PlayerState, b: PlayerState)
			if a.Strokes ~= b.Strokes then
				return a.Strokes < b.Strokes
			end
			local indexA = table.find(order, a) or 0
			local indexB = table.find(order, b) or 0
			return indexA < indexB
		end)
		order = ranked
		startHole(holeIndex + 1, now)
	end

	-- After the flight pause: next player, or the next hole, or the end.
	local function advance(now: number)
		local pending = false
		for _, ps in players do
			if not ps.Holed and not ps.Forfeited then
				pending = true
			end
		end
		if not pending then
			finishHole(now)
			return
		end
		local nextPlayer = chooseNext()
		if nextPlayer then
			beginTurn(nextPlayer, now)
		end
	end

	-- ---- shooting --------------------------------------------------------
	local function clampAim(aimDeg: number): number
		return math.clamp(aimDeg, -M.MaxAimDegrees, M.MaxAimDegrees)
	end

	local function shotSetup(ps: PlayerState, aimOffsetDeg: number, windScale: number): (number, ShotPhysics.Terrain, ShotPhysics.Wind, ShotPhysics.Cup, number)
		local headingDeg = pinHeadingDeg(ps) + clampAim(aimOffsetDeg)
		local headingRad = math.rad(headingDeg)
		local frame = CourseTerrain.shotFrame(terrain, ps.X, ps.Z, headingRad)
		local wind = SwingMath.windToLocal(windMph * windScale, windDirDeg, headingDeg)
		local cupX, cupZ = CourseTerrain.toShot(ps.X, ps.Z, headingRad, hole.Pin.X, hole.Pin.Z)
		return headingRad, frame, wind, { X = cupX, Z = cupZ }, headingDeg
	end

	local function resolve(ps: PlayerState, label: string, aimOffsetDeg: number, power: number, offset: number, windScale: number): (SwingMath.ResolvedShot, number)
		local slot = ClubDatabase.getSlot(label) :: ClubDatabase.BagSlot
		local headingRad, frame, wind, cup = shotSetup(ps, aimOffsetDeg, windScale)
		local shot = SwingMath.resolveShot({
			Slot = slot,
			Stats = statsFor(ps, label),
			Power = power,
			AccuracyOffset = offset,
			Lie = ps.Lie,
			Wind = wind,
		}, frame, cup)
		return shot, headingRad
	end

	-- Plays one shot for the active player and updates all state.
	local function playShot(ps: PlayerState, label: string, aimOffsetDeg: number, power: number, offset: number, now: number, auto: boolean)
		local startX, startZ, startLie = ps.X, ps.Z, ps.Lie
		local shot, headingRad = resolve(ps, label, aimOffsetDeg, power, offset, 1)
		local result = shot.Result

		local endX, endZ = CourseTerrain.toHole(startX, startZ, headingRad, result.FinalX, result.FinalZ)
		ps.Strokes += 1
		local penalty = false
		local holed = false

		if result.Outcome == "Holed" then
			holed = true
			ps.X, ps.Z = hole.Pin.X, hole.Pin.Z
		elseif result.Outcome == "Water" or not CourseTerrain.inBounds(hole, endX, endZ) then
			-- Hazard / out of bounds: penalty stroke, replay from the same spot.
			penalty = true
			ps.Strokes += M.PenaltyStrokes
		else
			ps.X, ps.Z = endX, endZ
			ps.Lie = CourseTerrain.lieAt(hole, endX, endZ)
			if ps.Lie == "Green" and distance(endX, endZ, hole.Pin.X, hole.Pin.Z) <= M.GimmeMeters then
				ps.Strokes += 1 -- the tap-in
				ps.X, ps.Z = hole.Pin.X, hole.Pin.Z
				holed = true
			end
		end

		local cap = hole.Par + M.MaxStrokesOverPar
		local pickedUp = false
		if not holed and ps.Strokes >= cap then
			ps.Strokes = cap
			holed = true
			pickedUp = true
		end
		ps.Holed = holed

		-- Trajectory in the hole frame for the client's ball animation.
		local samples: { { number } } = {}
		for _, s in result.Samples do
			local wx, wz = CourseTerrain.toHole(startX, startZ, headingRad, s.X, s.Z)
			table.insert(samples, { s.T, wx, s.Y, wz })
		end

		phase = "Flight"
		flightUntil = now + swingLead + result.TotalSeconds + M.FlightPadSeconds
		push("Shot", {
			PlayerId = ps.Spec.Id,
			HoleIndex = holeIndex,
			Stroke = ps.Strokes,
			ClubLabel = label,
			Power = power, -- lets every client size the golfer's backswing
			Auto = auto,
			Quality = shot.Quality,
			StartLie = startLie,
			Start = { X = startX, Z = startZ },
			End = { X = ps.X, Z = ps.Z },
			EndLie = ps.Lie,
			Outcome = result.Outcome,
			Penalty = penalty,
			Holed = holed,
			PickedUp = pickedUp,
			HoleInOne = holed and not pickedUp and ps.Strokes == 1,
			Telemetry = {
				CarryYds = result.CarryYds, TotalYds = result.TotalYds, RollYds = result.RollYds,
				ApexFeet = result.ApexFeet, SpinRpm = result.SpinRpm, BallSpeedMph = result.BallSpeedMph,
				LateralYds = result.LateralYds,
			},
			Samples = samples, -- { t, x, y, z } in the hole frame (t = 0 at club impact)
			ImpactDelay = swingLead, -- seconds of swing animation before the ball leaves the club
			AirSeconds = result.FlightSeconds, -- time until first touchdown (carry ends here)
			TotalSeconds = result.TotalSeconds, -- until the ball stops
		})
	end

	-- ---- public API ------------------------------------------------------
	local function snapshot(now: number): { [string]: any }
		local views: { any } = {}
		for _, ps in players do
			table.insert(views, {
				Id = ps.Spec.Id,
				Name = ps.Spec.Name,
				IsBot = ps.Spec.IsBot,
				Position = { X = ps.X, Z = ps.Z },
				YardsToPin = pinDistanceYds(ps),
				Lie = ps.Lie,
				Strokes = ps.Strokes,
				Holed = ps.Holed,
				Total = ps.Total,
				HoleScores = table.clone(ps.HoleScores),
				ClubLabel = ps.ClubLabel,
				AimDeg = ps.AimDeg,
				Forfeited = ps.Forfeited,
				Cosmetics = ps.Spec.Cosmetics,
			})
		end
		return {
			Phase = phase,
			HoleIndex = holeIndex,
			HoleCount = #config.Holes,
			Hole = {
				Id = hole.Id, Name = hole.Name, Par = hole.Par, Yards = CourseDatabase.yards(hole),
				Tee = hole.Tee, Pin = hole.Pin,
			},
			Wind = { Mph = windMph, DirDeg = windDirDeg },
			ActiveId = if phase == "Finished" then nil else active.Spec.Id,
			TurnSecondsLeft = if phase == "Swing" then math.max(0, turnDeadline - now) else 0,
			IntroSecondsLeft = if phase == "Intro" then math.max(0, introUntil - now) else 0,
			Players = views,
			Finished = finished,
			Result = if finished then buildResult() else nil,
		}
	end

	local function situation(playerId: string): Situation?
		local ps = byId[playerId]
		if ps == nil then
			return nil
		end
		return {
			Position = { X = ps.X, Z = ps.Z },
			DistanceYds = pinDistanceYds(ps),
			PinHeadingDeg = pinHeadingDeg(ps),
			Lie = ps.Lie,
			WindMph = windMph,
			WindDirDeg = windDirDeg,
			Par = hole.Par,
			Strokes = ps.Strokes,
		}
	end

	-- Dry-run a swing for planning (bots). Changes no state.
	local function preview(playerId: string, label: string, aimOffsetDeg: number, power: number, offset: number, windScale: number): SwingMath.ResolvedShot?
		local ps = byId[playerId]
		if ps == nil or ClubDatabase.getSlot(label) == nil then
			return nil
		end
		local shot = resolve(ps, label, aimOffsetDeg, power, offset, windScale)
		return shot
	end

	local function landing(playerId: string, aimOffsetDeg: number, result: ShotPhysics.ShotResult): (Types.LieId, boolean)
		local ps = byId[playerId]
		if ps == nil then
			return "Rough", false
		end
		local headingRad = math.rad(pinHeadingDeg(ps) + clampAim(aimOffsetDeg))
		local x, z = CourseTerrain.toHole(ps.X, ps.Z, headingRad, result.FinalX, result.FinalZ)
		return CourseTerrain.lieAt(hole, x, z), CourseTerrain.inBounds(hole, x, z)
	end

	local function setClub(playerId: string, label: any): (boolean, string?)
		local ps = byId[playerId]
		if ps == nil then
			return false, "unknown_player"
		end
		if type(label) ~= "string" or ClubDatabase.getSlot(label) == nil then
			return false, "unknown_club_slot"
		end
		-- Auto-putter: on the green the putter is the only club.
		if ps.Lie == "Green" and label ~= ClubStats.PUTTER then
			return false, "putter_only_on_green"
		end
		ps.ClubLabel = label
		return true, nil
	end

	local function setAim(playerId: string, aimDeg: any): (boolean, string?)
		local ps = byId[playerId]
		if ps == nil then
			return false, "unknown_player"
		end
		if not Validate.numberInRange(aimDeg, -M.MaxAimDegrees, M.MaxAimDegrees) then
			return false, "bad_aim"
		end
		ps.AimDeg = aimDeg :: number
		return true, nil
	end

	local function submitSwing(playerId: string, power: any, offset: any, now: number): (boolean, string?)
		local ps = byId[playerId]
		if ps == nil then
			return false, "unknown_player"
		end
		if phase ~= "Swing" or active ~= ps then
			return false, "not_your_turn"
		end
		local ok, why = SwingMath.validateSubmission(power, offset, now - turnStartedAt)
		if not ok then
			return false, why
		end
		playShot(ps, ps.ClubLabel, ps.AimDeg, power :: number, offset :: number, now, false)
		return true, nil
	end

	local function submitBotSwing(playerId: string, label: string, aimOffsetDeg: number, power: number, offset: number, now: number): (boolean, string?)
		local ps = byId[playerId]
		if ps == nil or not ps.Spec.IsBot then
			return false, "not_a_bot"
		end
		if phase ~= "Swing" or active ~= ps then
			return false, "not_your_turn"
		end
		if ClubDatabase.getSlot(label) == nil then
			return false, "unknown_club_slot"
		end
		playShot(ps, label, aimOffsetDeg, math.clamp(power, 0, 100), math.clamp(offset, -1, 1), now, false)
		return true, nil
	end

	local function forfeit(playerId: string, now: number)
		local ps = byId[playerId]
		if ps == nil or ps.Forfeited or finished then
			return
		end
		ps.Forfeited = true
		ps.Holed = true -- off the hole
		push("Forfeit", { PlayerId = playerId })
		if #livePlayers() < 2 then
			finishMatch()
		elseif phase == "Swing" and active == ps then
			advance(now)
		end
	end

	local function tick(now: number)
		if finished then
			return
		end
		if phase == "Intro" then
			if now >= introUntil then
				local first = chooseNext()
				if first then
					beginTurn(first, now)
				end
			end
		elseif phase == "Flight" then
			if now >= flightUntil then
				advance(now)
			end
		elseif phase == "Swing" and now >= turnDeadline then
			local ps = active
			ps.Timeouts += 1
			push("Timeout", { PlayerId = ps.Spec.Id, Count = ps.Timeouts })
			if ps.Timeouts >= M.MaxTimeouts then
				forfeit(ps.Spec.Id, now)
			else
				-- Penalty shot: poor power, clear slice, with the player's current club/aim.
				playShot(ps, ps.ClubLabel, ps.AimDeg, M.AutoShotPower, M.AutoShotOffset, now, true)
			end
		end
	end

	startHole(1, config.Now)

	return {
		snapshot = snapshot,
		situation = situation,
		preview = preview,
		landing = landing,
		setClub = setClub,
		setAim = setAim,
		submitSwing = submitSwing,
		submitBotSwing = submitBotSwing,
		tick = tick,
		forfeit = forfeit,
		drainEvents = function(): { Event }
			local out = events
			events = {}
			return out
		end,
		isFinished = function(): boolean
			return finished
		end,
		phase = function(): Phase
			return phase
		end,
		activeId = function(): string?
			return if phase == "Finished" then nil else active.Spec.Id
		end,
		result = function(): MatchResult
			return resultCache or buildResult()
		end,
	}
end

return MatchEngine
