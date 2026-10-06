--!strict
--[[
	GaugeView.luau  (ReplicatedStorage.GolfRivals.Shared)

	Maps the swing state machine's gauge onto a horizontal bar (0 = left, 1 = right)
	so the UI only has to place a few frames:

	    |<- late zone ->|<-------------- power 0 .. 100% -------------->|
	    x=0           ZeroX                                            x=1

	  * The bar's power axis starts at ZeroX (the "green zone centre"), where the
	    falling marker must be when you click for a perfect shot. Left of ZeroX is
	    the "too late" region the marker enters after the centre.
	  * marker units -> bar: x = (marker + w) / (1 + w), with
	        w = AccuracyWindowSeconds / FallSeconds   (marker units per offset 1)
	  * The green zone is +/- greenHalfWidth (offset units) around ZeroX, which is
	    +/- greenHalfWidth * w in marker units.

	Phase behaviour:
	  Idle             nothing moves
	  PowerRising      fill grows from ZeroX to the marker
	  AccuracyFalling  the locked power stays marked; the marker slides back to ZeroX
	  Done             frozen
]]

local Config = require(script.Parent.Config)
local SwingStateMachine = require(script.Parent.SwingStateMachine)

export type Layout = {
	Phase: SwingStateMachine.Phase,
	ZeroX: number,
	GreenLeftX: number,
	GreenRightX: number,
	MarkerX: number,
	LockedX: number?, -- locked power tick (after click 2)
	FillFromX: number,
	FillToX: number,
	PowerPercent: number, -- what click 2 would lock right now (or did lock)
}

local GaugeView = {}

local S = Config.Swing

-- Marker units per unit of accuracy offset.
function GaugeView.window(): number
	return S.AccuracyWindowSeconds / S.FallSeconds
end

function GaugeView.toX(marker: number): number
	local w = GaugeView.window()
	return math.clamp((marker + w) / (1 + w), 0, 1)
end

function GaugeView.layout(gauge: SwingStateMachine.Gauge, greenHalfWidth: number): Layout
	local w = GaugeView.window()
	local zero = GaugeView.toX(0)
	local marker = gauge.Marker
	local locked = gauge.LockedPower
	local power = if gauge.Phase == "PowerRising" then gauge.Marker elseif locked then locked else 0
	return {
		Phase = gauge.Phase,
		ZeroX = zero,
		GreenLeftX = GaugeView.toX(-greenHalfWidth * w),
		GreenRightX = GaugeView.toX(greenHalfWidth * w),
		MarkerX = GaugeView.toX(marker),
		LockedX = if locked then GaugeView.toX(locked) else nil,
		FillFromX = zero,
		FillToX = if gauge.Phase == "PowerRising" then GaugeView.toX(marker) elseif locked then GaugeView.toX(locked) else zero,
		PowerPercent = math.clamp(power, 0, 1) * 100,
	}
end

return GaugeView
