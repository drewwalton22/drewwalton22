--!strict
--[[
	LobbyLayout.luau  (ReplicatedStorage.GolfRivals.Shared)

	The 3D social hub ("THE LINKS", mockup panel 1) as pure part specs, in studs,
	centred on the origin with the ground surface at y = 0. The server's LobbyBuilder
	turns it into parts; this module only decides WHAT goes WHERE, so it is testable.

	WORLD  clubhouse to the north (-Z) facing the plaza (+Z); a stone plaza with a
	       fountain in the middle; stairs up to the porch; a big signboard on the
	       porch ("PLAY / COMPETE / UPGRADE / CUSTOMIZE"); a practice putting green
	       to the east; palm-style trees around the edge; lamps and benches.
	SPAWN  on the plaza, south of the fountain, looking at the clubhouse.

	SIGNS  Roblox draws a SurfaceGui on a part's Front face = local -Z. Rotating by
	       yaw about Y sends it to (-sin yaw, -cos yaw), so yaw 180 faces +Z (the
	       plaza). The tests check every sign faces the plaza centre.

	Uses CourseLayout.PartSpec so one factory builds both the course and the lobby.
]]

local CourseLayout = require(script.Parent.CourseLayout)
local Prng = require(script.Parent.Prng)
local Types = require(script.Parent.Types)

type PartSpec = CourseLayout.PartSpec

export type Sign = {
	Name: string,
	X: number, Y: number, Z: number,
	SX: number, SY: number,
	YawDeg: number,
	Lines: { string },
	Color: Types.RGB,
	TextColor: Types.RGB,
}

export type Light = {
	X: number, Y: number, Z: number,
	Range: number,
	Brightness: number,
	Color: Types.RGB,
}

export type Layout = {
	Parts: { PartSpec },
	Signs: { Sign },
	Lights: { Light },
	Spawn: { X: number, Y: number, Z: number },
}

local LobbyLayout = {}

LobbyLayout.PLAZA_RADIUS = 95

local function block(name: string, x: number, y: number, z: number, sx: number, sy: number, sz: number, color: Types.RGB, material: string, canCollide: boolean?, yaw: number?, transparency: number?): PartSpec
	return {
		Name = name, Shape = "Block", X = x, Y = y, Z = z, SX = sx, SY = sy, SZ = sz,
		YawDeg = yaw or 0, Color = color, Material = material, Transparency = transparency or 0, CanCollide = canCollide ~= false,
	}
end

-- Flat vertical-axis cylinder: SX = thickness, SY = SZ = diameter.
local function disc(name: string, x: number, topY: number, z: number, radius: number, thickness: number, color: Types.RGB, material: string, transparency: number?): PartSpec
	return {
		Name = name, Shape = "Disc", X = x, Y = topY - thickness / 2, Z = z, SX = thickness, SY = radius * 2, SZ = radius * 2,
		YawDeg = 0, Color = color, Material = material, Transparency = transparency or 0, CanCollide = true,
	}
end

local function ball(name: string, x: number, y: number, z: number, diameter: number, color: Types.RGB, material: string): PartSpec
	return {
		Name = name, Shape = "Ball", X = x, Y = y, Z = z, SX = diameter, SY = diameter, SZ = diameter,
		YawDeg = 0, Color = color, Material = material, Transparency = 0, CanCollide = false,
	}
end

