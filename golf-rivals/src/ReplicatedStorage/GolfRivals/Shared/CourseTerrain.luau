--!strict
--[[
	CourseTerrain.luau  (ReplicatedStorage.GolfRivals.Shared)

	Turns a HoleDef's shapes into the Terrain interface ShotPhysics needs
	(heightAt / lieAt / slopeAt), and re-expresses it in a shot's own frame.

	TWO FRAMES
	  hole frame: where the course data lives (tee at the origin).
	  shot frame: what ShotPhysics simulates in: origin at the ball, +X along the
	              aim, +Z to the golfer's right.
	  A ball at (ox, oz) aiming along heading h (radians, measured from hole +X
	  toward hole +Z) has
	      d = (cos h,  sin h)     aim direction   (shot +X expressed in hole frame)
	      r = (-sin h, cos h)     right direction (shot +Z expressed in hole frame)
	      hole(xl, zl) = (ox, oz) + xl * d + zl * r
	  Slopes transform by projection: (gx, gz)_shot = ((g . d), (g . r)).
	  Heading 0 gives d = (1,0), r = (0,1), matching "+Z is right when facing +X".

	LIE PRIORITY (first match wins): Water > Green > Sand > Tee > Fairway > Rough.
	Height is flat everywhere; only greens have a slope (used for the ball's roll
	and the landing normal).
]]

local Types = require(script.Parent.Types)
local CourseDatabase = require(script.Parent.CourseDatabase)
local ShotPhysics = require(script.Parent.ShotPhysics)

local CourseTerrain = {}

local TEE_BOX_RADIUS = 3.6 -- metres

local function inCircle(c: CourseDatabase.Circle, x: number, z: number): boolean
	local dx, dz = x - c.X, z - c.Z
	return dx * dx + dz * dz <= c.R * c.R
end

-- Distance from (x, z) to the segment A-B, compared with the half-width.
local function inCapsule(c: CourseDatabase.Capsule, x: number, z: number): boolean
	local abx, abz = c.BX - c.AX, c.BZ - c.AZ
	local lengthSq = abx * abx + abz * abz
	local t = 0
	if lengthSq > 0 then
		-- Project onto the segment, clamped so the ends are rounded caps.
		t = math.clamp(((x - c.AX) * abx + (z - c.AZ) * abz) / lengthSq, 0, 1)
	end
	local px, pz = c.AX + abx * t, c.AZ + abz * t
	local dx, dz = x - px, z - pz
	return dx * dx + dz * dz <= c.HalfWidth * c.HalfWidth
end

function CourseTerrain.lieAt(hole: CourseDatabase.HoleDef, x: number, z: number): Types.LieId
	for _, water in hole.Water do
		if inCircle(water, x, z) then
			return "Water"
		end
	end
	for _, green in hole.Greens do
		if inCircle(green, x, z) then
			return "Green"
		end
	end
	for _, bunker in hole.Bunkers do
		if inCircle(bunker, x, z) then
			return "Sand"
		end
	end
	-- The tee box wins over fairway: par 3s often start on a strip of fairway.
	local dx, dz = x - hole.Tee.X, z - hole.Tee.Z
	if dx * dx + dz * dz <= TEE_BOX_RADIUS * TEE_BOX_RADIUS then
		return "Tee"
	end
	for _, fairway in hole.Fairway do
		if inCapsule(fairway, x, z) then
			return "Fairway"
		end
	end
	return "Rough"
end

function CourseTerrain.inBounds(hole: CourseDatabase.HoleDef, x: number, z: number): boolean
	local b = hole.Bounds
	return x >= b.MinX and x <= b.MaxX and z >= b.MinZ and z <= b.MaxZ
end

-- Terrain in the hole frame.
function CourseTerrain.forHole(hole: CourseDatabase.HoleDef): ShotPhysics.Terrain
	return {
		heightAt = function(_x: number, _z: number): number
			return 0
		end,
		lieAt = function(x: number, z: number): Types.LieId
			return CourseTerrain.lieAt(hole, x, z)
		end,
		slopeAt = function(x: number, z: number): (number, number)
			if CourseTerrain.lieAt(hole, x, z) == "Green" then
				return hole.GreenSlope.X, hole.GreenSlope.Z
			end
			return 0, 0
		end,
	}
end

-- The same terrain seen from a shot at (ox, oz) aimed along `headingRad`.
function CourseTerrain.shotFrame(terrain: ShotPhysics.Terrain, ox: number, oz: number, headingRad: number): ShotPhysics.Terrain
	local dx, dz = math.cos(headingRad), math.sin(headingRad)
	local rx, rz = -dz, dx
	return {
		heightAt = function(xl: number, zl: number): number
			return terrain.heightAt(ox + xl * dx + zl * rx, oz + xl * dz + zl * rz)
		end,
		lieAt = function(xl: number, zl: number): Types.LieId
			return terrain.lieAt(ox + xl * dx + zl * rx, oz + xl * dz + zl * rz)
		end,
		slopeAt = function(xl: number, zl: number): (number, number)
			local gx, gz = terrain.slopeAt(ox + xl * dx + zl * rx, oz + xl * dz + zl * rz)
			return gx * dx + gz * dz, gx * rx + gz * rz
		end,
	}
end

-- Shot-frame (xl, zl) -> hole frame position.
function CourseTerrain.toHole(ox: number, oz: number, headingRad: number, xl: number, zl: number): (number, number)
	local dx, dz = math.cos(headingRad), math.sin(headingRad)
	return ox + xl * dx - zl * dz, oz + xl * dz + zl * dx
end

-- Hole-frame point -> shot-frame coordinates (used to place the cup).
function CourseTerrain.toShot(ox: number, oz: number, headingRad: number, x: number, z: number): (number, number)
	local dx, dz = math.cos(headingRad), math.sin(headingRad)
	local px, pz = x - ox, z - oz
	return px * dx + pz * dz, -px * dz + pz * dx
end

return CourseTerrain
