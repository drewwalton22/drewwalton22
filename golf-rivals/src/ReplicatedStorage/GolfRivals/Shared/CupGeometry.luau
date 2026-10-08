--!strict
--[[
	CupGeometry.luau  (ReplicatedStorage.GolfRivals.Shared)

	The cup, as pure maths (tested offline in tools/verify_features.luau). Server
	CupBuilder and Client BallAnimator both use it, so the pocket that is built and
	the ball that drops into it always agree.

	  RADIUS / DEPTH        the pocket: CourseLayout.CUP_DIAMETER wide,
	                        TerrainPlan.CUP_DEPTH deep (deeper than the ball)
	  FLOOR                 top of the dark bottom disc, above the pocket's floor
	  restDepth()           how far the ball's CENTRE ends below the green surface
	                        when it lies in the cup (its top is below the surface)
	  restOffset()          how far from the cup centre it lies: against the wall,
	                        clear of the flagstick
	  dropAt(t, ...)        the holed ball's path: from where the physics caught it
	                        it keeps travelling toward the far wall while it falls,
	                        lands on the bottom and rattles once
	  circle / annulus      the green's turf as triangles with a REAL HOLE in it
	                        (no CSG): a polygon around the cup zipped to the green's
	                        outline, every triangle wound the same way, areas adding
	                        up to (green - cup) - so no gaps and no overlaps
	  ring                  the fringe: triangles between two concentric polygons

	Units are studs. Angles are radians. Vec2 = { X, Z }.
]]

local CourseLayout = require(script.Parent.CourseLayout)
local TerrainPlan = require(script.Parent.TerrainPlan)

export type Vec2 = { X: number, Z: number }
export type Triangle = { Vec2 }

local CupGeometry = {}

CupGeometry.RADIUS = CourseLayout.CUP_DIAMETER / 2
CupGeometry.DEPTH = TerrainPlan.CUP_DEPTH
CupGeometry.BALL_RADIUS = CourseLayout.BALL_DIAMETER / 2
CupGeometry.FLOOR = 0.085 -- the bottom disc's top, above the pocket floor
CupGeometry.POLE_RADIUS = 0.07 -- the flagstick (PinPole is 0.14 wide)
CupGeometry.RIM_WIDTH = 0.07 -- the white liner showing at the top of the cup
CupGeometry.RIM_HEIGHT = 0.12
CupGeometry.RIM_RAISE = 0.015 -- the rim's top sits this far above the turf (always visible)
CupGeometry.SEGMENTS = 20 -- wall / rim planks around the pocket
CupGeometry.HOLE_SIDES = 24 -- sides of the hole in the turf
CupGeometry.DROP_GRAVITY = 40 -- studs/s^2: a little slower than real so you see it drop
CupGeometry.RATTLE_SECONDS = 0.16
CupGeometry.RATTLE_HEIGHT = 0.07

function CupGeometry.restDepth(): number
	return CupGeometry.DEPTH - CupGeometry.FLOOR - CupGeometry.BALL_RADIUS
end

function CupGeometry.restOffset(): number
	return CupGeometry.RADIUS - CupGeometry.BALL_RADIUS - 0.03
end

-- ---------------------------------------------------------------------------
-- The drop. `entry` = the ball's centre relative to the cup centre when the
-- physics holed it, `velocity` its horizontal velocity (studs/s), `lift` the
-- centre's height above the turf while rolling. Returns the centre relative to
-- the cup centre ON THE SURFACE (y = 0 is the turf) and whether it has settled.
-- ---------------------------------------------------------------------------
export type Drop = { X: number, Z: number, Y: number, Done: boolean }

local function restSide(entryX: number, entryZ: number, velX: number, velZ: number): (number, number)
	local speed = math.sqrt(velX * velX + velZ * velZ)
	if speed > 0.05 then
		return velX / speed, velZ / speed -- it carries on to the far wall
	end
	local d = math.sqrt(entryX * entryX + entryZ * entryZ)
	if d > 1e-3 then
		return entryX / d, entryZ / d -- it trickles in over the near edge
	end
	return 1, 0
end

function CupGeometry.restPoint(entryX: number, entryZ: number, velX: number, velZ: number): (number, number)
	local sx, sz = restSide(entryX, entryZ, velX, velZ)
	local r = CupGeometry.restOffset()
	return sx * r, sz * r
end

function CupGeometry.fallSeconds(lift: number): number
	return math.sqrt(2 * (lift + CupGeometry.restDepth()) / CupGeometry.DROP_GRAVITY)
end

