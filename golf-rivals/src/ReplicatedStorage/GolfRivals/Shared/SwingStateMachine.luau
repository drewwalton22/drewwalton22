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

	STAGE 2 - ACCURACY (back-and-forth)
	  A needle swings across the accuracy track and back, smoothly, like a
	  ping-pong: left (-1) -> right (+1) in AccuracySweepSeconds, then right -> left
	  at the same speed, and so on. The SWEET SPOT is the centre (0):
	      u = ((t - t1) / AccuracySweep) mod 2,   v = u (u <= 1) else 2 - u
	      offset = -1 + 2 v
	      offset < 0  the needle was LEFT of centre  -> slice (curves right)
	      offset > 0  the needle was RIGHT of centre -> hook  (curves left)
	  5-SECOND TIMEOUT: with no click within AccuracyTimeoutSeconds the shot
	  fires by itself with a RANDOM accuracy penalty - |offset| between
	  TimeoutPenaltyMin and TimeoutPenaltyMax, randomly hooked or sliced - so
	  stalling never helps. (The rng is injected: new(rng), for tests.)

	SPEED is per mode (Config.Swing): full swings use PowerSweepSeconds /
	AccuracySweepSeconds; putts use the much slower PuttPowerSweepSeconds /
	PuttAccuracySweepSeconds for fine pace control. start() also takes a speed
	scale (2 = twice as fast) for difficulty settings.
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
	TimeLeft: number?, -- seconds before the accuracy stage times out
}

export type SwingResult = {
	Power: number, -- 0..100
	AccuracyOffset: number, -- -1..1
	TimedOut: boolean, -- no click 2: fired with a random penalty
}

export type Machine = {
	start: (now: number, mode: Mode?, speedScale: number?) -> (), -- arm: the power marker starts moving
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

-- Accuracy needle (-1..1) `elapsed` seconds into the Accuracy stage (ping-pong).
function SwingStateMachine.needleAt(elapsed: number, sweep: number): number
	return -1 + 2 * SwingStateMachine.powerAt(elapsed, sweep)
end

-- The random penalty offset for a timed-out accuracy stage.
function SwingStateMachine.timeoutOffset(rng: () -> number): number
	local magnitude = S.TimeoutPenaltyMin + (S.TimeoutPenaltyMax - S.TimeoutPenaltyMin) * math.clamp(rng(), 0, 1)
	return if rng() < 0.5 then -magnitude else magnitude
end

-- Deterministic fallback rng (callers pass Random:NextNumber in the game).
local function defaultRng(): () -> number
	local state = 12345
	return function(): number
		state = (state * 1103515245 + 12345) % 2147483648
		return state / 2147483648
	end
end

function SwingStateMachine.new(rng: (() -> number)?): Machine
	local random = rng or defaultRng()
	local phase: Phase = "Idle"
	local mode: Mode = "Full"
	local powerSweep, accuracySweep = SwingStateMachine.speeds("Full")
	local t0, t1 = 0.0, 0.0
	local power = 0.0 -- 0..1
	local offset = 0.0
	local timedOut = false

	local function start(now: number, newMode: Mode?, speedScale: number?)
		mode = newMode or "Full"
		powerSweep, accuracySweep = SwingStateMachine.speeds(mode)
		local scale = math.clamp(speedScale or 1, 0.25, 4)
		powerSweep, accuracySweep = powerSweep / scale, accuracySweep / scale
		t0 = now
		power, offset, timedOut = 0, 0, false
		phase = "Power"
	end

	local function update(now: number)
		if phase == "Accuracy" and now >= t1 + S.AccuracyTimeoutSeconds then
			offset = SwingStateMachine.timeoutOffset(random)
			timedOut = true
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
			offset = SwingStateMachine.needleAt(now - t1, accuracySweep)
			phase = "Done"
		end
		-- Done: further clicks ignored until reset().
	end

	local function gauge(now: number): Gauge
		update(now)
		if phase == "Power" then
			return { Phase = phase, Mode = mode, Power = SwingStateMachine.powerAt(now - t0, powerSweep), Needle = 0, LockedPower = nil }
		elseif phase == "Accuracy" then
			return {
				Phase = phase, Mode = mode, Power = power, Needle = SwingStateMachine.needleAt(now - t1, accuracySweep), LockedPower = power,
				TimeLeft = math.max(0, t1 + S.AccuracyTimeoutSeconds - now),
			}
		elseif phase == "Done" then
			return { Phase = phase, Mode = mode, Power = power, Needle = offset, LockedPower = power }
		end
		return { Phase = phase, Mode = mode, Power = 0, Needle = 0, LockedPower = nil }
	end

	local function result(): SwingResult?
		if phase ~= "Done" then
			return nil
		end
		return { Power = power * 100, AccuracyOffset = offset, TimedOut = timedOut }
	end

	local function reset()
		phase = "Idle"
		t0, t1, power, offset, timedOut = 0, 0, 0, 0, false
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
