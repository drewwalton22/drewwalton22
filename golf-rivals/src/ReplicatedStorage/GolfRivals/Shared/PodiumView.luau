--!strict
--[[
	PodiumView.luau  (ReplicatedStorage.GolfRivals.Shared)

	The post-game showcase: who stands where on the podium and which animation
	each golfer plays, from the final match snapshot. Match/PodiumStage builds the
	stage and the avatars from this; pure, so the rules are tested offline.

	  Winner     -> top step (centre, highest), "Victory" loop
	  Loser      -> second step (to the winner's right as the camera sees it),
	                "Defeat" loop; a player who forfeited is always the loser
	  Draw       -> both on equal steps side by side, "Idle" (a respectful nod)

	Slot offsets are in studs relative to the stage origin, X = sideways as the
	camera looks at the stage, Y = height of the step top.
]]

local Format = require(script.Parent.Format)

export type Outcome = "Winner" | "RunnerUp" | "Draw"
export type Animation = "Victory" | "Defeat" | "Idle"

export type Entry = {
	Id: string,
	Name: string,
	IsBot: boolean,
	IsMe: boolean,
	Place: number, -- 1 or 2 (both 1 on a draw)
	Outcome: Outcome,
	Animation: Animation,
	TotalText: string, -- "11 strokes"
	SlotX: number, -- studs, stage-relative
	StepHeight: number, -- studs
	StepColor: { number },
}

export type Podium = {
	Title: string, -- from MY point of view: "VICTORY" / "DEFEAT" / "DRAW"
	Subtitle: string,
	Entries: { Entry },
}

local PodiumView = {}

PodiumView.GOLD = { 255, 200, 60 }
PodiumView.SILVER = { 180, 190, 205 }
PodiumView.BLUE = { 90, 150, 255 }

function PodiumView.build(snapshot: any, myId: string): Podium
	local result = snapshot.Result or {}
	local draw = result.Draw == true
	local winnerId: string? = result.WinnerId

	local views: { any } = {}
	for _, view in snapshot.Players do
		table.insert(views, view)
	end
	-- Winner first; then by total strokes (forfeits last).
	table.sort(views, function(a: any, b: any): boolean
		if (a.Id == winnerId) ~= (b.Id == winnerId) then
			return a.Id == winnerId
		end
		if (a.Forfeited == true) ~= (b.Forfeited == true) then
			return not a.Forfeited
		end
		if a.Total ~= b.Total then
			return a.Total < b.Total
		end
		return tostring(a.Id) < tostring(b.Id)
	end)

	local entries: { Entry } = {}
	for index, view in views do
		local outcome: Outcome
		local animation: Animation
		local place: number
		local slotX: number
		local height: number
		local color: { number }
		if draw then
			outcome, animation, place = "Draw", "Idle", 1
			slotX = if index == 1 then -3.5 else 3.5
			height, color = 3, PodiumView.BLUE
		elseif index == 1 then
			outcome, animation, place = "Winner", "Victory", 1
			slotX, height, color = 0, 4, PodiumView.GOLD
		else
			outcome, animation, place = "RunnerUp", "Defeat", 2
			slotX, height, color = 7, 2, PodiumView.SILVER
		end
		local strokes = if view.Forfeited then "forfeited" else `{view.Total} strokes`
		table.insert(entries, {
			Id = view.Id,
			Name = view.Name,
			IsBot = view.IsBot == true,
			IsMe = view.Id == myId,
			Place = place,
			Outcome = outcome,
			Animation = animation,
			TotalText = strokes,
			SlotX = slotX,
			StepHeight = height,
			StepColor = color,
		})
	end

	local title: string
	if draw then
		title = "DRAW"
	elseif winnerId == myId then
		title = "VICTORY"
	else
		title = "DEFEAT"
	end
	local winnerName = if entries[1] then entries[1].Name else ""
	local subtitle = if draw then "All square after " .. Format.commas(snapshot.HoleCount or 0) .. " holes" else `{winnerName} wins the match`
	if result.Reason == "forfeit" and not draw then
		subtitle = `{winnerName} wins by forfeit`
	end
	return { Title = title, Subtitle = subtitle, Entries = entries }
end

return PodiumView
