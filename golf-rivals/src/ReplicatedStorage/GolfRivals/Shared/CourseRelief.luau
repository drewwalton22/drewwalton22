--!strict
--[[
	CourseRelief.luau  (ReplicatedStorage.GolfRivals.Shared)

	The 3D SHAPE of a hole: a height field h(x, z) in metres (hole frame), built
	from the hole's Relief (CourseData) and its 2D features. Every system reads
	the same numbers, so what you see is what the ball rolls on:

	    ShotPhysics / bots      CourseTerrain.forHole -> heightAt / slopeAt
	    Smooth Terrain sculptor TerrainPlan.column -> TerrainBuilder (WriteVoxels)
	    client heights          the sculpted terrain (raycast)

	LAYERS (in order)
	  1. play-line profile   the hole's elevation profile (tee -> green) laid along
	                         the line of play (tee, each fairway corner, pin); every
	                         point takes the elevation of its nearest point on that
	                         line, smoothly interpolated between control points
	  2. rolling mounds      two crossed sine waves (Undulation, Wavelength), faded
	                         out around the tee box and the green
	  3. framing hills       outside the bounds the ground rises (up to FRAME_RISE)
	                         so every hole sits in its own valley
	  4. sand bunkers        bowls BUNKER_DEPTH deep
	  5. water               the ground drops WATER_DEPTH below a water level set
	                         just under the LOWEST point of the pond's rim, so a pond
	                         never overflows; the water surface is what a ball hits
	  6. tee box             a flat plateau TeeRaise above the ground (elevated tee)
	  7. greens              a tilted plane (GreenSlope) GreenRaise above the
	                         surroundings, blended down over GREEN_BANK metres
	                         (banked / raised greens; also builds island greens)

	SLOPES: the gradient (dh/dx, dh/dz) - the physics uses it for the landing
	normal and for gravity along the ground, so balls run away downhill, check up
	uphill and break on tilted greens.

	PERFORMANCE: heights are sampled on a 1 m grid on demand and bilinearly
	interpolated (cached per hole), so a bot planning dozens of shots stays cheap.
	The grid is exact on the green (a plane is bilinear-exact).
]]

local CourseDatabase = require(script.Parent.CourseDatabase)

local CourseRelief = {}

CourseRelief.TEE_RADIUS = 3.6 -- metres (the tee box)
CourseRelief.TEE_SKIRT = 6 -- metres over which the tee plateau blends down
CourseRelief.GREEN_BANK = 7 -- metres over which a raised green blends down
CourseRelief.BUNKER_DEPTH = 0.55
CourseRelief.WATER_DEPTH = 1.3
CourseRelief.WATER_FREEBOARD = 0.35 -- water level below the pond's lowest rim
CourseRelief.FRAME_RISE = 7 -- metres the hills outside the bounds rise
CourseRelief.FRAME_WIDTH = 45 -- metres over which they rise
CourseRelief.GRID = 1.0 -- metres between cached samples

type HoleDef = CourseDatabase.HoleDef

type Cache = {
	Line: { { number } }, -- play line points {x, z}
	Cum: { number }, -- cumulative length at each point
	Total: number,
	WaterLevels: { number },
	Grid: { [number]: number },
}

local caches: { [HoleDef]: Cache } = setmetatable({}, { __mode = "k" }) :: any

