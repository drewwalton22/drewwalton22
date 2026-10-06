--!strict
--[[
	SwingStateMachine.luau  (ReplicatedStorage.GolfRivals.Shared)

	The classic 2-STAGE timing bar as a pure state machine driven by timestamps, so
	the client UI, the anti-cheat bound and offline tests share one implementation.
	Time is passed in (`os.clock()` on the client), never read internally.

	  Idle ──start──> Power ──click 1──> Accuracy ──click 2──> Done
	                  (lock power)        (lock accuracy)

	STAGE 1 - POWER (starts the moment the bar is armed)
	  The power marker sweeps 0% -> 100% in PowerSweepSeconds, then back down to 0%
	  at the same speed, and so on (a triangle wave), until click 1 locks it:
	      u = ((t - t0) / PowerSweep) mod 2,   power = u (u <= 1) else 2 - u

	STAGE 2 - ACCURACY
	  A needle crosses the accuracy track from left (-1) to right (+1) in
	  AccuracySweepSeconds. The SWEET SPOT is the centre (0):
	      offset = clamp(-1 + 2 * (t - t1) / AccuracySweep, -1, 1)
	      offset < 0  clicked EARLY (left of centre) -> slice (curves right)
	      offset > 0  clicked LATE  (right of centre) -> hook  (curves left)
	  No click by the end of the track: auto-locks at exactly +1 (a hard hook),
	  so stalling can never be exploited.

	SPEED is per mode (Config.Swing): full swings use PowerSweepSeconds /
	AccuracySweepSeconds; putts use the much slower PuttPowerSweepSeconds /
	PuttAccuracySweepSeconds for fine pace control.
]]

local Config = require(script.Parent.Config)

local S = Config.Swing

export type Mode = "Full" | "Putt"
export type Phase = "Idle" | "Power" | "Accuracy" | "Done"

export type Gauge = {
	Phase: Phase,
	Mode: Mode,
	Power: number, -- 0..1: live in the Power stage, the locked value afterwards
	Needle: number, -- -1..1 in the Accuracy stage (0 otherwise)
	LockedPower: number?, -- 0..1 once click 1 happened
}

export type SwingResult = {
	Power: number, -- 0..100
	AccuracyOffset: number, -- -1..1
}

export type Machine = {
	start: (now: number, mode: Mode?) -> (), -- arm: the power marker starts moving
	click: (now: number) -> (),
	update: (now: number) -> (), -- apply the accuracy auto-lock up to `now`
	gauge: (now: number) -> Gauge,
	phase: () -> Phase,
	result: () -> SwingResult?, -- non-nil only in Done
	reset: () -> (),
}

local SwingStateMachine = {}

-- (power sweep seconds, accuracy sweep seconds) for a mode.
function SwingStateMachine.speeds(mode: Mode): (number, number)
	if mode == "Putt" then
		return S.PuttPowerSweepSeconds, S.PuttAccuracySweepSeconds
	end
	return S.PowerSweepSeconds, S.AccuracySweepSeconds
end

-- Power marker (0..1) `elapsed` seconds into the Power stage.
function SwingStateMachine.powerAt(elapsed: number, sweep: number): number
	local u = (math.max(elapsed, 0) / sweep) % 2
	return if u <= 1 then u else 2 - u
end

function SwingStateMachine.new(): Machine
	local phase: Phase = "Idle"
	local mode: Mode = "Full"
	local powerSweep, accuracySweep = SwingStateMachine.speeds("Full")
	local t0, t1 = 0.0, 0.0
	local power = 0.0 -- 0..1
	local offset = 0.0

	local function start(now: number, newMode: Mode?)
		mode = newMode or "Full"
		powerSweep, accuracySweep = SwingStateMachine.speeds(mode)
		t0 = now
		power, offset = 0, 0
		phase = "Power"
	end

	local function update(now: number)
		if phase == "Accuracy" and now >= t1 + accuracySweep then
			offset = 1 -- deadline: exactly +1, not "about 1" from float math
			phase = "Done"
		end
	end

	local function click(now: number)
		update(now)
		if phase == "Idle" then
			start(now, mode) -- a click on an un-armed bar just starts it
		elseif phase == "Power" then
			power = SwingStateMachine.powerAt(now - t0, powerSweep)
			t1 = now
			phase = "Accuracy"
		elseif phase == "Accuracy" then
			offset = math.clamp(-1 + 2 * (now - t1) / accuracySweep, -1, 1)
			phase = "Done"
		end
		-- Done: further clicks ignored until reset().
	end

	local function gauge(now: number): Gauge
		update(now)
		if phase == "Power" then
			return { Phase = phase, Mode = mode, Power = SwingStateMachine.powerAt(now - t0, powerSweep), Needle = 0, LockedPower = nil }
		elseif phase == "Accuracy" then
			return { Phase = phase, Mode = mode, Power = power, Needle = math.clamp(-1 + 2 * (now - t1) / accuracySweep, -1, 1), LockedPower = power }
		elseif phase == "Done" then
			return { Phase = phase, Mode = mode, Power = power, Needle = offset, LockedPower = power }
		end
		return { Phase = phase, Mode = mode, Power = 0, Needle = 0, LockedPower = nil }
	end

	local function result(): SwingResult?
		if phase ~= "Done" then
			return nil
		end
		return { Power = power * 100, AccuracyOffset = offset }
	end

	local function reset()
		phase = "Idle"
		t0, t1, power, offset = 0, 0, 0, 0
	end

	return {
		start = start,
		click = click,
		update = update,
		gauge = gauge,
		phase = function(): Phase
			return phase
		end,
		result = result,
		reset = reset,
	}
end

return SwingStateMachine
