--!strict
--[[
	DecorPlanner.luau  (ReplicatedStorage.GolfRivals.Shared)

	WHERE the MapDecorator puts foliage, rocks and grass patches around a hole's
	borders - pure and deterministic (seeded), so every server decorates a hole
	identically and tests can check the rules:

	  * only in the BORDER BAND: between BandInsideMeters inside the hole's bounds
	    and BandOutsideMeters outside it (never in the middle of the hole)
	  * never within ClearanceMeters of a fairway, green, tee, bunker or water
	  * count = min(MaxItems, band area x Density)
	  * kind picked by weight (Config.Decor.Kinds), random scale and yaw per item

	Output is in hole-frame metres; the MapDecorator raycasts for the ground height
	and clones a template / mesh / procedural stand-in for each item.
]]

local Config = require(script.Parent.Config)
local CourseDatabase = require(script.Parent.CourseDatabase)
local Prng = require(script.Parent.Prng)

export type Item = {
	Kind: string,
	X: number,
	Z: number,
	Scale: number,
	YawDeg: number,
}

export type Input = {
	Bounds: CourseDatabase.Bounds,
	Circles: { CourseDatabase.Circle }, -- keep-out circles (greens, bunkers, water, tee, pin)
	Capsules: { CourseDatabase.Capsule }, -- keep-out capsules (fairways)
	Seed: number,
}

local DecorPlanner = {}

local function distanceToCapsule(c: CourseDatabase.Capsule, x: number, z: number): number
	local abx, abz = c.BX - c.AX, c.BZ - c.AZ
	local lengthSq = abx * abx + abz * abz
	local t = if lengthSq > 0 then math.clamp(((x - c.AX) * abx + (z - c.AZ) * abz) / lengthSq, 0, 1) else 0
	local dx, dz = x - (c.AX + abx * t), z - (c.AZ + abz * t)
	return math.sqrt(dx * dx + dz * dz) - c.HalfWidth
end

-- Distance from (x, z) to the nearest keep-out feature's edge (<= 0 inside one).
function DecorPlanner.clearance(input: Input, x: number, z: number): number
	local best = math.huge
	for _, c in input.Circles do
		best = math.min(best, math.sqrt((x - c.X) ^ 2 + (z - c.Z) ^ 2) - c.R)
	end
	for _, c in input.Capsules do
		best = math.min(best, distanceToCapsule(c, x, z))
	end
	return best
end

-- True when (x, z) lies in the decoration band around the bounds.
function DecorPlanner.inBand(bounds: CourseDatabase.Bounds, x: number, z: number): boolean
	local cfg = Config.Decor
	local outside = x < bounds.MinX - cfg.BandOutsideMeters or x > bounds.MaxX + cfg.BandOutsideMeters
		or z < bounds.MinZ - cfg.BandOutsideMeters or z > bounds.MaxZ + cfg.BandOutsideMeters
	local deepInside = x > bounds.MinX + cfg.BandInsideMeters and x < bounds.MaxX - cfg.BandInsideMeters
		and z > bounds.MinZ + cfg.BandInsideMeters and z < bounds.MaxZ - cfg.BandInsideMeters
	return not outside and not deepInside
end

function DecorPlanner.plan(input: Input): { Item }
	local cfg = Config.Decor
	local b = input.Bounds
	local o, i = cfg.BandOutsideMeters, cfg.BandInsideMeters
	local outerArea = (b.MaxX - b.MinX + 2 * o) * (b.MaxZ - b.MinZ + 2 * o)
	local innerArea = math.max(0, b.MaxX - b.MinX - 2 * i) * math.max(0, b.MaxZ - b.MinZ - 2 * i)
	local target = math.min(cfg.MaxItems, math.floor((outerArea - innerArea) * cfg.Density))

	local totalWeight = 0
	for _, kind in cfg.Kinds do
		totalWeight += kind.Weight
	end

	local prng = Prng.new(input.Seed)
	local items: { Item } = {}
	local attempts = 0
	while #items < target and attempts < target * 30 do
		attempts += 1
		local x = b.MinX - o + prng.next() * (b.MaxX - b.MinX + 2 * o)
		local z = b.MinZ - o + prng.next() * (b.MaxZ - b.MinZ + 2 * o)
		if DecorPlanner.inBand(b, x, z) and DecorPlanner.clearance(input, x, z) >= cfg.ClearanceMeters then
			local pick = prng.next() * totalWeight
			local chosen = cfg.Kinds[#cfg.Kinds]
			for _, kind in cfg.Kinds do
				pick -= kind.Weight
				if pick <= 0 then
					chosen = kind
					break
				end
			end
			table.insert(items, {
				Kind = chosen.Kind,
				X = x,
				Z = z,
				Scale = chosen.MinScale + prng.next() * (chosen.MaxScale - chosen.MinScale),
				YawDeg = prng.next() * 360,
			})
		end
	end
	return items
end

-- Keep-out shapes of a generated hole.
function DecorPlanner.forHole(hole: CourseDatabase.HoleDef, seed: number): { Item }
	local circles: { CourseDatabase.Circle } = {}
	for _, list in { hole.Greens, hole.Bunkers, hole.Water } do
		for _, c in list do
			table.insert(circles, c)
		end
	end
	table.insert(circles, { X = hole.Tee.X, Z = hole.Tee.Z, R = 6 })
	table.insert(circles, { X = hole.Pin.X, Z = hole.Pin.Z, R = 4 })
	return DecorPlanner.plan({ Bounds = hole.Bounds, Circles = circles, Capsules = hole.Fairway, Seed = seed })
end

return DecorPlanner
