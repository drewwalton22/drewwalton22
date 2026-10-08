--!strict
--[[
	SwingPose.luau  (ReplicatedStorage.GolfRivals.Shared)

	Procedural golfer animation as pure keyframe math. Match/GolferRig turns a
	Pose into joint rotations on any rig (R15, R6 or the blocky bot rig), so every
	shot has a real swing - and a podium has real celebrations - even before any
	animation asset is uploaded (Assets.Animations stays the optional upgrade).

	POSE ANGLES (degrees, in the torso's own frame: the golfer faces -Z, +X is the
	golfer's right, +Y up; a right-handed golfer's TARGET is to their left, -X)
	  SpineYaw   chest turn about Y. Negative = turned away from the target (backswing),
	             positive = turned toward it (follow-through).
	  SpineBend  forward bend at the hips (positive = toward the ball).
	  HeadPitch  positive = look up.
	  RArmPitch / LArmPitch  arm raised forward from hanging (0 = by the side,
	             90 = straight out in front, 180 = straight up).
	  RArmRoll / LArmRoll    arm swung OUTWARD from the body (negative = across
	             the chest toward the other side).
	  Hop        whole-body lift in studs (victory jumps).

	TIMING: the club meets the ball at exactly Config.Match.SwingLeadSeconds into a
	"Swing" or "Putt" - the same lead the server waits before the ball flies - so the
	impact frame and the launch line up on every client.
]]

local Config = require(script.Parent.Config)

export type Pose = {
	SpineYaw: number,
	SpineBend: number,
	HeadPitch: number,
	RArmPitch: number,
	RArmRoll: number,
	LArmPitch: number,
	LArmRoll: number,
	Hop: number,
}

export type Kind = "Idle" | "Address" | "PuttAddress" | "Swing" | "Putt" | "Victory" | "Defeat"

type Key = { T: number, P: Pose }

local SwingPose = {}

local IMPACT = Config.Match.SwingLeadSeconds
SwingPose.IMPACT_SECONDS = IMPACT

local function pose(spineYaw: number, spineBend: number, headPitch: number, rPitch: number, rRoll: number, lPitch: number, lRoll: number, hop: number?): Pose
	return {
		SpineYaw = spineYaw, SpineBend = spineBend, HeadPitch = headPitch,
		RArmPitch = rPitch, RArmRoll = rRoll, LArmPitch = lPitch, LArmRoll = lRoll, Hop = hop or 0,
	}
end

SwingPose.IDLE = pose(0, 0, 0, 0, 0, 0, 0)
SwingPose.ADDRESS = pose(0, 22, -18, 24, -14, 24, -14)
SwingPose.PUTT_ADDRESS = pose(0, 34, -28, 30, -12, 30, -12)

-- Full swing keyframes at 100% power. Lower power shortens the backswing only.
local function swingKeys(power: number): { Key }
	local amount = 0.45 + 0.55 * math.clamp(power, 0, 100) / 100
	local top = pose(-85 * amount, 18, -16, 24 + 95 * amount, 22 * amount, 24 + 95 * amount, -14 - 30 * amount)
	return {
		{ T = 0, P = SwingPose.ADDRESS },
		{ T = 0.62, P = top },
		{ T = 0.74, P = top }, -- a beat at the top
		{ T = IMPACT, P = pose(15, 20, -18, 22, -12, 22, -12) }, -- impact: hands back at the ball, chest opening
		{ T = IMPACT + 0.32, P = pose(80, 6, -4, 128, -38, 128, 18) }, -- finish, facing the target
		{ T = IMPACT + 1.25, P = pose(78, 4, 0, 122, -34, 122, 16) }, -- hold the finish and watch
		{ T = IMPACT + 1.65, P = SwingPose.IDLE },
	}
end

