--!strict
--[[
	AimGuide.luau  (ReplicatedStorage.GolfRivals.Shared)

	The aiming arc / putting line shown in front of the player before a swing.

	It is not a guess: the guide runs the SAME ShotPhysics the server uses for the
	selected club, the player's stats, the lie and the chosen power, with a perfect
	strike and NO wind (wind is the player's job to read). So the arc lands where a
	flushed shot would land in still air, and the putting line bends with the
	green's slope exactly like the real putt will.

	  full shots -> the flight up to the first touchdown (the arc) + the landing spot
	  putts      -> the roll path along the ground (the putting line), up to where
	                the ball would stop (the cup is ignored so the line shows pace)

	Output points are in the caller's frame (hole frame on the course, range frame
	at the driving range), metres, with Y = height above the ground. The client
	turns them into parts/beams. Point count is capped so drawing stays cheap.
]]

local ClubDatabase = require(script.Parent.ClubDatabase)
local CourseTerrain = require(script.Parent.CourseTerrain)
local ShotPhysics = require(script.Parent.ShotPhysics)
local SwingMath = require(script.Parent.SwingMath)
local Types = require(script.Parent.Types)

export type Point = { X: number, Y: number, Z: number }

export type Request = {
	Terrain: ShotPhysics.Terrain, -- in the caller's frame
	X: number, -- ball position (caller's frame, metres)
	Z: number,
	HeadingRad: number, -- aim direction in the caller's frame
	Slot: ClubDatabase.BagSlot,
	Stats: ClubDatabase.Stats,
	Lie: Types.LieId,
	Power: number, -- 0..100
}

export type Guide = {
	IsPutt: boolean,
	Points: { Point },
	EndX: number, -- landing spot (full shots) or rest spot (putts), caller's frame
	EndZ: number,
	DistanceYds: number, -- carry (full shots) or roll (putts)
}

local AimGuide = {}

AimGuide.MAX_POINTS = 28
AimGuide.MIN_POWER = 2 -- below this the guide is a stub, not a line of zero length

function AimGuide.compute(request: Request): Guide
	local power = math.clamp(request.Power, AimGuide.MIN_POWER, 100)
	local launch = SwingMath.computeLaunch({
		Slot = request.Slot,
		Stats = request.Stats,
		Power = power,
		AccuracyOffset = 0,
		Lie = request.Lie,
	})
	local frame = CourseTerrain.shotFrame(request.Terrain, request.X, request.Z, request.HeadingRad)
	local result = ShotPhysics.simulate(launch, frame, nil, nil, { CarryOnly = not launch.IsPutt, KeepSamples = true })

	-- Thin the samples evenly, always keeping the last one.
	local samples = result.Samples
	local step = math.max(1, math.ceil(#samples / AimGuide.MAX_POINTS))
	local points: { Point } = {}
	local function push(sample: ShotPhysics.Sample)
		local hx, hz = CourseTerrain.toHole(request.X, request.Z, request.HeadingRad, sample.X, sample.Z)
		table.insert(points, { X = hx, Y = math.max(0, sample.Y - frame.heightAt(sample.X, sample.Z)), Z = hz })
	end
	for i = 1, #samples, step do
		push(samples[i])
	end
	if #samples > 0 and (#samples - 1) % step ~= 0 then
		push(samples[#samples])
	end

	local endLocalX = if launch.IsPutt then result.FinalX else result.LandingX
	local endLocalZ = if launch.IsPutt then result.FinalZ else result.LandingZ
	local endX, endZ = CourseTerrain.toHole(request.X, request.Z, request.HeadingRad, endLocalX, endLocalZ)
	return {
		IsPutt = launch.IsPutt,
		Points = points,
		EndX = endX,
		EndZ = endZ,
		DistanceYds = if launch.IsPutt then result.TotalYds else result.CarryYds,
	}
end

return AimGuide
