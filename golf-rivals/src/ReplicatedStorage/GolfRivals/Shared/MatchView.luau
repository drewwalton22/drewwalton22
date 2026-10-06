--!strict
--[[
	MatchView.luau  (ReplicatedStorage.GolfRivals.Shared)

	Everything the in-match HUD shows, derived from the server's MatchState snapshot
	(see MatchEngine.snapshot). Pure: the HUD just binds these values to labels.

	  hud(snapshot, myId, statsFor)  -> HudModel  (hole text, turn banner, timer, wind
	                                   arrow, club options with reach, score rows)
	  summary(snapshot, myId)        -> end-of-match results
	  windRotation(...)              -> arrow angle relative to the aim line

	WIND ARROW  The arrow points where the wind blows TOWARD, drawn relative to the
	aim line (aim = up): 0 deg = tailwind (arrow up), 90 = blowing right, 180 =
	headwind (arrow down). rel = windDir - aimHeading, both in the hole frame.
]]

local Types = require(script.Parent.Types)
local Format = require(script.Parent.Format)
local ClubDatabase = require(script.Parent.ClubDatabase)
local ClubAdvisor = require(script.Parent.ClubAdvisor)

export type ClubOption = {
	Label: string,
	DisplayName: string,
	ReachYds: number,
	Selected: boolean,
	Recommended: boolean,
}

export type Row = {
	Id: string,
	Name: string,
	IsBot: boolean,
	IsMe: boolean,
	IsActive: boolean,
	Holed: boolean,
	Strokes: number, -- this hole
	Total: number, -- completed holes
	YardsToPin: number,
	HoleScores: { number },
	Forfeited: boolean,
}

export type HudModel = {
	HoleText: string, -- "HOLE 1"
	ParText: string, -- "PAR 4"
	YardsText: string, -- "432 YDS"
	ProgressText: string, -- "1 / 3"
	Phase: string,
	IsMyTurn: boolean,
	Banner: string,
	ActiveName: string,
	YardsToPin: number,
	YardsToPinText: string,
	Lie: string,
	WindText: string,
	WindRotationDeg: number,
	TimerSeconds: number,
	TimerText: string,
	Rows: { Row },
	Me: Row?,
	ClubOptions: { ClubOption },
	SelectedLabel: string,
	AimDeg: number,
}

export type Summary = {
	Title: string,
	Won: boolean,
	Draw: boolean,
	Rows: { Row },
	Reason: string,
}

local MatchView = {}

-- Normalise an angle in degrees to (-180, 180].
local function wrap(deg: number): number
	local d = (deg + 180) % 360 - 180
	if d == -180 then
		d = 180
	end
	return d
end

-- Wind arrow angle for a ball at (bx, bz) aiming at the pin with an aim offset.
function MatchView.windRotation(ballX: number, ballZ: number, pinX: number, pinZ: number, aimOffsetDeg: number, windDirDeg: number): number
	local aimHeading = math.deg(math.atan2(pinZ - ballZ, pinX - ballX)) + aimOffsetDeg
	return wrap(windDirDeg - aimHeading)
end

local function toRow(view: any, myId: string, activeId: string?): Row
	return {
		Id = view.Id, Name = view.Name, IsBot = view.IsBot, IsMe = view.Id == myId, IsActive = view.Id == activeId,
		Holed = view.Holed, Strokes = view.Strokes, Total = view.Total, YardsToPin = view.YardsToPin,
		HoleScores = view.HoleScores, Forfeited = view.Forfeited,
	}
end

function MatchView.hud(snapshot: any, myId: string, statsFor: (string) -> ClubDatabase.Stats): HudModel
	local hole = snapshot.Hole
	local rows: { Row } = {}
	local me: Row? = nil
	local myView: any = nil
	for _, view in snapshot.Players do
		local row = toRow(view, myId, snapshot.ActiveId)
		table.insert(rows, row)
		if view.Id == myId then
			me, myView = row, view
		end
	end

	local activeName = ""
	for _, row in rows do
		if row.IsActive then
			activeName = row.Name
		end
	end
	local isMyTurn = snapshot.Phase == "Swing" and snapshot.ActiveId == myId

	local banner: string
	if snapshot.Phase == "Finished" then
		banner = "MATCH COMPLETE"
	elseif snapshot.Phase == "Flight" then
		banner = "BALL IN FLIGHT"
	elseif isMyTurn then
		banner = "YOUR SHOT"
	else
		banner = `{string.upper(activeName)}'S SHOT`
	end

	local lie: Types.LieId = if myView then myView.Lie else "Tee"
	local yardsToPin = if myView then myView.YardsToPin else hole.Yards
	local selected = if myView then myView.ClubLabel else "D"
	local aim = if myView then myView.AimDeg else 0

	local options: { ClubOption } = {}
	local recommended = ClubAdvisor.recommendClub(yardsToPin, lie, statsFor)
	for _, slot in ClubDatabase.BagSlots do
		table.insert(options, {
			Label = slot.Label,
			DisplayName = slot.DisplayName,
			ReachYds = if slot.Class == "Putter" then 0 else ClubAdvisor.estimateCarry(slot, statsFor(slot.Label), lie),
			Selected = slot.Label == selected,
			Recommended = slot.Label == recommended,
		})
	end

	local windRotation = 0.0
	if myView then
		windRotation = MatchView.windRotation(myView.Position.X, myView.Position.Z, hole.Pin.X, hole.Pin.Z, aim, snapshot.Wind.DirDeg)
	end

	return {
		HoleText = `HOLE {snapshot.HoleIndex}`,
		ParText = `PAR {hole.Par}`,
		YardsText = Format.yards(hole.Yards),
		ProgressText = `{snapshot.HoleIndex} / {snapshot.HoleCount}`,
		Phase = snapshot.Phase,
		IsMyTurn = isMyTurn,
		Banner = banner,
		ActiveName = activeName,
		YardsToPin = yardsToPin,
		YardsToPinText = Format.yards(yardsToPin),
		Lie = lie,
		WindText = Format.mph(snapshot.Wind.Mph),
		WindRotationDeg = windRotation,
		TimerSeconds = snapshot.TurnSecondsLeft,
		TimerText = Format.clock(snapshot.TurnSecondsLeft),
		Rows = rows,
		Me = me,
		ClubOptions = options,
		SelectedLabel = selected,
		AimDeg = aim,
	}
end

function MatchView.summary(snapshot: any, myId: string): Summary
	local result = snapshot.Result
	local rows: { Row } = {}
	for _, view in snapshot.Players do
		table.insert(rows, toRow(view, myId, nil))
	end
	table.sort(rows, function(a: Row, b: Row)
		if a.Forfeited ~= b.Forfeited then
			return not a.Forfeited
		end
		return a.Total < b.Total
	end)
	local won = result ~= nil and result.WinnerId == myId
	local draw = result ~= nil and result.Draw
	local title: string
	if draw then
		title = "DRAW"
	elseif won then
		title = "VICTORY"
	else
		title = "DEFEAT"
	end
	return { Title = title, Won = won, Draw = draw, Rows = rows, Reason = if result then result.Reason else "complete" }
end

return MatchView
