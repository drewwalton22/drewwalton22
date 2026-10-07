--!strict
--[[
	GaugeView.luau  (ReplicatedStorage.GolfRivals.Shared)

	Maps the 2-stage timing bar (SwingStateMachine) onto two horizontal tracks so
	the UI only places a few frames. Every value is 0..1 across its track.

	    POWER     |██████████████▌               |  fill = live / locked power
	                               ^ target tick (from the aim reticle, optional)
	    ACCURACY  |      ░░░[SWEET]░░░           |  needle swings back and forth
	              -1 (early/slice)  0   +1 (late/hook)

	  needleX     = (offset + 1) / 2            (offset -1..1 -> 0..1)
	  sweet spot  = needleX of +/- greenHalfWidth  (the "Perfect" zone, no curve)
	  good band   = needleX of +/- GoodHalfWidth   (small curve)
]]

local Config = require(script.Parent.Config)
local SwingStateMachine = require(script.Parent.SwingStateMachine)

export type Layout = {
	Phase: SwingStateMachine.Phase,
	Mode: SwingStateMachine.Mode,
	PowerFill: number, -- 0..1
	PowerPercent: number, -- 0..100 (what click 1 would lock now, or did lock)
	Locked: boolean, -- power stage finished
	NeedleX: number?, -- 0..1 across the accuracy track (nil before stage 2)
	SweetLeft: number,
	SweetRight: number,
	GoodLeft: number,
	GoodRight: number,
	TargetPower: number?, -- 0..1 power the aim reticle asks for (optional tick)
	TimeLeft: number?, -- seconds before stage 2 times out (nil outside stage 2)
	TimeFraction: number?, -- TimeLeft / AccuracyTimeoutSeconds (countdown ring)
}

local GaugeView = {}

-- Accuracy offset (-1..1) -> position on the accuracy track (0..1).
function GaugeView.toTrack(offset: number): number
	return (math.clamp(offset, -1, 1) + 1) / 2
end

function GaugeView.layout(gauge: SwingStateMachine.Gauge, greenHalfWidth: number, targetPower: number?): Layout
	local good = Config.Swing.GoodHalfWidth
	local inAccuracy = gauge.Phase == "Accuracy" or gauge.Phase == "Done"
	return {
		Phase = gauge.Phase,
		Mode = gauge.Mode,
		PowerFill = math.clamp(gauge.Power, 0, 1),
		PowerPercent = math.clamp(gauge.Power, 0, 1) * 100,
		Locked = gauge.LockedPower ~= nil,
		NeedleX = if inAccuracy then GaugeView.toTrack(gauge.Needle) else nil,
		SweetLeft = GaugeView.toTrack(-greenHalfWidth),
		SweetRight = GaugeView.toTrack(greenHalfWidth),
		GoodLeft = GaugeView.toTrack(-good),
		GoodRight = GaugeView.toTrack(good),
		TargetPower = if targetPower then math.clamp(targetPower, 0, 1) else nil,
		TimeLeft = gauge.TimeLeft,
		TimeFraction = if gauge.TimeLeft then math.clamp(gauge.TimeLeft / Config.Swing.AccuracyTimeoutSeconds, 0, 1) else nil,
	}
end

return GaugeView