local function puttKeys(power: number): { Key }
	local amount = 0.3 + 0.7 * math.clamp(power, 0, 100) / 100
	return {
		{ T = 0, P = SwingPose.PUTT_ADDRESS },
		{ T = 0.45, P = SwingPose.PUTT_ADDRESS },
		{ T = 0.78, P = pose(-10 * amount, 34, -28, 30 + 6 * amount, -6, 30 + 6 * amount, -18) }, -- back-stroke
		{ T = IMPACT, P = SwingPose.PUTT_ADDRESS },
		{ T = IMPACT + 0.25, P = pose(12 * amount, 33, -24, 34 + 8 * amount, -18, 34 + 8 * amount, -6) },
		{ T = IMPACT + 1.1, P = pose(12 * amount, 30, -10, 34, -18, 34, -6) },
		{ T = IMPACT + 1.5, P = SwingPose.IDLE },
	}
end

SwingPose.VICTORY_PERIOD = 0.9
SwingPose.DEFEAT_PERIOD = 3.2

-- Ease in-out (smoothstep) so joints accelerate and settle like a person.
local function ease(alpha: number): number
	local a = math.clamp(alpha, 0, 1)
	return a * a * (3 - 2 * a)
end

function SwingPose.lerp(a: Pose, b: Pose, alpha: number): Pose
	local function mix(x: number, y: number): number
		return x + (y - x) * alpha
	end
	return {
		SpineYaw = mix(a.SpineYaw, b.SpineYaw),
		SpineBend = mix(a.SpineBend, b.SpineBend),
		HeadPitch = mix(a.HeadPitch, b.HeadPitch),
		RArmPitch = mix(a.RArmPitch, b.RArmPitch),
		RArmRoll = mix(a.RArmRoll, b.RArmRoll),
		LArmPitch = mix(a.LArmPitch, b.LArmPitch),
		LArmRoll = mix(a.LArmRoll, b.LArmRoll),
		Hop = mix(a.Hop, b.Hop),
	}
end

local function sampleKeys(keys: { Key }, t: number): Pose
	if t <= keys[1].T then
		return keys[1].P
	end
	for i = 2, #keys do
		local a, b = keys[i - 1], keys[i]
		if t <= b.T then
			local span = b.T - a.T
			local alpha = if span > 0 then (t - a.T) / span else 1
			return SwingPose.lerp(a.P, b.P, ease(alpha))
		end
	end
	return keys[#keys].P
end

-- Length of a one-shot animation (loops return their period).
function SwingPose.duration(kind: Kind, power: number?): number
	if kind == "Swing" then
		local keys = swingKeys(power or 100)
		return keys[#keys].T
	elseif kind == "Putt" then
		local keys = puttKeys(power or 100)
		return keys[#keys].T
	elseif kind == "Victory" then
		return SwingPose.VICTORY_PERIOD
	elseif kind == "Defeat" then
		return SwingPose.DEFEAT_PERIOD
	end
	return 0
end

-- When the club meets the ball (nil for poses that never strike).
function SwingPose.impactTime(kind: Kind): number?
	return if kind == "Swing" or kind == "Putt" then IMPACT else nil
end

-- The pose `t` seconds into an animation. `power` (0-100) scales swings.
function SwingPose.sample(kind: Kind, t: number, power: number?): Pose
	if kind == "Swing" then
		return sampleKeys(swingKeys(power or 100), t)
	elseif kind == "Putt" then
		return sampleKeys(puttKeys(power or 100), t)
	elseif kind == "Address" then
		return SwingPose.ADDRESS
	elseif kind == "PuttAddress" then
		return SwingPose.PUTT_ADDRESS
	elseif kind == "Victory" then
		-- Arms pumping overhead with little jumps.
		local phase = (t % SwingPose.VICTORY_PERIOD) / SwingPose.VICTORY_PERIOD
		local pump = math.sin(phase * math.pi * 2)
		return pose(math.sin(t * 1.3) * 12, -4, 14, 160 + 14 * pump, 18, 160 - 14 * pump, 18, math.abs(math.sin(phase * math.pi)) * 1.6)
	elseif kind == "Defeat" then
		-- Head down, shoulders slumped, a slow disappointed sway.
		local sway = math.sin((t % SwingPose.DEFEAT_PERIOD) / SwingPose.DEFEAT_PERIOD * math.pi * 2)
		return pose(sway * 6, 24, -38, 8, -10, 8, -10)
	end
	return SwingPose.IDLE
end

return SwingPose
