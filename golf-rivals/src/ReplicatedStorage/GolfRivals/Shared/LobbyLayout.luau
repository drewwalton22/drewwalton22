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
	       DRIVING RANGE to the west: a covered tee deck with four hitting bays and
	       five target greens downrange (positions from RangeRules, so the server's
	       payouts and the visible targets always agree).
	       AFK LOUNGE to the south-east: a cabana over a round deck; standing on
	       the deck earns coins over time (LobbyLayout.insideAfk is the server's
	       presence test).
	SPAWN  on the plaza, south of the fountain, looking at the clubhouse.

	SIGNS  Roblox draws a SurfaceGui on a part's Front face = local -Z. Rotating by
	       yaw about Y sends it to (-sin yaw, -cos yaw), so yaw 180 faces +Z (the
	       plaza). The tests check every sign faces the plaza centre.

	Uses CourseLayout.PartSpec so one factory builds both the course and the lobby.
]]

local Config = require(script.Parent.Config)
local CourseLayout = require(script.Parent.CourseLayout)
local Prng = require(script.Parent.Prng)
local RangeRules = require(script.Parent.RangeRules)
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

-- The AFK lounge deck (studs). Shared by the layout and the server's presence check.
LobbyLayout.AFK_LOUNGE = { X = 112, Z = 172, Radius = 20, MaxHeight = 14 }

-- The west range field (studs): ground extends to RANGE_FAR_X.
LobbyLayout.RANGE_FAR_X = -1180

function LobbyLayout.insideAfk(x: number, y: number, z: number): boolean
	local lounge = LobbyLayout.AFK_LOUNGE
	local dx, dz = x - lounge.X, z - lounge.Z
	return dx * dx + dz * dz <= lounge.Radius * lounge.Radius and y > -2 and y < lounge.MaxHeight
end

-- True when a world point is on the range field or tee deck (kept clear of trees).
function LobbyLayout.inRangeArea(x: number, z: number): boolean
	return x < -100 and math.abs(z - RangeRules.ORIGIN.Z) < 230
end

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

