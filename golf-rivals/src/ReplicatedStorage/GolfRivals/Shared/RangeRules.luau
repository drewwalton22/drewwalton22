--!strict
--[[
	RangeRules.luau  (ReplicatedStorage.GolfRivals.Shared)

	The lobby DRIVING RANGE: where the hitting bays and target greens are, how a
	range shot is simulated, and what it pays. Pure, so the server (authoritative
	payout), the client (drawing the targets, the aim arc) and LobbyLayout (building
	the range) all agree, and tests cover it offline.

	FRAMES
	  World (studs): the range sits west of the plaza; balls are hit toward -X.
	  Range frame (metres): origin = middle of the tee line, +X = downrange,
	  +Z = to the golfer's right when facing downrange (same handedness as a shot
	  frame, so CourseTerrain.toHole/toShot work unchanged).
	      worldX = ORIGIN.X - x * STUDS_PER_METER
	      worldZ = ORIGIN.Z - z * STUDS_PER_METER

	PAYOUT
	  A ball that comes to REST on a target green pays that target's coins; inside
	  the inner third (bullseye) it pays Config.Range.BullseyeMultiplier times as
	  much. Further targets are smaller and pay more. The daily cap is applied by
	  ZoneRewards, not here.
]]

local ClubDatabase = require(script.Parent.ClubDatabase)
local Config = require(script.Parent.Config)
local CourseLayout = require(script.Parent.CourseLayout)
local CourseTerrain = require(script.Parent.CourseTerrain)
local ShotPhysics = require(script.Parent.ShotPhysics)
local SwingMath = require(script.Parent.SwingMath)
local Types = require(script.Parent.Types)

export type Bay = {
	Id: number,
	WorldZ: number, -- studs; the bay's tee is at (ORIGIN.X, WorldZ)
}

export type Target = {
	Id: string,
	Name: string,
	DistanceYds: number, -- downrange distance of the centre
	LateralYds: number, -- + = right of the centre line (looking downrange)
	RadiusYds: number,
	Coins: number,
	Color: Types.RGB, -- flag / ring colour
}

export type Shot = {
	BayId: number,
	ClubLabel: string,
	Quality: SwingMath.Quality,
	Samples: { { number } }, -- { t, x, y, z } in the RANGE frame (metres)
	AirSeconds: number,
	TotalSeconds: number,
	Final: { X: number, Z: number },
	TargetId: string?,
	Bullseye: boolean,
	Coins: number, -- before the daily cap
	Telemetry: { CarryYds: number, TotalYds: number, ApexFeet: number, BallSpeedMph: number, LateralYds: number, SpinRpm: number, RollYds: number },
}

local RangeRules = {}

local YD = Config.Physics.YardsToMeters
local SPM = CourseLayout.STUDS_PER_METER

RangeRules.ORIGIN = { X = -125, Z = 40 } -- world studs, middle of the tee line
RangeRules.MaxAimDegrees = 20
RangeRules.Bays = {
	{ Id = 1, WorldZ = 16 },
	{ Id = 2, WorldZ = 32 },
	{ Id = 3, WorldZ = 48 },
	{ Id = 4, WorldZ = 64 },
} :: { Bay }

RangeRules.Targets = {
	{ Id = "T50", Name = "50", DistanceYds = 50, LateralYds = -6, RadiusYds = 8, Coins = 10, Color = { 90, 200, 120 } },
	{ Id = "T90", Name = "90", DistanceYds = 90, LateralYds = 8, RadiusYds = 9, Coins = 15, Color = { 80, 170, 255 } },
	{ Id = "T130", Name = "130", DistanceYds = 130, LateralYds = -10, RadiusYds = 10, Coins = 25, Color = { 170, 110, 255 } },
	{ Id = "T175", Name = "175", DistanceYds = 175, LateralYds = 7, RadiusYds = 11, Coins = 40, Color = { 255, 150, 60 } },
	{ Id = "T225", Name = "225", DistanceYds = 225, LateralYds = 0, RadiusYds = 13, Coins = 60, Color = { 255, 205, 60 } },
} :: { Target }

-- How far the mown range extends (yards) - used by LobbyLayout and tests.
RangeRules.LengthYds = 300
RangeRules.HalfWidthYds = 60

-- ---------------------------------------------------------------------------
-- Frames
-- ---------------------------------------------------------------------------

function RangeRules.toWorld(x: number, z: number): (number, number)
	return RangeRules.ORIGIN.X - x * SPM, RangeRules.ORIGIN.Z - z * SPM
