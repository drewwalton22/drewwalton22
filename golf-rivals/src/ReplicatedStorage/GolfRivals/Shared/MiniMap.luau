--!strict
--[[
	MiniMap.luau  (ReplicatedStorage.GolfRivals.Shared)

	Top-down hole map for the HUD (mockup panel 9, right edge): tee at the bottom,
	pin toward the top, whatever direction the hole really runs. The UI draws the
	returned shapes as frames; this module only does the geometry.

	    u = unit(pin - tee)               "up" on the map
	    r = (-u.z, u.x)                   "right" on the map
	    forward a = (p - tee) . u ,  sideways b = (p - tee) . r
	    screen x = originX + b * scale ,  screen y = originY - a * scale

	The scale fits the hole's playable bounds into the box with a padding margin.
	Shapes are listed back-to-front so drawing in order layers them correctly.
]]

local Types = require(script.Parent.Types)
local CourseDatabase = require(script.Parent.CourseDatabase)

export type Circle = { Kind: "Circle", Lie: Types.LieId, X: number, Y: number, R: number }
export type Capsule = { Kind: "Capsule", Lie: Types.LieId, X1: number, Y1: number, X2: number, Y2: number, Width: number }
export type Shape = Circle | Capsule

export type Layout = {
	Width: number,
	Height: number,
	Shapes: { Shape },
	Outline: { { number } }, -- 4 corners {x, y} of the playable bounds
	Tee: { number },
	Pin: { number },
	project: (x: number, z: number) -> (number, number),
}

local MiniMap = {}

function MiniMap.layout(hole: CourseDatabase.HoleDef, width: number, height: number, padding: number?): Layout
	local pad = padding or 6
	local ux, uz = hole.Pin.X - hole.Tee.X, hole.Pin.Z - hole.Tee.Z
	local length = math.sqrt(ux * ux + uz * uz)
	ux, uz = ux / length, uz / length
	local rx, rz = -uz, ux

	local function axes(x: number, z: number): (number, number)
		local px, pz = x - hole.Tee.X, z - hole.Tee.Z
		return px * ux + pz * uz, px * rx + pz * rz -- (forward a, sideways b)
	end

	-- Extent of the playable rectangle in map axes.
	local b = hole.Bounds
	local minA: number, maxA: number, minB: number, maxB: number = 1e18, -1e18, 1e18, -1e18
	local corners: { { number } } = { { b.MinX, b.MinZ }, { b.MinX, b.MaxZ }, { b.MaxX, b.MinZ }, { b.MaxX, b.MaxZ } }
	for _, corner in corners do
		local a, s = axes(corner[1], corner[2])
		if a < minA then
			minA = a
		end
		if a > maxA then
			maxA = a
		end
		if s < minB then
			minB = s
		end
		if s > maxB then
			maxB = s
		end
	end
	local scale = math.min((width - 2 * pad) / (maxB - minB), (height - 2 * pad) / (maxA - minA))
	-- Centre the fitted map inside the box.
	local originX = width / 2 - (minB + maxB) / 2 * scale
	local originY = height / 2 + (minA + maxA) / 2 * scale

	local function project(x: number, z: number): (number, number)
		local a, s = axes(x, z)
		return originX + s * scale, originY - a * scale
	end

	local shapes: { Shape } = {}
	for _, fairway in hole.Fairway do
		local x1, y1 = project(fairway.AX, fairway.AZ)
		local x2, y2 = project(fairway.BX, fairway.BZ)
		local capsule: Capsule = { Kind = "Capsule", Lie = "Fairway", X1 = x1, Y1 = y1, X2 = x2, Y2 = y2, Width = fairway.HalfWidth * 2 * scale }
		table.insert(shapes, capsule)
	end
	local function addCircles(circles: { CourseDatabase.Circle }, lie: Types.LieId)
		for _, c in circles do
			local x, y = project(c.X, c.Z)
			local circle: Circle = { Kind = "Circle", Lie = lie, X = x, Y = y, R = c.R * scale }
			table.insert(shapes, circle)
		end
	end
	addCircles(hole.Bunkers, "Sand")
	addCircles(hole.Greens, "Green")
	addCircles(hole.Water, "Water")

	local outline: { { number } } = {}
	for _, corner in { { b.MinX, b.MinZ }, { b.MinX, b.MaxZ }, { b.MaxX, b.MaxZ }, { b.MaxX, b.MinZ } } do
		local x, y = project(corner[1], corner[2])
		table.insert(outline, { x, y })
	end
	local teeX, teeY = project(hole.Tee.X, hole.Tee.Z)
	local pinX, pinY = project(hole.Pin.X, hole.Pin.Z)
	return {
		Width = width, Height = height, Shapes = shapes, Outline = outline,
		Tee = { teeX, teeY }, Pin = { pinX, pinY }, project = project,
	}
end

return MiniMap
