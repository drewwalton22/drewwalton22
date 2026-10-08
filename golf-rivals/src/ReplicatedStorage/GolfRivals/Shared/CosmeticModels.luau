--!strict
--[[
	CosmeticModels.luau  (ReplicatedStorage.GolfRivals.Shared)

	BLUEPRINTS for the code-built 3D cosmetics (pure data + maths, tested offline).
	Client/Golf/CosmeticBuilder turns these into Parts; nothing here touches
	Instances, so tools/verify_features.luau can check the shapes.

	CLUB FRAME (studs): the grip is at the origin, the shaft runs down -Y to the
	hosel at Y = -Length, +X points at the target (the clubface looks along +X)
	and +Z points to the toe (away from the golfer). The "Sole" point is on the
	ground just behind the bottom of the face: GolferRig rests it on the ground a
	ball's width behind the ball, so the face meets the ball.

	Every club category has its own head:
	  Driver       big, deep rounded head (ellipsoid), shallow face, sole plate
	  FairwayWood  smaller and flatter wood
	  LongIron     thin blade, small cavity, little loft
	  ShortIron    taller blade, bigger cavity, more loft
	  Wedge        tall, very lofted, wide bounce sole
	  Putter       mallet with a rounded back, a white sight line, plumber's neck

	RARITY scales the detail (see tier()): accent stripes and trims, neon inlays,
	a glow light, sparkles, a swing trail and finally a pulsing Mythical glow.

	BALLS: each ball cosmetic has a pattern (bands, swirl rings, glowing cracks,
	an accretion disc...) built from thin parts around the sphere.
]]

local Types = require(script.Parent.Types)

export type Vec = { X: number, Y: number, Z: number }
export type Shape = "Block" | "Ellipsoid" | "Cylinder" | "Wedge"
-- Role decides colour / material in the builder:
--   Body (skin primary), Face (dark metal), Sole (secondary metal), Accent
--   (secondary), Trim (gold / chrome), Neon (secondary, Neon material), Line (white)
export type Role = "Body" | "Face" | "Sole" | "Accent" | "Trim" | "Neon" | "Line" | "Hosel"

export type Piece = {
	Name: string,
	Shape: Shape,
	Size: Vec,
	Offset: Vec, -- centre, club frame
	Rotation: Vec, -- degrees about X, Y, Z (applied Z, then Y, then X: CFrame.Angles order)
	Role: Role,
}

export type Tier = {
	Level: number, -- 1 (Common) .. 6 (Mythical)
	Accents: number, -- accent stripes / badges
	Trim: boolean, -- gold / chrome trims
	Neon: boolean, -- neon inlays
	Glow: boolean, -- PointLight on the head
	Sparkles: boolean, -- ParticleEmitter around the head
	SwingTrail: boolean, -- Trail streak behind the head while it moves
	Pulse: boolean, -- animated glow pulse
}

export type ClubSpec = {
	Class: string,
	Length: number, -- grip to hosel
	Loft: number, -- degrees (face tilt)
	Sole: Vec, -- the point that rests on the ground
	Pieces: { Piece },
	Tier: Tier,
}

export type Band = { Rotation: Vec, Width: number, Role: "Accent" | "Neon" | "Line" | "Trim" }
export type BallSpec = {
	Bands: { Band }, -- rings hugging the sphere (stripes, swirls, cracks)
	Disc: { Diameter: number, Thickness: number, Tilt: number }?, -- accretion disc (spins)
	Core: boolean, -- glowing inner core (seen through Glass / ForceField)
	Sparkles: boolean,
	Embers: boolean, -- rising sparks
	SpinRate: number, -- degrees / second for the disc (0 = still)
	BodyColor: Types.RGB?, -- overrides the item colour for the sphere itself
	BodyMaterial: string?,
	GlowColor: Types.RGB?, -- disc / core / neon colour (default: the item colour)
}

local CosmeticModels = {}

local TIER_LEVEL: { [string]: number } = { Common = 1, Uncommon = 2, Rare = 3, Unique = 4, Legendary = 5, Mythical = 6 }

function CosmeticModels.tier(rarity: Types.RarityId | string): Tier
	local level = TIER_LEVEL[rarity] or 1
	return {
		Level = level,
		Accents = if level >= 2 then math.min(level - 1, 3) else 0,
		Trim = level >= 3,
		Neon = level >= 4,
		Glow = level >= 5,
		Sparkles = level >= 5,
		SwingTrail = level >= 5,
		Pulse = level >= 6,
	}
end

local function v(x: number, y: number, z: number): Vec
	return { X = x, Y = y, Z = z }
end

local function piece(name: string, shape: Shape, size: Vec, offset: Vec, rotation: Vec, role: Role): Piece
	return { Name = name, Shape = shape, Size = size, Offset = offset, Rotation = rotation, Role = role }
