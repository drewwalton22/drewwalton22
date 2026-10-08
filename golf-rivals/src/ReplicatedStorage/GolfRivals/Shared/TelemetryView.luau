--!strict
--[[
	TelemetryView.luau  (ReplicatedStorage.GolfRivals.Shared)

	The live numbers on the post-shot overlay (mockup panel 10): TOTAL DISTANCE,
	CARRY, ROLL, APEX and SPIN, evaluated at time `t` of the ball's flight.

	Input is the `Shot` event the server sent: `Samples` = { {t, x, y, z}, ... } in
	the hole frame (metres), `AirSeconds` (touchdown time) and the final
	`Telemetry`. While the ball is airborne CARRY and TOTAL both grow with the
	distance flown; at touchdown CARRY freezes at its final value and ROLL starts
	counting the extra distance; when the ball stops everything shows the exact
	final numbers from the server.

	    carry(t) = flown(t)                       while t < AirSeconds
	             = final carry                    after touchdown
	    total(t) = flown(t)                       (straight-line distance from the start)
	    roll(t)  = max(0, total(t) - carry(t))
	    apex(t)  = highest point reached so far, in feet
]]

local Config = require(script.Parent.Config)

export type Telemetry = {
	CarryYds: number,
	TotalYds: number,
	RollYds: number,
	ApexFeet: number,
	SpinRpm: number,
	BallSpeedMph: number,
	LateralYds: number,
}

export type Shot = {
	Samples: { { number } },
	AirSeconds: number, -- touchdown time; 0 for putts
	Telemetry: Telemetry,
}

export type Live = {
	CarryYds: number,
	TotalYds: number,
	RollYds: number,
	ApexFeet: number,
	SpinRpm: number,
	Landed: boolean,
	Done: boolean,
	X: number, -- ball position (metres, hole frame)
	Y: number,
	Z: number,
}

local TelemetryView = {}

local YD = Config.Physics.YardsToMeters
local FT = Config.Physics.MetersToFeet

-- Linear interpolation of the ball position at time t (clamped to the ends).
function TelemetryView.positionAt(samples: { { number } }, t: number): (number, number, number)
	local count = #samples
	if count == 0 then
		return 0, 0, 0
	end
	if t <= samples[1][1] then
		return samples[1][2], samples[1][3], samples[1][4]
	end
	local last = samples[count]
	if t >= last[1] then
		return last[2], last[3], last[4]
	end
	-- Samples are time-ordered; find the bracketing pair.
	local lo, hi = 1, count
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if samples[mid][1] <= t then
			lo = mid
		else
			hi = mid
		end
	end
	local a, b = samples[lo], samples[hi]
	local span = b[1] - a[1]
	local f = if span > 1e-9 then (t - a[1]) / span else 0
	return a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f, a[4] + (b[4] - a[4]) * f
end

function TelemetryView.duration(shot: Shot): number
	local last = shot.Samples[#shot.Samples]
	return if last then last[1] else 0
end

function TelemetryView.at(shot: Shot, t: number): Live
	local samples = shot.Samples
	local final = shot.Telemetry
	local x, y, z = TelemetryView.positionAt(samples, t)
	local first = samples[1]
	local done = t >= TelemetryView.duration(shot)
	local landed = t >= shot.AirSeconds

	if done then
		return {
			CarryYds = final.CarryYds, TotalYds = final.TotalYds, RollYds = final.RollYds,
			ApexFeet = final.ApexFeet, SpinRpm = final.SpinRpm, Landed = true, Done = true, X = x, Y = y, Z = z,
		}
	end

	local flown = 0
	if first then
		local dx, dz = x - first[2], z - first[4]
		flown = math.sqrt(dx * dx + dz * dz) / YD
	end
	local apex = 0
	for _, s in samples do
		if s[1] > t then
			break
		end
		apex = math.max(apex, (s[3] - (if first then first[3] else 0)) * FT)
	end
	-- Never show more than the final apex (interpolation can't exceed the samples).
	apex = math.min(apex, final.ApexFeet)

	local carry = if landed then final.CarryYds else flown
	return {
		CarryYds = carry,
		TotalYds = flown,
		RollYds = math.max(0, flown - carry),
		ApexFeet = apex,
		SpinRpm = final.SpinRpm,
		Landed = landed,
		Done = false,
		X = x, Y = y, Z = z,
	}
end

return TelemetryView
