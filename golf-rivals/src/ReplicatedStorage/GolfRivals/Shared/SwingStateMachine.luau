--!strict
--[[
	SwingStateMachine.luau  (ReplicatedStorage.GolfRivals.Shared)

	The 3-click swing gauge as a pure state machine driven by timestamps, so the
	client UI, bots and offline tests all share one implementation. Time is
	passed in (`os.clock()` on the client), never read internally.

	  Idle ──click──> PowerRising ──click──> AccuracyFalling ──click──> Done
	  (click 1: start)  (click 2: lock power)   (click 3: lock accuracy)

	TIMELINE (see Config.Swing for the numbers)
	  click 1 at t1:   marker rises  m(t) = (t - t1) / RiseSeconds, 0 -> 1.
	                   If it reaches 1 with no click, power auto-locks at 100%
	                   at t1 + RiseSeconds.
	  click 2 at t2:   power P = m(t2) (0..1). The marker now falls toward the
	                   green zone's centre, reaching it at tCenter = t2 + P*FallSeconds.
	  click 3 at t3:   offset = clamp((t3 - tCenter) / AccuracyWindowSeconds, -1, 1)
	                   early (t3 < tCenter) -> negative -> slice
	                   late  (t3 > tCenter) -> positive -> hook
	                   No click by tCenter + Window: auto-locks at offset +1
	                   (a very late hook), so stalling can't be exploited.

	Auto-locks use the exact deadline time (not the time of the next call), so
	the result is identical no matter how often the UI polls.
]]

local Config = require(script.Parent.Config)

local S = Config.Swing

export type Phase = "Idle" | "PowerRising" | "AccuracyFalling" | "Done"

export type Gauge = {
	Phase: Phase,
	-- Marker position for the UI. 0..1 while rising/falling (1 = full power).
	-- Goes below 0 after the centre, down to -1 at the auto-lock deadline.
	Marker: number,
	LockedPower: number?, -- 0..1 once click 2 happened
}

export type SwingResult = {
	Power: number, -- 0..100
	AccuracyOffset: number, -- -1..1
}

export type Machine = {
	click: (now: number) -> (),
	update: (now: number) -> (), -- apply auto-lock deadlines up to `now`
	gauge: (now: number) -> Gauge,
	phase: () -> Phase,
	result: () -> SwingResult?, -- non-nil only in Done
	reset: () -> (),
}

local SwingStateMachine = {}

function SwingStateMachine.new(): Machine
	local phase: Phase = "Idle"
	local t1, t2, tCenter = 0.0, 0.0, 0.0
	local power = 0.0 -- 0..1
	local offset = 0.0

	local function lockPower(at: number)
		power = math.clamp((at - t1) / S.RiseSeconds, 0, 1)
		t2 = at
		tCenter = t2 + power * S.FallSeconds
		phase = "AccuracyFalling"
	end

	local function lockAccuracy(at: number)
		offset = math.clamp((at - tCenter) / S.AccuracyWindowSeconds, -1, 1)
		phase = "Done"
	end

	-- Deadline reached with no click 3: exactly +1 (not "about 1" from float math).
	local function lockAccuracyLate()
		offset = 1
		phase = "Done"
	end

	-- Apply any deadline that has already passed, in order.
	local function update(now: number)
		if phase == "PowerRising" and now >= t1 + S.RiseSeconds then
			lockPower(t1 + S.RiseSeconds) -- full power, locked at the exact deadline
		end
		if phase == "AccuracyFalling" and now >= tCenter + S.AccuracyWindowSeconds then
			lockAccuracyLate()
		end
	end

	local function click(now: number)
		update(now)
		if phase == "Idle" then
			t1 = now
			phase = "PowerRising"
		elseif phase == "PowerRising" then
			lockPower(now)
		elseif phase == "AccuracyFalling" then
			lockAccuracy(now)
		end
		-- Done: further clicks ignored until reset().
	end

	local function gauge(now: number): Gauge
		update(now)
		if phase == "PowerRising" then
			return { Phase = phase, Marker = math.clamp((now - t1) / S.RiseSeconds, 0, 1), LockedPower = nil }
		elseif phase == "AccuracyFalling" then
			-- Falls at 1/FallSeconds per second, so it hits 0 exactly at tCenter.
			local marker = power - (now - t2) / S.FallSeconds
			return { Phase = phase, Marker = marker, LockedPower = power }
		elseif phase == "Done" then
			return { Phase = phase, Marker = 0, LockedPower = power }
		end
		return { Phase = phase, Marker = 0, LockedPower = nil }
	end

	local function result(): SwingResult?
		if phase ~= "Done" then
			return nil
		end
		return { Power = power * 100, AccuracyOffset = offset }
	end

	local function reset()
		phase = "Idle"
		t1, t2, tCenter, power, offset = 0, 0, 0, 0, 0
	end

	return {
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
