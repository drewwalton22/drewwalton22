--!strict
--[[
	CosmeticsData.luau  (ReplicatedStorage.GolfRivals.Shared)

	THE central description of how every cosmetic LOOKS and MOVES. ItemDatabase
	says what an item is (name, rarity, slot, price); this module says how to
	render it:

	  GOLF BALL SKINS      colour, material, optional MeshId / TextureId, glow
	  BALL TRAILS          Trail (streak), Sparkle (Trail + ParticleEmitter) or
	                       Ribbon (a Beam that lags behind the ball + emitter)
	  CLUB MESHES          per club category (Driver, Fairway Wood, Long Iron,
	                       Short Iron, Wedge, Putter): head MeshId / TextureId,
	                       plus each club skin's colours / material; or a ready-made
	                       template in ReplicatedStorage.GolfRivalsAssets.Clubs
	  SWINGS / STANCES     AnimationId (with an "Impact" marker) or the procedural
	  VICTORY EMOTES       SwingPose fallback
	  HOLE EFFECTS         particle burst style, colour and size

	Every asset id ships blank: the game renders each cosmetic with procedural
	shapes, colours and particles until you paste real ids here, so nothing ever
	breaks for a missing asset. Client/Golf/CosmeticBuilder turns these looks into
	Instances (MeshParts via SpecialMesh, Trails, Beams, emitters) and attaches them
	to the golfer during the swing sequence.
]]

local ItemDatabase = require(script.Parent.ItemDatabase)
local Types = require(script.Parent.Types)

export type BallLook = {
	Color: Types.RGB,
	Material: string,
	MeshId: string, -- "" = sphere
	TextureId: string,
	Glow: boolean, -- PointLight on the ball
	Scale: number,
}

export type TrailStyle = "Trail" | "Sparkle" | "Ribbon"

export type TrailLook = {
	Style: TrailStyle,
	Color: Types.RGB,
	Color2: Types.RGB, -- end colour of the gradient
	Width: number, -- studs
	Lifetime: number, -- seconds
	LightEmission: number,
	TextureId: string,
	ParticleRate: number, -- Sparkle / Ribbon emitters
}

export type ClubLook = {
	HeadColor: Types.RGB,
	AccentColor: Types.RGB,
	Material: string,
	HeadMeshId: string, -- "" = procedural head
	HeadTextureId: string,
	HeadScale: number,
	Shape: "Wood" | "Iron" | "Putter", -- procedural head shape
	-- Templates looked up (first found wins) in ReplicatedStorage.GolfRivalsAssets.Clubs
	TemplateNames: { string },
}

export type AnimationLook = {
	AnimationId: string, -- "" = procedural
	Pose: string, -- SwingPose kind used when no animation id is set
	Speed: number,
}

export type HoleEffectLook = {
	Color: Types.RGB,
	Count: number,
	Style: "Confetti" | "Sparks" | "Splash" | "Firework" | "Crown" | "Supernova",
}

local CosmeticsData = {}