end

function RangeRules.fromWorld(worldX: number, worldZ: number): (number, number)
	return (RangeRules.ORIGIN.X - worldX) / SPM, (RangeRules.ORIGIN.Z - worldZ) / SPM
end

function RangeRules.bay(id: any): Bay?
	for _, bay in RangeRules.Bays do
		if bay.Id == id then
			return bay
		end
	end
	return nil
end

-- The bay's tee in the range frame (metres).
function RangeRules.teeOf(bay: Bay): (number, number)
	return RangeRules.fromWorld(RangeRules.ORIGIN.X, bay.WorldZ)
end

-- Target centre in the range frame (metres).
function RangeRules.centreOf(target: Target): (number, number)
	return target.DistanceYds * YD, target.LateralYds * YD
end

-- ---------------------------------------------------------------------------
-- Scoring
-- ---------------------------------------------------------------------------

-- Which target (if any) contains the range-frame point, and whether it is the bullseye.
function RangeRules.targetAt(x: number, z: number): (Target?, boolean)
	for _, target in RangeRules.Targets do
		local cx, cz = RangeRules.centreOf(target)
		local d = math.sqrt((x - cx) ^ 2 + (z - cz) ^ 2)
		local radius = target.RadiusYds * YD
		if d <= radius then
			return target, d <= radius / 3
		end
	end
	return nil, false
end

function RangeRules.payout(target: Target?, bullseye: boolean): number
	if target == nil then
		return 0
	end
	return if bullseye then target.Coins * Config.Range.BullseyeMultiplier else target.Coins
end

-- The range as terrain: flat; target greens play as Green (balls check up on
-- them), everything else as Fairway.
function RangeRules.terrain(): ShotPhysics.Terrain
	return {
		heightAt = function(_x: number, _z: number): number
			return 0
		end,
		lieAt = function(x: number, z: number): Types.LieId
			return if RangeRules.targetAt(x, z) then "Green" else "Fairway"
		end,
		slopeAt = function(_x: number, _z: number): (number, number)
			return 0, 0
		end,
	}
end

-- ---------------------------------------------------------------------------
-- Shots
-- ---------------------------------------------------------------------------

-- Simulates one range ball from a bay. Inputs must already be validated (the
-- server checks timing, ranges and ownership); this clamps defensively anyway.
-- Range balls are always hit off a perfect lie with no wind.
function RangeRules.resolve(bay: Bay, label: string, stats: ClubDatabase.Stats, power: number, offset: number, aimDeg: number): Shot?
	local slot = ClubDatabase.getSlot(label)
	if slot == nil or slot.Class == "Putter" then
		return nil -- no putting at the range
	end
	local teeX, teeZ = RangeRules.teeOf(bay)
	local heading = math.rad(math.clamp(aimDeg, -RangeRules.MaxAimDegrees, RangeRules.MaxAimDegrees))
	local frame = CourseTerrain.shotFrame(RangeRules.terrain(), teeX, teeZ, heading)
	local shot = SwingMath.resolveShot({
		Slot = slot,
		Stats = stats,
		Power = math.clamp(power, 0, 100),
		AccuracyOffset = math.clamp(offset, -1, 1),
		Lie = "Tee",
	}, frame, nil)
	local result = shot.Result

	local samples: { { number } } = {}
	for _, s in result.Samples do
		local x, z = CourseTerrain.toHole(teeX, teeZ, heading, s.X, s.Z)
		table.insert(samples, { s.T, x, s.Y, z })
	end
	local finalX, finalZ = CourseTerrain.toHole(teeX, teeZ, heading, result.FinalX, result.FinalZ)
	local target, bullseye = RangeRules.targetAt(finalX, finalZ)
	return {
		BayId = bay.Id,
		ClubLabel = label,
		Quality = shot.Quality,
		Samples = samples,
		AirSeconds = result.FlightSeconds,
		TotalSeconds = result.TotalSeconds,
		Final = { X = finalX, Z = finalZ },
		TargetId = if target then target.Id else nil,
		Bullseye = target ~= nil and bullseye,
		Coins = RangeRules.payout(target, bullseye),
		Telemetry = {
			CarryYds = result.CarryYds, TotalYds = result.TotalYds, ApexFeet = result.ApexFeet,
			BallSpeedMph = result.BallSpeedMph, LateralYds = result.LateralYds, SpinRpm = result.SpinRpm,
			RollYds = result.RollYds,
		},
	}
end

return RangeRules
