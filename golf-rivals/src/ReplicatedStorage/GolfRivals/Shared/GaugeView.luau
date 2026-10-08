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
	  PUTTS: the power track is a distance scale in FEET (the putter is linear and
	  auto-scaled, SwingMath.puttRange): tick marks at a round step (1/2/5/10/...
	  ft, at most 7 of them), a HOLE marker where the hole distance falls, and the
	  readout shows feet instead of percent.
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
	PowerLabel: string, -- "62%" (full swings) or "18 FT" (putts)
	PuttTicks: { PuttTick }?, -- putts: labelled tick marks along the power track
	HoleX: number?, -- putts: where the hole falls on the power track (0..1)
	TimeLeft: number?, -- seconds before stage 2 times out (nil outside stage 2)
	TimeFraction: number?, -- TimeLeft / AccuracyTimeoutSeconds (countdown ring)
}

export type PuttTick = { X: number, Label: string }
export type PuttScale = { RangeFeet: number, HoleFeet: number }

local GaugeView = {}

local TICK_STEPS = { 1, 2, 5, 10, 15, 20, 25, 50, 100 }

-- Tick marks (0..range feet) at the smallest round step giving <= 7 intervals.
function GaugeView.puttTicks(rangeFeet: number): { PuttTick }
	local step = TICK_STEPS[#TICK_STEPS]
	for _, candidate in TICK_STEPS do
		if rangeFeet / candidate <= 7 then
			step = candidate
			break
		end
	end
	local ticks: { PuttTick } = {}
	local feet = 0
	while feet <= rangeFeet + 1e-6 do
		table.insert(ticks, { X = feet / rangeFeet, Label = `{feet}` })
		feet += step
	end
	return ticks
end

-- Accuracy offset (-1..1) -> position on the accuracy track (0..1).
function GaugeView.toTrack(offset: number): number
	return (math.clamp(offset, -1, 1) + 1) / 2
end

function GaugeView.layout(gauge: SwingStateMachine.Gauge, greenHalfWidth: number, targetPower: number?, puttScale: PuttScale?): Layout
	local good = Config.Swing.GoodHalfWidth
	local inAccuracy = gauge.Phase == "Accuracy" or gauge.Phase == "Done"
	local power = math.clamp(gauge.Power, 0, 1)
	local holeX = if puttScale then math.clamp(puttScale.HoleFeet / puttScale.RangeFeet, 0, 1) else nil
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
		TargetPower = if holeX then holeX elseif targetPower then math.clamp(targetPower, 0, 1) else nil,
		PowerLabel = if puttScale then `{math.floor(power * puttScale.RangeFeet + 0.5)} FT` else `{math.floor(power * 100 + 0.5)}%`,
		PuttTicks = if puttScale then GaugeView.puttTicks(puttScale.RangeFeet) else nil,
		HoleX = holeX,
		TimeLeft = gauge.TimeLeft,
		TimeFraction = if gauge.TimeLeft then math.clamp(gauge.TimeLeft / Config.Swing.AccuracyTimeoutSeconds, 0, 1) else nil,
	}
end

return GaugeView