end

type HeadDef = {
	Length: number,
	Loft: number,
	Kind: "Wood" | "Iron" | "Putter",
	Depth: number, -- front-to-back (X)
	Height: number, -- (Y)
	Span: number, -- heel-to-toe (Z)
	Cavity: number, -- iron cavity size (0..1)
	SoleWidth: number, -- iron sole plate depth
}

local HEADS: { [string]: HeadDef } = {
	Driver = { Length = 4.4, Loft = 10, Kind = "Wood", Depth = 0.86, Height = 0.5, Span = 1.0, Cavity = 0, SoleWidth = 0 },
	FairwayWood = { Length = 4.15, Loft = 16, Kind = "Wood", Depth = 0.66, Height = 0.36, Span = 0.84, Cavity = 0, SoleWidth = 0 },
	LongIron = { Length = 3.95, Loft = 22, Kind = "Iron", Depth = 0.14, Height = 0.42, Span = 0.76, Cavity = 0.45, SoleWidth = 0.16 },
	ShortIron = { Length = 3.75, Loft = 34, Kind = "Iron", Depth = 0.16, Height = 0.5, Span = 0.74, Cavity = 0.7, SoleWidth = 0.2 },
	Wedge = { Length = 3.6, Loft = 54, Kind = "Iron", Depth = 0.18, Height = 0.56, Span = 0.72, Cavity = 0.3, SoleWidth = 0.32 },
	Putter = { Length = 3.0, Loft = 3, Kind = "Putter", Depth = 0.42, Height = 0.24, Span = 0.92, Cavity = 0, SoleWidth = 0 },
}

-- Where the head sits: its bottom just below the hosel, its heel at the shaft.
local HEAD_DROP = 0.06 -- studs from the hosel down to the sole line
local SOLE_BEHIND_FACE = 0.04 -- the resting point, just behind the leading edge

function CosmeticModels.classes(): { string }
	return { "Driver", "FairwayWood", "LongIron", "ShortIron", "Wedge", "Putter" }
end