-- DRIVING RANGE (west) ---------------------------------------------------------------------------
function LobbyLayout.addRange(parts: { PartSpec }, signs: { Sign }, lights: { Light })
	local ox, oz = RangeRules.ORIGIN.X, RangeRules.ORIGIN.Z
	local farX = LobbyLayout.RANGE_FAR_X
	local fieldLength = -450 - farX -- beyond the main ground plate
	local halfWidth = RangeRules.HalfWidthYds * Config.Physics.YardsToMeters * CourseLayout.STUDS_PER_METER

	-- Ground beyond the plate, then the mown range strip from the tee line out.
	table.insert(parts, block("RangeGround", -450 - fieldLength / 2, -2, oz, fieldLength, 4, halfWidth * 2 + 120, { 74, 122, 58 }, "Grass"))
	table.insert(parts, block("RangeField", (ox + farX) / 2, 0.05, oz, ox - farX, 0.1, halfWidth * 2, { 98, 168, 74 }, "Grass", false))
	-- Distance stripes every 50 yards so players can read the range.
	for yards = 50, RangeRules.LengthYds, 50 do
		local wx = RangeRules.toWorld(yards * Config.Physics.YardsToMeters, 0)
		table.insert(parts, block(`RangeStripe_{yards}`, wx, 0.12, oz, 2, 0.1, halfWidth * 2, { 230, 236, 220 }, "SmoothPlastic", false))
	end

	-- Covered tee deck with the hitting bays.
	local deckBack = ox + 22
	table.insert(parts, block("RangeDeck", (ox + deckBack) / 2 + 2, 0.3, oz, deckBack - ox + 4, 0.6, 84, { 168, 132, 96 }, "WoodPlanks"))
	table.insert(parts, block("RangeRoof", ox + 12, 15, oz, 26, 1.2, 88, { 40, 56, 70 }, "Metal"))
	for i, z in { oz - 42, oz - 14, oz + 14, oz + 42 } do
		table.insert(parts, block(`RangeRoofPost_{i}`, ox + 22, 7.5, z, 1.4, 15, 1.4, { 230, 230, 230 }, "Metal"))
	end
	for _, bay in RangeRules.Bays do
		table.insert(parts, block(`RangeMat_{bay.Id}`, ox + 2, 0.7, bay.WorldZ, 9, 0.2, 9, { 52, 120, 64 }, "Fabric"))
		table.insert(parts, block(`RangeTee_{bay.Id}`, ox, 1.0, bay.WorldZ, 0.4, 0.6, 0.4, { 245, 245, 245 }, "SmoothPlastic", false))
		table.insert(signs, {
			Name = `RangeBaySign_{bay.Id}`, X = ox + 22.8, Y = 11, Z = bay.WorldZ, SX = 7, SY = 3, YawDeg = -90,
			Lines = { `BAY {bay.Id}` }, Color = { 18, 30, 44 }, TextColor = { 255, 214, 90 },
		})
	end
	-- Dividers between and either side of the bays (one more divider than bays).
	for i = 1, #RangeRules.Bays + 1 do
		local z = RangeRules.Bays[1].WorldZ - 8 + (i - 1) * 16
		table.insert(parts, block(`RangeDivider_{i}`, ox + 6, 3, z, 12, 5, 0.6, { 210, 214, 220 }, "SmoothPlastic"))
	end
	table.insert(signs, {
		Name = "RangeSign", X = ox + 26, Y = 22, Z = oz, SX = 44, SY = 10, YawDeg = -90,
		Lines = { "DRIVING RANGE", "LAND ON A GREEN · EARN COINS" }, Color = { 18, 40, 30 }, TextColor = { 245, 245, 235 },
	})
	table.insert(lights, { X = ox + 12, Y = 13, Z = oz, Range = 40, Brightness = 1.2, Color = { 255, 236, 200 } })

	-- Target greens with a bullseye, a flag in the target colour and a yardage board.
	local spm = CourseLayout.STUDS_PER_METER
	for _, target in RangeRules.Targets do
		local cx, cz = RangeRules.centreOf(target)
		local wx, wz = RangeRules.toWorld(cx, cz)
		local radius = target.RadiusYds * Config.Physics.YardsToMeters * spm
		table.insert(parts, disc(`RangeTarget_{target.Id}`, wx, 0.25, wz, radius, 0.3, { 120, 200, 98 }, "Grass"))
		table.insert(parts, disc(`RangeTargetRing_{target.Id}`, wx, 0.3, wz, radius / 3 + 0.8, 0.3, target.Color, "Neon"))
		table.insert(parts, disc(`RangeBullseye_{target.Id}`, wx, 0.35, wz, radius / 3, 0.3, { 150, 220, 120 }, "Grass"))
		table.insert(parts, block(`RangeFlagPole_{target.Id}`, wx, 9, wz, 0.5, 18, 0.5, { 245, 245, 245 }, "Metal", false))
		table.insert(parts, block(`RangeFlag_{target.Id}`, wx, 16, wz + 3, 0.3, 4, 6, target.Color, "Neon", false))
		table.insert(signs, {
			Name = `RangeYardage_{target.Id}`, X = wx + radius + 6, Y = 6, Z = wz, SX = 12, SY = 7, YawDeg = -90,
			Lines = { `{target.DistanceYds} YDS`, `{target.Coins} COINS` }, Color = { 16, 26, 36 }, TextColor = target.Color,
		})
	end
end