function LobbyLayout.build(): Layout
	local parts: { PartSpec } = {}
	local signs: { Sign } = {}
	local lights: { Light } = {}

	-- Ground and plaza -------------------------------------------------------------------------------
	table.insert(parts, block("Ground", 0, -2, 0, 900, 4, 900, { 78, 128, 60 }, "Grass"))
	table.insert(parts, disc("Plaza", 0, 0.3, 40, LobbyLayout.PLAZA_RADIUS, 1, { 196, 188, 172 }, "Cobblestone"))
	table.insert(parts, disc("PlazaRing", 0, 0.45, 40, 30, 1, { 150, 142, 128 }, "Slate"))

	-- Fountain at the plaza centre.
	table.insert(parts, disc("FountainBasin", 0, 2.2, 40, 14, 2, { 170, 164, 150 }, "Concrete"))
	table.insert(parts, disc("FountainWater", 0, 2.5, 40, 12, 1, { 70, 150, 230 }, "Glass", 0.3))
	table.insert(parts, block("FountainSpout", 0, 6, 40, 2.5, 7, 2.5, { 190, 184, 170 }, "Concrete"))

	-- Clubhouse (north, facing +Z) ---------------------------------------------------------------------
	local houseZ = -150
	table.insert(parts, block("HouseBase", 0, 14, houseZ, 150, 28, 56, { 214, 198, 168 }, "Wood"))
	table.insert(parts, block("HouseRoof", 0, 30.5, houseZ + 6, 164, 5, 72, { 92, 62, 50 }, "Slate"))
	table.insert(parts, block("HouseWindows", 0, 14, houseZ + 28.5, 120, 12, 1, { 130, 190, 240 }, "Glass", false, 0, 0.35))
	table.insert(parts, block("HouseDoor", 0, 8, houseZ + 28.6, 14, 16, 1.2, { 80, 54, 40 }, "Wood", false))
	table.insert(parts, block("Porch", 0, 1.5, houseZ + 46, 150, 3, 36, { 190, 176, 152 }, "WoodPlanks"))
	for i, x in { -66, -22, 22, 66 } do
		table.insert(parts, block(`Column_{i}`, x, 14, houseZ + 62, 4, 28, 4, { 236, 230, 218 }, "Concrete"))
	end
	-- Stairs down from the porch to the plaza.
	for i = 1, 4 do
		table.insert(parts, block(`Step_{i}`, 0, (4 - i) * 0.75 + 0.4, houseZ + 62 + i * 4, 40, 1.5, 4, { 206, 198, 182 }, "Concrete"))
	end

	-- The big signboard on the porch (faces the plaza) ---------------------------------------------------------
	table.insert(signs, {
		Name = "MainSign", X = -50, Y = 14, Z = houseZ + 64.5, SX = 56, SY = 30, YawDeg = 180,
		Lines = { "PLAY", "COMPETE", "UPGRADE", "CUSTOMIZE" }, Color = { 26, 58, 40 }, TextColor = { 245, 245, 235 },
	})
	table.insert(signs, {
		Name = "TitleSign", X = 42, Y = 18, Z = houseZ + 64.5, SX = 62, SY = 22, YawDeg = 180,
		Lines = { "THE LINKS" }, Color = { 18, 34, 28 }, TextColor = { 255, 214, 90 },
	})
	table.insert(parts, block("MainSignPostL", -72, 7, houseZ + 64, 2, 14, 2, { 92, 62, 50 }, "Wood"))
	table.insert(parts, block("MainSignPostR", -28, 7, houseZ + 64, 2, 14, 2, { 92, 62, 50 }, "Wood"))

	-- Flag poles by the stairs -------------------------------------------------------------------------------------
	for i, x in { -30, 30 } do
		table.insert(parts, block(`FlagPole_{i}`, x, 18, houseZ + 74, 0.8, 36, 0.8, { 235, 235, 235 }, "Metal"))
		table.insert(parts, block(`Flag_{i}`, x + 4, 32, houseZ + 74, 8, 5, 0.3, { 230, 60, 60 }, "Fabric", false))
	end

	-- Practice putting green (east) ---------------------------------------------------------------------------------
	table.insert(parts, disc("PracticeGreen", 150, 0.35, 70, 30, 1, { 120, 200, 98 }, "Grass"))
	table.insert(parts, block("PracticePole", 150, 7, 70, 0.4, 14, 0.4, { 240, 240, 240 }, "Metal", false))
	table.insert(parts, block("PracticeFlag", 152.4, 12.5, 70, 4.8, 3, 0.2, { 230, 60, 60 }, "Fabric", false))

	-- Benches and lamps around the plaza ----------------------------------------------------------------------------------
	local benchRadius = 70
	for i = 0, 5 do
		local angle = math.rad(200 + i * 28)
		local bx, bz = math.cos(angle) * benchRadius, 40 + math.sin(angle) * benchRadius
		local yaw = math.deg(math.atan2(-(bx), -(bz - 40))) -- seat faces the fountain
		table.insert(parts, block(`Bench_{i}`, bx, 1.9, bz, 10, 1, 3, { 120, 84, 56 }, "WoodPlanks", true, yaw))
		table.insert(parts, block(`BenchBack_{i}`, bx, 3.4, bz, 10, 2.6, 0.6, { 100, 70, 48 }, "WoodPlanks", false, yaw))
	end
	for i = 0, 7 do
		local angle = math.rad(i * 45)
		local lx, lz = math.cos(angle) * 88, 40 + math.sin(angle) * 88
		table.insert(parts, block(`LampPole_{i}`, lx, 9, lz, 0.8, 18, 0.8, { 40, 40, 44 }, "Metal"))
		table.insert(parts, ball(`LampGlobe_{i}`, lx, 19, lz, 3, { 255, 226, 150 }, "Neon"))
		table.insert(lights, { X = lx, Y = 19, Z = lz, Range = 38, Brightness = 1.4, Color = { 255, 214, 140 } })
	end

	-- Palm-style trees around the edge (deterministic) ----------------------------------------------------------------------
	local prng = Prng.new(20260101)
	local planted = 0
	for _ = 1, 400 do
		if planted >= 60 then
			break
		end
		local angle = prng.next() * math.pi * 2
		local radius = 120 + prng.next() * 190
		local x, z = math.cos(angle) * radius, 40 + math.sin(angle) * radius
		-- Keep the clubhouse frontage, the stairs and the practice green clear.
		local nearHouse = z < -70 and math.abs(x) < 110
		local nearGreen = math.sqrt((x - 150) ^ 2 + (z - 70) ^ 2) < 45
		if not nearHouse and not nearGreen then
			planted += 1
			local height = 24 + prng.next() * 14
			table.insert(parts, block(`TreeTrunk_{planted}`, x, height / 2, z, 2.2, height, 2.2, { 130, 96, 62 }, "Wood", true, prng.next() * 360))
			for leaf = 1, 5 do
				local leafAngle = math.rad(leaf * 72)
				table.insert(parts, ball(`TreeLeaf_{planted}_{leaf}`, x + math.cos(leafAngle) * 5, height + 1 + (leaf % 2), z + math.sin(leafAngle) * 5, 9, { 54, 140 + math.floor(prng.next() * 40), 70 }, "Grass"))
			end
		end
	end

	return {
		Parts = parts,
		Signs = signs,
		Lights = lights,
		Spawn = { X = 0, Y = 4, Z = 100 },
	}
end

return LobbyLayout