function CosmeticModels.club(class: string, rarity: Types.RarityId | string): ClubSpec
	local h = HEADS[class] or HEADS.ShortIron
	local tier = CosmeticModels.tier(rarity)
	local pieces: { Piece } = {}
	local bottom = -h.Length - HEAD_DROP -- sole line (Y)
	local midY = bottom + h.Height / 2
	local midZ = h.Span / 2 - 0.08 -- the heel overlaps the shaft slightly
	local face = 0.04 -- face plane (X): a touch ahead of the shaft line
	local back = face - h.Depth
	local midX = (face + back) / 2

	local function add(p: Piece)
		table.insert(pieces, p)
	end

	-- Hosel: the neck joining the shaft to the heel.
	if h.Kind == "Putter" then
		-- Plumber's neck: down, across, down.
		add(piece("Neck", "Cylinder", v(0.3, 0.08, 0.08), v(0, -h.Length + 0.12, 0), v(0, 0, 90), "Hosel"))
		add(piece("NeckBend", "Block", v(0.08, 0.08, 0.2), v(0, -h.Length + 0.22, 0.1), v(0, 0, 0), "Hosel"))
	else
		add(piece("Hosel", "Cylinder", v(0.34, 0.11, 0.11), v(0, -h.Length + 0.14, 0), v(0, 0, 90), "Hosel"))
	end

	if h.Kind == "Wood" then
		-- Rounded head, slightly flattened sole, a flat face and a crown stripe.
		add(piece("Body", "Ellipsoid", v(h.Depth, h.Height, h.Span), v(midX, midY + 0.02, midZ), v(0, 0, 0), "Body"))
		add(piece("Face", "Block", v(0.05, h.Height * 0.78, h.Span * 0.8), v(face - 0.02, midY, midZ), v(0, 0, h.Loft), "Face"))
		add(piece("SolePlate", "Ellipsoid", v(h.Depth * 0.86, 0.06, h.Span * 0.86), v(midX, bottom + 0.035, midZ), v(0, 0, 0), "Sole"))
		for i = 1, tier.Accents do
			-- Crown stripes along the target line (alignment aids / racing stripes).
			local z = midZ + (i - (tier.Accents + 1) / 2) * 0.14
			add(piece(`CrownStripe{i}`, "Ellipsoid", v(h.Depth * 0.7, 0.05, 0.06), v(midX - 0.04, midY + h.Height * 0.47, z), v(0, 0, 0), "Accent"))
		end
		if tier.Trim then
			add(piece("Skirt", "Ellipsoid", v(h.Depth * 1.02, 0.07, h.Span * 1.02), v(midX, midY - h.Height * 0.12, midZ), v(0, 0, 0), "Trim"))
		end
		if tier.Neon then
			add(piece("NeonRing", "Ellipsoid", v(h.Depth * 0.92, 0.03, h.Span * 0.92), v(midX, midY + h.Height * 0.12, midZ), v(0, 0, 0), "Neon"))
		end
	elseif h.Kind == "Iron" then
		-- The blade leans back by the loft, pivoting on its back-bottom edge so its
		-- leading edge is the most forward point and nothing dips below the sole.
		-- Blade-local point (a forward from the back face, s up the face):
		local th = math.rad(h.Loft)
		local nx, ny = math.cos(th), math.sin(th) -- face normal (forward / up)
		local ux, uy = -math.sin(th), math.cos(th) -- up the face (leans back)
		local backX = face - h.Depth * nx
		local function at(a: number, s: number, z: number): Vec
			return v(backX + nx * a + ux * s, bottom + ny * a + uy * s, z)
		end
		local tilt = v(0, 0, h.Loft)
		add(piece("Blade", "Block", v(h.Depth, h.Height, h.Span), at(h.Depth / 2, h.Height / 2, midZ), tilt, "Body"))
		add(piece("TopLine", "Block", v(h.Depth * 1.15, 0.05, h.Span * 0.98), at(h.Depth / 2, h.Height - 0.02, midZ), tilt, "Sole"))
		local soleHeight = math.max(0.07, h.Depth * ny + 0.03)
		add(piece("SolePlate", "Block", v(h.SoleWidth, soleHeight, h.Span * 0.96), v(face - h.SoleWidth / 2, bottom + soleHeight / 2, midZ), v(0, 0, 0), "Sole"))
		if h.Cavity > 0 then
			add(piece("Cavity", "Block", v(0.06, h.Height * 0.5 * h.Cavity + 0.08, h.Span * 0.62), at(-0.02, h.Height * 0.34, midZ + 0.04), tilt, "Accent"))
		end
		local grooves = if class == "Wedge" then 6 else 4
		for i = 1, grooves do
			add(piece(`Groove{i}`, "Block", v(0.02, 0.02, h.Span * 0.6), at(h.Depth + 0.004, 0.1 + (i - 0.5) * (h.Height * 0.62 / grooves), midZ), tilt, "Face"))
		end
		for i = 1, tier.Accents do
			add(piece(`Badge{i}`, "Block", v(0.04, 0.05, 0.16), at(-0.05, h.Height * 0.22 + i * 0.07, midZ + 0.12), tilt, "Accent"))
		end
		if tier.Trim then
			add(piece("ToeTrim", "Block", v(h.Depth * 1.1, h.Height * 0.9, 0.04), at(h.Depth / 2, h.Height * 0.5, midZ + h.Span / 2 - 0.01), tilt, "Trim"))
		end
		if tier.Neon then
			add(piece("NeonInlay", "Block", v(0.03, 0.04, h.Span * 0.7), at(-0.06, h.Height * 0.55, midZ), tilt, "Neon"))
		end
	else -- Putter (mallet)
		local body = h.Depth * 0.55
		add(piece("Body", "Block", v(body, h.Height, h.Span), v(face - body / 2, midY, midZ), v(0, 0, h.Loft), "Body"))
		add(piece("Back", "Cylinder", v(h.Span * 0.9, h.Height, h.Height), v(face - body, bottom + h.Height / 2, midZ), v(0, 90, 0), "Body"))
		add(piece("FaceInsert", "Block", v(0.03, h.Height * 0.62, h.Span * 0.7), v(face + 0.005, midY, midZ), v(0, 0, h.Loft), "Face"))
		add(piece("SightLine", "Block", v(h.Depth * 0.8, 0.02, 0.05), v(face - h.Depth * 0.42, bottom + h.Height + 0.002, midZ), v(0, 0, 0), "Line"))
		add(piece("SolePlate", "Block", v(h.Depth * 0.9, 0.04, h.Span * 0.9), v(face - h.Depth * 0.45, bottom + 0.02, midZ), v(0, 0, 0), "Sole"))
		for i = 1, tier.Accents do
			add(piece(`Wing{i}`, "Block", v(h.Depth * 0.5, 0.05, 0.08), v(face - h.Depth * 0.6, bottom + h.Height * 0.5 + 0.03 * i, midZ + (if i % 2 == 0 then -1 else 1) * h.Span * 0.38), v(0, 0, 0), "Accent"))
		end
		if tier.Trim then
			add(piece("Rim", "Block", v(0.04, h.Height * 0.95, h.Span * 1.01), v(face - body + 0.02, midY, midZ), v(0, 0, 0), "Trim"))
		end
		if tier.Neon then
			add(piece("NeonSight", "Block", v(h.Depth * 0.7, 0.025, 0.02), v(face - h.Depth * 0.42, bottom + h.Height + 0.006, midZ - 0.08), v(0, 0, 0), "Neon"))
		end
	end

	return {
		Class = class,
		Length = h.Length,
		Loft = h.Loft,
		Sole = v(face - SOLE_BEHIND_FACE, bottom, midZ),
		Pieces = pieces,
		Tier = tier,
	}
