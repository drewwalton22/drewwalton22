--!strict
--[[
	gen_animations.luau  (offline tool; run by tools/gen_animations.sh)

	Builds the golf animations as Roblox KeyframeSequence model files (.rbxmx)
	from the SAME pose maths the game uses procedurally (Shared/SwingPose), so a
	published animation moves exactly like the built-in fallback:

	    Address, PuttAddress   looped stance while lining up a shot
	    Swing, Putt            one-shot strokes with an "Impact" KeyframeMarker on
	                           the frame the club meets the ball
	    Victory, Defeat        looped podium celebrations

	Each move is written twice: <Move>_R15 and <Move>_R6 (different body parts).
	Rojo syncs the folder into ServerStorage > GolfRivals > AnimationsToPublish,
	where you right-click each one > Save to Roblox (see docs/STUDIO_SETUP.md).

	JOINT MATHS (mirrors Client/Golf/GolferRig.applyPose): each pose's CFrame is the
	joint Transform  R0^-1 * desired * R0,  R0 = the rotation of the joint's C0.
	R15 joints have no C0 rotation; R6 joints use Roblox's standard R6 C0s.
]]

local SwingPose = require("./SwingPose")

-- A CFrame as position + row-major 3x3 rotation.
type CF = { P: { number }, R: { { number } } }

local function cf(px: number, py: number, pz: number, r: { { number } }): CF
	return { P = { px, py, pz }, R = r }
end

local IDENTITY = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }

local function rx(a: number): CF
	local c, s = math.cos(a), math.sin(a)
	return cf(0, 0, 0, { { 1, 0, 0 }, { 0, c, -s }, { 0, s, c } })
end
local function ry(a: number): CF
	local c, s = math.cos(a), math.sin(a)
	return cf(0, 0, 0, { { c, 0, s }, { 0, 1, 0 }, { -s, 0, c } })
end
local function rz(a: number): CF
	local c, s = math.cos(a), math.sin(a)
	return cf(0, 0, 0, { { c, -s, 0 }, { s, c, 0 }, { 0, 0, 1 } })
end
local function translate(x: number, y: number, z: number): CF
	return cf(x, y, z, IDENTITY)
end

local function mul(a: CF, b: CF): CF
	local r: { { number } } = {}
	for i = 1, 3 do
		r[i] = {}
		for j = 1, 3 do
			r[i][j] = a.R[i][1] * b.R[1][j] + a.R[i][2] * b.R[2][j] + a.R[i][3] * b.R[3][j]
		end
	end
	local p: { number } = {}
	for i = 1, 3 do
		p[i] = a.P[i] + a.R[i][1] * b.P[1] + a.R[i][2] * b.P[2] + a.R[i][3] * b.P[3]
	end
	return { P = p, R = r }
end

local function inverse(a: CF): CF
	local r: { { number } } = { {}, {}, {} }
	for i = 1, 3 do
		for j = 1, 3 do
			r[i][j] = a.R[j][i]
		end
	end
	local p: { number } = {}
	for i = 1, 3 do
		p[i] = -(r[i][1] * a.P[1] + r[i][2] * a.P[2] + r[i][3] * a.P[3])
	end
	return { P = p, R = r }
end

local function rot(rows: { number }): CF
	return cf(0, 0, 0, { { rows[1], rows[2], rows[3] }, { rows[4], rows[5], rows[6] }, { rows[7], rows[8], rows[9] } })
end

-- Standard R6 joint C0 rotations (row-major).
local R6_C0 = {
	Torso = rot({ -1, 0, 0, 0, 0, 1, 0, 1, 0 }), -- RootJoint
	Head = rot({ -1, 0, 0, 0, 0, 1, 0, 1, 0 }), -- Neck
	["Right Arm"] = rot({ 0, 0, 1, 0, 1, 0, -1, 0, 0 }),
	["Left Arm"] = rot({ 0, 0, -1, 0, 1, 0, 1, 0, 0 }),
	["Right Leg"] = rot({ 0, 0, 1, 0, 1, 0, -1, 0, 0 }),
	["Left Leg"] = rot({ 0, 0, -1, 0, 1, 0, 1, 0, 0 }),
}

local function convert(r0: CF, desired: CF): CF
	return mul(mul(inverse(r0), desired), r0)
end

local function spineOf(p: SwingPose.Pose): CF
	return mul(ry(math.rad(p.SpineYaw)), rx(math.rad(-p.SpineBend)))
end
local function armOf(pitch: number, roll: number): CF
	return mul(rz(math.rad(roll)), rx(math.rad(pitch)))
end

-- Joint transforms for one pose, keyed by the part each joint moves.
local function transforms(p: SwingPose.Pose, rig: string): { [string]: CF }
	local spine = spineOf(p)
	local head = rx(math.rad(p.HeadPitch))
	local rightArm = armOf(p.RArmPitch, p.RArmRoll)
	local leftArm = armOf(p.LArmPitch, -p.LArmRoll)
	if rig == "R15" then
		return {
			LowerTorso = translate(0, p.Hop, 0),
			UpperTorso = spine,
			Head = head,
			RightUpperArm = rightArm,
			LeftUpperArm = leftArm,
		}
	end
	local counter = inverse(spine)
	return {
		Torso = convert(R6_C0.Torso, mul(translate(0, p.Hop, 0), spine)),
		Head = convert(R6_C0.Head, head),
		["Right Arm"] = convert(R6_C0["Right Arm"], rightArm),
		["Left Arm"] = convert(R6_C0["Left Arm"], leftArm),
		["Right Leg"] = convert(R6_C0["Right Leg"], counter),
		["Left Leg"] = convert(R6_C0["Left Leg"], counter),
	}