-- ---------------------------------------------------------------------------
-- Asset slots (paste rbxassetid://... values; blank = procedural fallback)
-- ---------------------------------------------------------------------------

-- Club head meshes per category (used by every skin of that category).
CosmeticsData.ClubMeshes = {
	Driver = { MeshId = "", TextureId = "", Scale = 1 },
	FairwayWood = { MeshId = "", TextureId = "", Scale = 1 },
	LongIron = { MeshId = "", TextureId = "", Scale = 1 },
	ShortIron = { MeshId = "", TextureId = "", Scale = 1 },
	Wedge = { MeshId = "", TextureId = "", Scale = 1 },
	Putter = { MeshId = "", TextureId = "", Scale = 1 },
} :: { [string]: { MeshId: string, TextureId: string, Scale: number } }

-- Optional per-item asset overrides, keyed by item id.
CosmeticsData.BallMeshes = {} :: { [string]: { MeshId: string, TextureId: string } }
CosmeticsData.TrailTextures = {} :: { [string]: string }
CosmeticsData.AnimationIds = {
	-- e.g. swing_samurai = "rbxassetid://1234567890",
} :: { [string]: string }

-- ---------------------------------------------------------------------------
-- Style tables (pure presentation, safe to tweak)
-- ---------------------------------------------------------------------------
local BALL_MATERIALS: { [string]: string } = {
	ball_hex = "SmoothPlastic", ball_neon = "Neon", ball_marble = "Marble", ball_lava = "Neon",
	ball_golden = "Foil", ball_blackhole = "Glass",
}
local BALL_GLOW: { [string]: boolean } = { ball_neon = true, ball_lava = true, ball_golden = true, ball_blackhole = true }

local TRAIL_STYLES: { [string]: { Style: TrailStyle, Color2: Types.RGB, Width: number, Lifetime: number, Light: number, Rate: number } } = {
	trail_chalk = { Style = "Trail", Color2 = { 200, 200, 200 }, Width = 0.6, Lifetime = 0.5, Light = 0.1, Rate = 0 },
	trail_grass = { Style = "Sparkle", Color2 = { 40, 140, 50 }, Width = 0.7, Lifetime = 0.6, Light = 0.2, Rate = 30 },
	trail_ocean = { Style = "Sparkle", Color2 = { 200, 240, 255 }, Width = 0.9, Lifetime = 0.7, Light = 0.4, Rate = 40 },
	trail_lightning = { Style = "Ribbon", Color2 = { 220, 240, 255 }, Width = 1.0, Lifetime = 0.5, Light = 0.9, Rate = 50 },
	trail_comet = { Style = "Ribbon", Color2 = { 255, 90, 30 }, Width = 1.4, Lifetime = 0.9, Light = 0.8, Rate = 60 },
	trail_nova = { Style = "Ribbon", Color2 = { 90, 200, 255 }, Width = 1.6, Lifetime = 1.0, Light = 1.0, Rate = 80 },
}

local HOLE_STYLES: { [string]: { Style: "Confetti" | "Sparks" | "Splash" | "Firework" | "Crown" | "Supernova", Count: number } } = {
	hole_confetti = { Style = "Confetti", Count = 60 },
	hole_sparks = { Style = "Sparks", Count = 70 },
	hole_splash = { Style = "Splash", Count = 80 },
	hole_firework = { Style = "Firework", Count = 110 },
	hole_crown = { Style = "Crown", Count = 120 },
	hole_supernova = { Style = "Supernova", Count = 160 },
}

local CLASS_SHAPES: { [string]: "Wood" | "Iron" | "Putter" } = {
	Driver = "Wood", FairwayWood = "Wood", LongIron = "Iron", ShortIron = "Iron", Wedge = "Iron", Putter = "Putter",
}

-- Procedural fallback pose per animation slot.
local ANIMATION_POSES: { [string]: string } = { Swing = "Swing", Stance = "Address", Emote = "Victory" }

-- ---------------------------------------------------------------------------
-- Resolvers: always return a complete look (never nil), whatever is passed.
-- ---------------------------------------------------------------------------
local function primaryOf(itemId: string?, fallback: Types.RGB): Types.RGB
	local item = ItemDatabase.get(itemId)
	return if item and item.Visual.Primary then item.Visual.Primary else fallback
end

function CosmeticsData.ball(itemId: string?): BallLook
	local id = itemId or ""
	local mesh = CosmeticsData.BallMeshes[id]
	return {
		Color = primaryOf(itemId, { 240, 240, 245 }),
		Material = BALL_MATERIALS[id] or "SmoothPlastic",
		MeshId = if mesh then mesh.MeshId else "",
		TextureId = if mesh then mesh.TextureId else "",
		Glow = BALL_GLOW[id] == true,
		Scale = 1,
	}
end

function CosmeticsData.trail(itemId: string?): TrailLook
	local id = itemId or ""
	local style = TRAIL_STYLES[id] or TRAIL_STYLES.trail_chalk
	return {
		Style = style.Style,
		Color = primaryOf(itemId, { 240, 240, 240 }),
		Color2 = style.Color2,
		Width = style.Width,
		Lifetime = style.Lifetime,
		LightEmission = style.Light,
		TextureId = CosmeticsData.TrailTextures[id] or "",
		ParticleRate = style.Rate,
	}
end

-- `skinItemId` = the club skin equipped for the category (EquippedItems[class]).
function CosmeticsData.club(skinItemId: string?, class: string): ClubLook
	local item = ItemDatabase.get(skinItemId)
	local mesh = CosmeticsData.ClubMeshes[class] or { MeshId = "", TextureId = "", Scale = 1 }
	local primary = if item and item.Visual.Primary then item.Visual.Primary else { 32, 32, 38 }
	local secondary = if item and item.Visual.Secondary then item.Visual.Secondary else { 200, 205, 215 }
	local templates: { string } = {}
	if skinItemId then
		table.insert(templates, skinItemId) -- a bespoke model for this exact skin
	end
	table.insert(templates, class) -- a generic model for the category
	return {
		HeadColor = primary,
		AccentColor = secondary,
		Material = if item and item.Visual.Material then item.Visual.Material else "Metal",
		HeadMeshId = mesh.MeshId,
		HeadTextureId = mesh.TextureId,
		HeadScale = mesh.Scale,
		Shape = CLASS_SHAPES[class] or "Iron",
		TemplateNames = templates,
	}
end

function CosmeticsData.animation(itemId: string?): AnimationLook
	local item = ItemDatabase.get(itemId)
	local slot = if item then item.Slot else "Swing"
	return {
		AnimationId = CosmeticsData.AnimationIds[itemId or ""] or "",
		Pose = ANIMATION_POSES[slot] or "Swing",
		Speed = 1,
	}
end

function CosmeticsData.holeEffect(itemId: string?): HoleEffectLook
	local style = HOLE_STYLES[itemId or ""] or HOLE_STYLES.hole_confetti
	return {
		Color = primaryOf(itemId, { 255, 220, 120 }),
		Count = style.Count,
		Style = style.Style,
	}
end

-- Problems with the tables above (empty = fine). Run by the offline check.
function CosmeticsData.validate(): { string }
	local errors: { string } = {}
	for _, item in ItemDatabase.Ordered do
		if item.Slot == "BallTrail" and TRAIL_STYLES[item.Id] == nil then
			table.insert(errors, `trail {item.Id} has no style`)
		elseif item.Slot == "HoleEffect" and HOLE_STYLES[item.Id] == nil then
			table.insert(errors, `hole effect {item.Id} has no style`)
		elseif item.Slot == "BallModel" and BALL_MATERIALS[item.Id] == nil then
			table.insert(errors, `ball {item.Id} has no material`)
		end
	end
	for _, class in ItemDatabase.ClubClasses do
		if CosmeticsData.ClubMeshes[class] == nil or CLASS_SHAPES[class] == nil then
			table.insert(errors, `club category {class} has no mesh slot`)
		end
	end
	return errors
end

return CosmeticsData