function CupGeometry.dropAt(t: number, entryX: number, entryZ: number, velX: number, velZ: number, lift: number): Drop
	local fall = CupGeometry.fallSeconds(lift)
	local restX, restZ = CupGeometry.restPoint(entryX, entryZ, velX, velZ)
	if t >= fall + CupGeometry.RATTLE_SECONDS then
		return { X = restX, Z = restZ, Y = -CupGeometry.restDepth(), Done = true }
	end
	if t >= fall then
		-- One small rattle on the bottom.
		local u = (t - fall) / CupGeometry.RATTLE_SECONDS
		return { X = restX, Z = restZ, Y = -CupGeometry.restDepth() + CupGeometry.RATTLE_HEIGHT * math.sin(math.pi * u), Done = false }
	end
	local u = t / fall
	local ease = 1 - (1 - u) * (1 - u) -- keeps its speed at first, then meets the wall
	return {
		X = entryX + (restX - entryX) * ease,
		Z = entryZ + (restZ - entryZ) * ease,
		Y = lift - 0.5 * CupGeometry.DROP_GRAVITY * t * t,
		Done = false,
	}
end

-- ---------------------------------------------------------------------------
-- Turf triangulation
-- ---------------------------------------------------------------------------

-- `n` points on a circle; `circumscribe` pushes them out so the polygon covers
-- the whole circle (no sliver of what's underneath shows at the edge).
function CupGeometry.circle(cx: number, cz: number, radius: number, n: number, circumscribe: boolean?): { Vec2 }
	local r = if circumscribe then radius / math.cos(math.pi / n) else radius
	local points: { Vec2 } = {}
	for i = 0, n - 1 do
		local a = -math.pi + (i + 0.5) * 2 * math.pi / n
		table.insert(points, { X = cx + math.cos(a) * r, Z = cz + math.sin(a) * r })
	end
	return points
end

local function cross(a: Vec2, b: Vec2, c: Vec2): number
	return (b.X - a.X) * (c.Z - a.Z) - (b.Z - a.Z) * (c.X - a.X)
end

function CupGeometry.area(t: Triangle): number
	return cross(t[1], t[2], t[3]) / 2
end

function CupGeometry.polygonArea(points: { Vec2 }): number
	local sum = 0
	for i, p in points do
		local q = points[i % #points + 1]
		sum += p.X * q.Z - q.X * p.Z
	end
	return math.abs(sum) / 2
end

-- Points sorted by angle around (cx, cz), with their unwrapped angles.
local function byAngle(points: { Vec2 }, cx: number, cz: number): ({ Vec2 }, { number })
	type Entry = { P: Vec2, A: number }
	local order: { Entry } = {}
	for _, p in points do
		table.insert(order, { P = p, A = math.atan2(p.Z - cz, p.X - cx) })
	end
	table.sort(order, function(a: Entry, b: Entry): boolean
		return a.A < b.A
	end)
	local sorted: { Vec2 } = {}
	local angles: { number } = {}
	for _, o in order do
		table.insert(sorted, o.P)
		table.insert(angles, o.A)
	end
	return sorted, angles
end

-- The region between `inner` (around the cup at cx, cz) and `outer` (the green's
-- outline, which must contain the cup), as triangles. Both polygons are walked
-- in angle order around the cup and "zipped": each step adds the triangle that
-- advances whichever side's next vertex comes first.
function CupGeometry.annulus(inner: { Vec2 }, outer: { Vec2 }, cx: number, cz: number): { Triangle }
	local p, pa = byAngle(inner, cx, cz)
	local q, qa = byAngle(outer, cx, cz)
	local m, n = #p, #q
	local triangles: { Triangle } = {}
	local i, j = 1, 1
	while i <= m or j <= n do
		local nextP = if i <= m then (if i < m then pa[i + 1] else pa[1] + 2 * math.pi) else math.huge
		local nextQ = if j <= n then (if j < n then qa[j + 1] else qa[1] + 2 * math.pi) else math.huge
		local pi, qj = p[(i - 1) % m + 1], q[(j - 1) % n + 1]
		if nextP <= nextQ then
			table.insert(triangles, { pi, p[i % m + 1], qj })
			i += 1
		else
			table.insert(triangles, { pi, q[j % n + 1], qj })
			j += 1
		end
	end
	return triangles
end

-- Triangles between two polygons with the same number of points (index-matched),
-- e.g. the fringe ring between the green's outline and the fringe's.
function CupGeometry.ring(inner: { Vec2 }, outer: { Vec2 }): { Triangle }
	local triangles: { Triangle } = {}
	local n = #inner
	for i = 1, n do
		local k = i % n + 1
		table.insert(triangles, { inner[i], inner[k], outer[k] })
		table.insert(triangles, { inner[i], outer[k], outer[i] })
	end
	return triangles
end

return CupGeometry