end

-- Pose tree (parent -> children) per rig.
local TREES: { [string]: { [string]: { string } } } = {
	R15 = {
		HumanoidRootPart = { "LowerTorso" },
		LowerTorso = { "UpperTorso" },
		UpperTorso = { "Head", "RightUpperArm", "LeftUpperArm" },
	},
	R6 = {
		HumanoidRootPart = { "Torso" },
		Torso = { "Head", "Right Arm", "Left Arm", "Right Leg", "Left Leg" },
	},
}

local referent = 0
local function ref(): string
	referent += 1
	return `RBX{referent}`
end

local function num(x: number): string
	local v = if math.abs(x) < 1e-9 then 0 else x
	return string.format("%.6f", v)
end

local function cframeXml(c: CF): string
	local r = c.R
	return `<CoordinateFrame name="CFrame"><X>{num(c.P[1])}</X><Y>{num(c.P[2])}</Y><Z>{num(c.P[3])}</Z>`
		.. `<R00>{num(r[1][1])}</R00><R01>{num(r[1][2])}</R01><R02>{num(r[1][3])}</R02>`
		.. `<R10>{num(r[2][1])}</R10><R11>{num(r[2][2])}</R11><R12>{num(r[2][3])}</R12>`
		.. `<R20>{num(r[3][1])}</R20><R21>{num(r[3][2])}</R21><R22>{num(r[3][3])}</R22></CoordinateFrame>`
end

local function poseXml(name: string, tree: { [string]: { string } }, values: { [string]: CF }, out: { string })
	local c = values[name] or translate(0, 0, 0)
	table.insert(out, `<Item class="Pose" referent="{ref()}"><Properties><string name="Name">{name}</string>{cframeXml(c)}<float name="Weight">1</float></Properties>`)
	for _, child in tree[name] or {} do
		poseXml(child, tree, values, out)
	end
	table.insert(out, "</Item>")
end

type Move = { Name: string, Kind: SwingPose.Kind, Length: number, Loop: boolean, Step: number }

local MOVES: { Move } = {
	{ Name = "Address", Kind = "Address", Length = 1, Loop = true, Step = 1 },
	{ Name = "PuttAddress", Kind = "PuttAddress", Length = 1, Loop = true, Step = 1 },
	{ Name = "Swing", Kind = "Swing", Length = SwingPose.duration("Swing", 100), Loop = false, Step = 1 / 20 },
	{ Name = "Putt", Kind = "Putt", Length = SwingPose.duration("Putt", 100), Loop = false, Step = 1 / 20 },
	{ Name = "Victory", Kind = "Victory", Length = SwingPose.VICTORY_PERIOD, Loop = true, Step = SwingPose.VICTORY_PERIOD / 12 },
	{ Name = "Defeat", Kind = "Defeat", Length = SwingPose.DEFEAT_PERIOD, Loop = true, Step = SwingPose.DEFEAT_PERIOD / 16 },
}

local function sequence(move: Move, rig: string): string
	referent = 0
	local out: { string } = {}
	table.insert(out, '<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">')
	table.insert(out, `<Item class="KeyframeSequence" referent="{ref()}"><Properties><string name="Name">{move.Name}_{rig}</string><bool name="Loop">{if move.Loop then "true" else "false"}</bool><token name="Priority">2</token></Properties>`)
	local impact = SwingPose.impactTime(move.Kind)
	local times: { number } = {}
	local t = 0
	while t < move.Length - 1e-6 do
		table.insert(times, t)
		t += move.Step
	end
	table.insert(times, move.Length)
	if impact then
		-- Make sure there is a keyframe exactly on the impact.
		local has = false
		for _, v in times do
			if math.abs(v - impact) < 1e-6 then
				has = true
			end
		end
		if not has then
			table.insert(times, impact)
			table.sort(times)
		end
	end
	for _, time in times do
		local pose = SwingPose.sample(move.Kind, time, 100)
		table.insert(out, `<Item class="Keyframe" referent="{ref()}"><Properties><string name="Name">Keyframe</string><float name="Time">{num(time)}</float></Properties>`)
		poseXml("HumanoidRootPart", TREES[rig], transforms(pose, rig), out)
		if impact and math.abs(time - impact) < 1e-6 then
			table.insert(out, `<Item class="KeyframeMarker" referent="{ref()}"><Properties><string name="Name">Impact</string><string name="Value"></string></Properties></Item>`)
		end
		table.insert(out, "</Item>")
	end
	table.insert(out, "</Item>")
	table.insert(out, "</roblox>")
	return table.concat(out, "\n")
end

for _, move in MOVES do
	for _, rig in { "R15", "R6" } do
		print(`=====FILE {move.Name}_{rig}.rbxmx=====`)
		print(sequence(move, rig))
	end
end
print("=====END=====")