end

-- Half-extents of a piece's (rotated) bounding box, CFrame.Angles(x, y, z) order.
function CosmeticModels.extents(p: Piece): Vec
	local cx, sx = math.cos(math.rad(p.Rotation.X)), math.sin(math.rad(p.Rotation.X))
	local cy, sy = math.cos(math.rad(p.Rotation.Y)), math.sin(math.rad(p.Rotation.Y))
	local cz, sz = math.cos(math.rad(p.Rotation.Z)), math.sin(math.rad(p.Rotation.Z))
	-- R = Rx * Ry * Rz
	local r = {
		{ cy * cz, -cy * sz, sy },
		{ cx * sz + sx * sy * cz, cx * cz - sx * sy * sz, -sx * cy },
		{ sx * sz - cx * sy * cz, sx * cz + cx * sy * sz, cx * cy },
	}
	local h = { p.Size.X / 2, p.Size.Y / 2, p.Size.Z / 2 }
	local e = {}
	for i = 1, 3 do
		e[i] = math.abs(r[i][1]) * h[1] + math.abs(r[i][2]) * h[2] + math.abs(r[i][3]) * h[3]
	end
	return v(e[1], e[2], e[3])
end

-- Most forward point of the head (the leading edge / face).
function CosmeticModels.faceX(spec: ClubSpec): number
	local best = -math.huge
	for _, p in spec.Pieces do
		if p.Role ~= "Hosel" then
			best = math.max(best, p.Offset.X + CosmeticModels.extents(p).X)
		end
	end
	return best
end

-- Lowest point of a club's pieces.
function CosmeticModels.bottomY(spec: ClubSpec): number
	local low = math.huge
	for _, p in spec.Pieces do
		low = math.min(low, p.Offset.Y - CosmeticModels.extents(p).Y)
	end
	return low
end

-- Ball patterns per item (unknown ids: plain).
local BALLS: { [string]: BallSpec } = {
	ball_hex = { Bands = { { Rotation = v(0, 0, 90), Width = 0.06, Role = "Line" } }, Disc = nil, Core = false, Sparkles = false, Embers = false, SpinRate = 0 },
	ball_neon = {
		Bands = { { Rotation = v(0, 0, 0), Width = 0.16, Role = "Accent" }, { Rotation = v(0, 0, 90), Width = 0.07, Role = "Neon" } },
		Disc = nil, Core = false, Sparkles = false, Embers = false, SpinRate = 0,
	},
	ball_marble = {
		Bands = { { Rotation = v(25, 0, 10), Width = 0.08, Role = "Trim" }, { Rotation = v(-40, 30, 70), Width = 0.05, Role = "Accent" }, { Rotation = v(70, -20, -30), Width = 0.04, Role = "Accent" } },
		Disc = nil, Core = false, Sparkles = false, Embers = false, SpinRate = 0,
	},
	ball_lava = {
		Bands = { { Rotation = v(15, 0, 20), Width = 0.05, Role = "Neon" }, { Rotation = v(-60, 40, 80), Width = 0.04, Role = "Neon" }, { Rotation = v(80, 10, -40), Width = 0.035, Role = "Neon" }, { Rotation = v(0, 70, 0), Width = 0.03, Role = "Neon" } },
		Disc = nil, Core = true, Sparkles = false, Embers = true, SpinRate = 0,
		BodyColor = { 46, 30, 26 }, BodyMaterial = "Basalt",
	},
	ball_golden = {
		Bands = { { Rotation = v(0, 0, 0), Width = 0.1, Role = "Trim" }, { Rotation = v(0, 0, 90), Width = 0.1, Role = "Trim" }, { Rotation = v(90, 0, 0), Width = 0.1, Role = "Trim" } },
		Disc = nil, Core = false, Sparkles = true, Embers = false, SpinRate = 0,
	},
	ball_blackhole = {
		Bands = {},
		Disc = { Diameter = 2.1, Thickness = 0.04, Tilt = 18 },
		Core = true, Sparkles = true, Embers = false, SpinRate = 140,
		BodyMaterial = "Glass", GlowColor = { 255, 140, 70 },
	},
}

local PLAIN: BallSpec = { Bands = {}, Disc = nil, Core = false, Sparkles = false, Embers = false, SpinRate = 0 }

-- Sizes are in BALL DIAMETERS (the builder scales them to the ball).
function CosmeticModels.ball(itemId: string?): BallSpec
	return BALLS[itemId or ""] or PLAIN
end

-- Ids with a hand-designed pattern (for the tests / docs).
function CosmeticModels.patternedBalls(): { string }
	local ids: { string } = {}
	for id in BALLS do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

return CosmeticModels