local function smooth(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- The line of play: tee, the far end of each fairway segment (in order), pin.
local function playLine(hole: HoleDef): { { number } }
	local points = { { hole.Tee.X, hole.Tee.Z } }
	for _, fairway in hole.Fairway do
		local last = points[#points]
		local dx, dz = fairway.BX - last[1], fairway.BZ - last[2]
		if dx * dx + dz * dz > 1 then
			table.insert(points, { fairway.BX, fairway.BZ })
		end
	end
	local last = points[#points]
	local dx, dz = hole.Pin.X - last[1], hole.Pin.Z - last[2]
	if dx * dx + dz * dz > 1 then
		table.insert(points, { hole.Pin.X, hole.Pin.Z })
	else
		points[#points] = { hole.Pin.X, hole.Pin.Z }
	end
	if #points == 1 then
		table.insert(points, { hole.Pin.X + 1, hole.Pin.Z })
	end
	return points
end

-- Fraction (0..1) along the play line of the point nearest to (x, z).
local function along(cache: Cache, x: number, z: number): number
	local bestDistSq, bestS = math.huge, 0
	local line = cache.Line
	for i = 1, #line - 1 do
		local ax, az = line[i][1], line[i][2]
		local bx, bz = line[i + 1][1], line[i + 1][2]
		local abx, abz = bx - ax, bz - az
		local lengthSq = abx * abx + abz * abz
		local t = if lengthSq > 0 then math.clamp(((x - ax) * abx + (z - az) * abz) / lengthSq, 0, 1) else 0
		local px, pz = ax + abx * t, az + abz * t
		local d = (x - px) ^ 2 + (z - pz) ^ 2
		if d < bestDistSq then
			bestDistSq = d
			bestS = (cache.Cum[i] + t * math.sqrt(lengthSq)) / cache.Total
		end
	end
	return bestS
end

-- Profile elevation at fraction s, smoothly interpolated between control points.
local function profileAt(relief: CourseDatabase.Relief, s: number): number
	local profile = relief.Profile
	local n = #profile
	if n == 1 then
		return profile[1]
	end
	local u = math.clamp(s, 0, 1) * (n - 1)
	local i = math.min(math.floor(u), n - 2)
	return lerp(profile[i + 1], profile[i + 2], smooth(u - i))
end

local function phase(seed: number, k: number): number
	return (seed * 12.9898 + k * 78.233) % (2 * math.pi)
end

local function outsideDistance(b: CourseDatabase.Bounds, x: number, z: number): number
	local dx = math.max(b.MinX - x, 0, x - b.MaxX)
	local dz = math.max(b.MinZ - z, 0, z - b.MaxZ)
	return math.sqrt(dx * dx + dz * dz)
end

-- Layers 1-3: the natural ground (no tee, green, bunker or water shaping).
local function natural(hole: HoleDef, cache: Cache, relief: CourseDatabase.Relief, x: number, z: number): number
	local h = profileAt(relief, along(cache, x, z))
	if relief.Undulation > 0 then
		local w = 2 * math.pi / math.max(relief.Wavelength, 1)
		local seed = relief.Seed
		local wave = 0.6 * math.sin(x * w + phase(seed, 1)) * math.sin(z * w * 1.25 + phase(seed, 2))
			+ 0.4 * math.sin((0.7 * x - 0.5 * z) * w * 0.77 + phase(seed, 3))
		-- Fade the mounds out around the tee box and the green.
		local tee = math.sqrt((x - hole.Tee.X) ^ 2 + (z - hole.Tee.Z) ^ 2)
		local fade = smooth((tee - CourseRelief.TEE_RADIUS - CourseRelief.TEE_SKIRT) / 12)
		for _, green in hole.Greens do
			local d = math.sqrt((x - green.X) ^ 2 + (z - green.Z) ^ 2) - green.R
			fade = math.min(fade, smooth((d - CourseRelief.GREEN_BANK) / 14))
		end
		h += relief.Undulation * wave * fade
	end
	local outside = outsideDistance(hole.Bounds, x, z)
	if outside > 0 then
		h += CourseRelief.FRAME_RISE * smooth(outside / CourseRelief.FRAME_WIDTH)
	end
	return h
end

local function cacheFor(hole: HoleDef): Cache
	local existing = caches[hole]
	if existing then
		return existing
	end
	local line = playLine(hole)
	local cum = { 0 }
	for i = 2, #line do
		cum[i] = cum[i - 1] + math.sqrt((line[i][1] - line[i - 1][1]) ^ 2 + (line[i][2] - line[i - 1][2]) ^ 2)
	end
	local cache: Cache = { Line = line, Cum = cum, Total = math.max(cum[#cum], 1e-6), WaterLevels = {}, Grid = {} }
	-- Each pond's level: just below the lowest natural ground on its rim.
	local relief = hole.Relief
	for i, water in hole.Water do
		local lowest = math.huge
		if relief then
			for k = 0, 23 do
				local a = k / 24 * 2 * math.pi
				lowest = math.min(lowest, natural(hole, cache, relief, water.X + math.cos(a) * water.R, water.Z + math.sin(a) * water.R))
			end
		else
			lowest = 0
		end
		cache.WaterLevels[i] = lowest - CourseRelief.WATER_FREEBOARD
	end
	caches[hole] = cache
	return cache
end

-- Height of the tee box top (metres).
function CourseRelief.teeTop(hole: HoleDef): number
	local relief = hole.Relief
	if relief == nil then
		return 0
	end
	return relief.Profile[1] + relief.TeeRaise
end

-- The green's tilted plane height at (x, z) for green `index`.
function CourseRelief.greenPlane(hole: HoleDef, index: number, x: number, z: number): number
	local relief = hole.Relief
	local green = hole.Greens[index]
	if relief == nil or green == nil then
		return 0
	end
	local cache = cacheFor(hole)
	local centre = profileAt(relief, along(cache, green.X, green.Z)) + relief.GreenRaise
	return centre + hole.GreenSlope.X * (x - green.X) + hole.GreenSlope.Z * (z - green.Z)
end

-- Water level of pond `index` (metres), or nil.
function CourseRelief.waterLevel(hole: HoleDef, index: number): number?
	if hole.Water[index] == nil then
		return nil
	end
	return cacheFor(hole).WaterLevels[index]
end

-- EXACT ground height (no grid), plus the water surface if (x, z) is open water.
function CourseRelief.exact(hole: HoleDef, x: number, z: number): (number, number?)
	local relief = hole.Relief
	if relief == nil then
		return 0, nil
	end
	local cache = cacheFor(hole)
	local h = natural(hole, cache, relief, x, z)

	-- 4. bunkers
	for _, bunker in hole.Bunkers do
		local d = math.sqrt((x - bunker.X) ^ 2 + (z - bunker.Z) ^ 2)
		if d < bunker.R then
			local u = d / bunker.R
			h -= CourseRelief.BUNKER_DEPTH * (1 - u * u)
		end
	end

	-- 5. water: the bed drops below the pond's level.
	local waterTop: number? = nil
	for i, water in hole.Water do
		local d = math.sqrt((x - water.X) ^ 2 + (z - water.Z) ^ 2)
		if d < water.R then
			local level = cache.WaterLevels[i]
			local bed = level - CourseRelief.WATER_DEPTH
			local edge = math.min(water.R * 0.35, 6)
			local t = smooth((water.R - d) / edge)
			h = math.min(h, lerp(h, bed, t))
			waterTop = if waterTop then math.max(waterTop, level) else level
		end
	end

	-- 6. tee box plateau
	local teeTop = relief.Profile[1] + relief.TeeRaise
	local teeD = math.sqrt((x - hole.Tee.X) ^ 2 + (z - hole.Tee.Z) ^ 2)
	if teeD < CourseRelief.TEE_RADIUS + CourseRelief.TEE_SKIRT then
		h = lerp(teeTop, h, smooth((teeD - CourseRelief.TEE_RADIUS) / CourseRelief.TEE_SKIRT))
	end

	-- 7. greens: a tilted plane, banked down to the surroundings (or the water).
	for i, green in hole.Greens do
		local d = math.sqrt((x - green.X) ^ 2 + (z - green.Z) ^ 2)
		if d < green.R + CourseRelief.GREEN_BANK then
			local plane = CourseRelief.greenPlane(hole, i, x, z)
			h = lerp(plane, h, smooth((d - green.R) / CourseRelief.GREEN_BANK))
		end
	end

	if waterTop and h >= (waterTop :: number) then
		waterTop = nil -- dry ground inside the pond circle (an island's bank)
	end
	return h, waterTop
end

-- Grid-cached ground height (bilinear between 1 m samples).
local function sample(hole: HoleDef, cache: Cache, ix: number, iz: number): number
	local key = ix * 131072 + iz
	local h = cache.Grid[key]
	if h == nil then
		h = (CourseRelief.exact(hole, ix * CourseRelief.GRID, iz * CourseRelief.GRID))
		cache.Grid[key] = h
	end
	return h :: number
end

-- Ground height and gradient (dh/dx, dh/dz) at (x, z). Open water is NOT
-- included here - see surface().
function CourseRelief.ground(hole: HoleDef, x: number, z: number): (number, number, number)
	if hole.Relief == nil then
		return 0, 0, 0
	end
	local cache = cacheFor(hole)
	local g = CourseRelief.GRID
	local fx, fz = x / g, z / g
	local ix, iz = math.floor(fx), math.floor(fz)
	local tx, tz = fx - ix, fz - iz
	local h00 = sample(hole, cache, ix, iz)
	local h10 = sample(hole, cache, ix + 1, iz)
	local h01 = sample(hole, cache, ix, iz + 1)
	local h11 = sample(hole, cache, ix + 1, iz + 1)
	local h0 = lerp(h00, h10, tx)
	local h1 = lerp(h01, h11, tx)
	local gx = lerp(h10 - h00, h11 - h01, tz) / g
	local gz = (h1 - h0) / g
	return lerp(h0, h1, tz), gx, gz
end

-- Is (x, z) open water? Returns the water level if so.
function CourseRelief.waterAt(hole: HoleDef, x: number, z: number): number?
	if #hole.Water == 0 then
		return nil
	end
	local inside = false
	for _, water in hole.Water do
		if (x - water.X) ^ 2 + (z - water.Z) ^ 2 < water.R * water.R then
			inside = true
			break
		end
	end
	if not inside then
		return nil
	end
	if hole.Relief == nil then
		return 0
	end
	local _, top = CourseRelief.exact(hole, x, z)
	return top
end

-- What a ball meets at (x, z): the water surface over a pond, else the ground.
function CourseRelief.surface(hole: HoleDef, x: number, z: number): (number, number, number)
	local h, gx, gz = CourseRelief.ground(hole, x, z)
	if #hole.Water > 0 and hole.Relief then
		local level = CourseRelief.waterAt(hole, x, z)
		if level and level > h then
			return level, 0, 0
		end
	end
	return h, gx, gz
end

-- Lowest / highest ground over a rectangle (metres), sampled every `step` m.
function CourseRelief.range(hole: HoleDef, minX: number, maxX: number, minZ: number, maxZ: number, step: number): (number, number)
	local lo: number, hi: number = math.huge, -math.huge
	local x = minX
	while x <= maxX do
		local z = minZ
		while z <= maxZ do
			local h: number = (CourseRelief.ground(hole, x, z))
			lo, hi = math.min(lo, h), math.max(hi, h)
			z += step
		end
		x += step
	end
	return lo, hi
end

return CourseRelief