-- AFK LOUNGE (south-east) ---------------------------------------------------------------------------
function LobbyLayout.addAfkLounge(parts: { PartSpec }, signs: { Sign }, lights: { Light })
	local lounge = LobbyLayout.AFK_LOUNGE
	table.insert(parts, disc("AfkDeck", lounge.X, 0.6, lounge.Z, lounge.Radius, 1.2, { 196, 160, 116 }, "WoodPlanks"))
	table.insert(parts, disc("AfkRing", lounge.X, 0.65, lounge.Z, lounge.Radius + 1, 1.2, { 120, 220, 255 }, "Neon"))
	table.insert(parts, disc("AfkDeckTop", lounge.X, 0.7, lounge.Z, lounge.Radius, 1.2, { 196, 160, 116 }, "WoodPlanks"))
	for i = 0, 5 do
		local angle = math.rad(i * 60)
		local px, pz = lounge.X + math.cos(angle) * (lounge.Radius - 2), lounge.Z + math.sin(angle) * (lounge.Radius - 2)
		table.insert(parts, block(`AfkPost_{i}`, px, 7, pz, 1.2, 14, 1.2, { 120, 84, 56 }, "Wood"))
	end
	table.insert(parts, disc("AfkRoof", lounge.X, 15, lounge.Z, lounge.Radius + 3, 1.4, { 220, 196, 140 }, "Fabric"))
	for i = 0, 3 do
		local angle = math.rad(45 + i * 90)
		local bx, bz = lounge.X + math.cos(angle) * 9, lounge.Z + math.sin(angle) * 9
		local yaw = math.deg(math.atan2(-(bx - lounge.X), -(bz - lounge.Z)))
		table.insert(parts, block(`AfkLounger_{i}`, bx, 1.8, bz, 4, 0.8, 9, { 240, 240, 236 }, "Fabric", true, yaw))
	end
	-- Sign on the side facing the plaza (the plaza centre is north-west of the lounge).
	local toPlazaX, toPlazaZ = 0 - lounge.X, 40 - lounge.Z
	local length = math.sqrt(toPlazaX * toPlazaX + toPlazaZ * toPlazaZ)
	local sx, sz = lounge.X + toPlazaX / length * (lounge.Radius + 4), lounge.Z + toPlazaZ / length * (lounge.Radius + 4)
	-- Front face (-sin yaw, -cos yaw) must point at the plaza.
	local yaw = math.deg(math.atan2(-toPlazaX, -toPlazaZ))
	table.insert(signs, {
		Name = "AfkSign", X = sx, Y = 9, Z = sz, SX = 24, SY = 8, YawDeg = yaw,
		Lines = { "AFK LOUNGE", `+{Config.Afk.CoinsPerTick} COINS EVERY MINUTE` }, Color = { 16, 40, 56 }, TextColor = { 120, 220, 255 },
	})
	table.insert(lights, { X = lounge.X, Y = 12, Z = lounge.Z, Range = 30, Brightness = 1.3, Color = { 160, 220, 255 } })
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
		local lounge = LobbyLayout.AFK_LOUNGE
		local nearLounge = math.sqrt((x - lounge.X) ^ 2 + (z - lounge.Z) ^ 2) < lounge.Radius + 16
		if not nearHouse and not nearGreen and not nearLounge and not LobbyLayout.inRangeArea(x, z) then
			planted += 1
			local height = 24 + prng.next() * 14
			table.insert(parts, block(`TreeTrunk_{planted}`, x, height / 2, z, 2.2, height, 2.2, { 130, 96, 62 }, "Wood", true, prng.next() * 360))
			for leaf = 1, 5 do
				local leafAngle = math.rad(leaf * 72)
				table.insert(parts, ball(`TreeLeaf_{planted}_{leaf}`, x + math.cos(leafAngle) * 5, height + 1 + (leaf % 2), z + math.sin(leafAngle) * 5, 9, { 54, 140 + math.floor(prng.next() * 40), 70 }, "Grass"))
			end
		end
	end

	LobbyLayout.addRange(parts, signs, lights)
	LobbyLayout.addAfkLounge(parts, signs, lights)

	return {
		Parts = parts,
		Signs = signs,
		Lights = lights,
		Spawn = { X = 0, Y = 4, Z = 100 },
	}
end

return LobbyLayout
