--!strict
--[[
	ItemDatabase.luau  (ReplicatedStorage.GolfRivals.Shared)

	Global catalogue of every cosmetic in the game. Three categories, each of
	which feeds exactly one case type (see CaseDatabase):

	  ClubSkin      - generated from SKIN_THEMES x the 5 club classes, so a
	                  "Crimson" finish exists for Driver, Wood, Iron, Wedge and
	                  Putter (the "dedicated skin slot per club class" rule).
	  Animation     - Swing / Stance / Emote (victory) animations.
	  BallCosmetic  - BallModel / BallTrail / HoleEffect (hole-drop VFX).

	Prices are NOT stored per item: price comes from the item's rarity
	(Rarity.ShopPrice), so rebalancing the economy is a one-line change.

	ASSET IDs: every `AssetId` below is the placeholder "rbxassetid://0".
	Swap in real uploads (meshes / animations / particle presets) as art
	lands; nothing else in the codebase depends on the value.

	DETERMINISM: all public arrays are sorted by Id. The daily shop and case
	pools index into these arrays with seeded RNG, so every server must see the
	same order (dictionary iteration order is not guaranteed in Luau).
]]

local Types = require(script.Parent.Types)
local Rarity = require(script.Parent.Rarity)
local TableUtil = require(script.Parent.TableUtil)

type RarityId = Types.RarityId
type ItemCategory = Types.ItemCategory

export type Visual = {
	Primary: Types.RGB?, -- main tint (skin body / trail color / VFX color)
	Secondary: Types.RGB?, -- accent tint
	Material: string?, -- Enum.Material name for skins
	AssetId: string?, -- mesh / animation / effect asset
}

export type Item = {
	Id: string,
	Name: string,
	Description: string,
	Category: ItemCategory,
	Slot: Types.ItemSlot,
	Rarity: RarityId,
	-- Starter items: every player owns and has equipped these from the first
	-- join. They are excluded from the shop (nobody buys what they own free).
	Default: boolean,
	Visual: Visual,
}

local PLACEHOLDER_ASSET = "rbxassetid://0"

local ItemDatabase = {}

ItemDatabase.Categories = { "ClubSkin", "Animation", "BallCosmetic" } :: { ItemCategory }
ItemDatabase.ClubClasses = { "Driver", "Wood", "Iron", "Wedge", "Putter" } :: { Types.ClubClass }

-- Slots belonging to each category (used by the inventory/equip validation).
ItemDatabase.CategorySlots = {
	ClubSkin = { "Driver", "Wood", "Iron", "Wedge", "Putter" },
	Animation = { "Swing", "Stance", "Emote" },
	BallCosmetic = { "BallModel", "BallTrail", "HoleEffect" },
} :: { [ItemCategory]: { Types.ItemSlot } }

-- ---------------------------------------------------------------------------
-- Registration plumbing
-- ---------------------------------------------------------------------------
local itemsById: { [string]: Item } = {}
local allItems: { Item } = {}

local function register(item: Item)
	assert(itemsById[item.Id] == nil, "duplicate item id: " .. item.Id)
	itemsById[item.Id] = item
	table.insert(allItems, item)
end

-- ---------------------------------------------------------------------------
-- 1) CLUB SKINS  (theme x club class)
-- ---------------------------------------------------------------------------
type SkinTheme = {
	Key: string,
	Name: string,
	Rarity: RarityId,
	Blurb: string,
	Primary: Types.RGB,
	Secondary: Types.RGB,
	Material: string,
	Default: boolean?,
}

local SKIN_THEMES: { SkinTheme } = {
	-- Common
	{ Key = "midnight", Name = "Midnight", Rarity = "Common", Blurb = "Matte black. Zero distractions.", Primary = { 22, 22, 26 }, Secondary = { 70, 70, 80 }, Material = "SmoothPlastic", Default = true },
	{ Key = "slate", Name = "Slate", Rarity = "Common", Blurb = "Quiet grey for loud swings.", Primary = { 110, 118, 128 }, Secondary = { 60, 64, 72 }, Material = "Metal" },
	-- Uncommon
	{ Key = "digital_camo", Name = "Digital Camo", Rarity = "Uncommon", Blurb = "Blend into the rough.", Primary = { 74, 92, 70 }, Secondary = { 40, 50, 40 }, Material = "Fabric" },
	{ Key = "fairway", Name = "Fairway Green", Rarity = "Uncommon", Blurb = "Fresh-cut stripes.", Primary = { 56, 160, 82 }, Secondary = { 190, 235, 190 }, Material = "SmoothPlastic" },
	-- Rare
	{ Key = "crimson", Name = "Crimson", Rarity = "Rare", Blurb = "Red-hot off the tee.", Primary = { 190, 30, 45 }, Secondary = { 40, 8, 12 }, Material = "Metal" },
	{ Key = "ocean", Name = "Deep Ocean", Rarity = "Rare", Blurb = "Pressure-tested blue.", Primary = { 20, 90, 190 }, Secondary = { 10, 30, 80 }, Material = "Glass" },
	-- Unique
	{ Key = "volt", Name = "Volt", Rarity = "Unique", Blurb = "Charged and crackling.", Primary = { 40, 120, 255 }, Secondary = { 190, 235, 255 }, Material = "Neon" },
	{ Key = "ultraviolet", Name = "Ultraviolet", Rarity = "Unique", Blurb = "Glows under the clubhouse lights.", Primary = { 140, 60, 230 }, Secondary = { 40, 10, 90 }, Material = "Neon" },
	-- Legendary
	{ Key = "gold_rush", Name = "Gold Rush", Rarity = "Legendary", Blurb = "Solid gold swagger.", Primary = { 235, 180, 40 }, Secondary = { 120, 80, 10 }, Material = "Metal" },
	{ Key = "royal_flush", Name = "Royal Flush", Rarity = "Legendary", Blurb = "Crown-jewel crimson and gold.", Primary = { 150, 20, 60 }, Secondary = { 245, 200, 70 }, Material = "Metal" },
	-- Mythical
	{ Key = "abyss", Name = "Abyss", Rarity = "Mythical", Blurb = "Stare into it. It swings back.", Primary = { 10, 40, 120 }, Secondary = { 0, 220, 255 }, Material = "Glass" },
	{ Key = "anime_wave", Name = "Anime Wave", Rarity = "Mythical", Blurb = "Pastel shockwave, maximum drama.", Primary = { 255, 120, 200 }, Secondary = { 90, 200, 255 }, Material = "Neon" },
	{ Key = "nebula", Name = "Nebula", Rarity = "Mythical", Blurb = "A galaxy in a clubhead.", Primary = { 120, 50, 230 }, Secondary = { 255, 90, 180 }, Material = "Neon" },
}

for _, theme in SKIN_THEMES do
	for _, class in ItemDatabase.ClubClasses do
		register({
			Id = `skin_{theme.Key}_{string.lower(class)}`,
			Name = theme.Name,
			Description = `{theme.Blurb} ({class} finish)`,
			Category = "ClubSkin",
			Slot = class, -- a skin only fits its own club class
			Rarity = theme.Rarity,
			Default = theme.Default == true,
			Visual = {
				Primary = theme.Primary,
				Secondary = theme.Secondary,
				Material = theme.Material,
				AssetId = PLACEHOLDER_ASSET,
			},
		})
	end
end

-- ---------------------------------------------------------------------------
-- 2) ANIMATIONS  (Swing / Stance / Emote)  and  3) BALL COSMETICS
--    Both are flat lists, one entry per (slot, rarity).
-- ---------------------------------------------------------------------------
type FlatDef = {
	Key: string,
	Slot: Types.ItemSlot,
	Name: string,
	Rarity: RarityId,
	Blurb: string,
	Primary: Types.RGB?, -- VFX tint (ball cosmetics only)
	Default: boolean?,
}

local ANIMATIONS: { FlatDef } = {
	-- Swings
	{ Key = "swing_classic", Slot = "Swing", Name = "Classic Swing", Rarity = "Common", Blurb = "Textbook. Reliable.", Default = true },
	{ Key = "swing_smooth", Slot = "Swing", Name = "Smooth Operator", Rarity = "Uncommon", Blurb = "Effortless tempo." },
	{ Key = "swing_windup", Slot = "Swing", Name = "Power Windup", Rarity = "Rare", Blurb = "Big turn, bigger crack." },
	{ Key = "swing_samurai", Slot = "Swing", Name = "Samurai Slash", Rarity = "Unique", Blurb = "One clean cut." },
	{ Key = "swing_thunder", Slot = "Swing", Name = "Thunder Crack", Rarity = "Legendary", Blurb = "You hear it before you see it." },
	{ Key = "swing_cosmic", Slot = "Swing", Name = "Cosmic Whip", Rarity = "Mythical", Blurb = "Bends spacetime around the shaft." },
	-- Stances
	{ Key = "stance_standard", Slot = "Stance", Name = "Standard Stance", Rarity = "Common", Blurb = "Feet shoulder-width.", Default = true },
	{ Key = "stance_wide", Slot = "Stance", Name = "Wide Stance", Rarity = "Uncommon", Blurb = "Planted like an oak." },
	{ Key = "stance_pro", Slot = "Stance", Name = "Pro Setup", Rarity = "Rare", Blurb = "Routine locked in." },
	{ Key = "stance_zen", Slot = "Stance", Name = "Zen Focus", Rarity = "Unique", Blurb = "Breathe. Aim. Believe." },
	{ Key = "stance_titan", Slot = "Stance", Name = "Titan Stance", Rarity = "Legendary", Blurb = "The ground cracks slightly." },
	{ Key = "stance_void", Slot = "Stance", Name = "Void Walker", Rarity = "Mythical", Blurb = "Hovers a hair off the turf." },
	-- Victory emotes
	{ Key = "emote_fistpump", Slot = "Emote", Name = "Fist Pump", Rarity = "Common", Blurb = "Classic celebration.", Default = true },
	{ Key = "emote_twirl", Slot = "Emote", Name = "Club Twirl", Rarity = "Uncommon", Blurb = "Spin it like a baton." },
	{ Key = "emote_moonwalk", Slot = "Emote", Name = "Moonwalk", Rarity = "Rare", Blurb = "Smooth criminal on the green." },
	{ Key = "emote_hio_dance", Slot = "Emote", Name = "Hole-in-One Dance", Rarity = "Unique", Blurb = "Pure, unfiltered joy." },
	{ Key = "emote_trophy", Slot = "Emote", Name = "Trophy Lift", Rarity = "Legendary", Blurb = "Hoist the hardware." },
	{ Key = "emote_ascension", Slot = "Emote", Name = "Golden Ascension", Rarity = "Mythical", Blurb = "Rise. Glow. Repeat." },
}

local BALL_COSMETICS: { FlatDef } = {
	-- Ball models
	{ Key = "ball_hex", Slot = "BallModel", Name = "Hex Ball", Rarity = "Common", Blurb = "Hexagonal dimples.", Primary = { 235, 235, 240 }, Default = true },
	{ Key = "ball_neon", Slot = "BallModel", Name = "Neon Dimple", Rarity = "Uncommon", Blurb = "Easy to find at dusk.", Primary = { 120, 255, 120 } },
	{ Key = "ball_marble", Slot = "BallModel", Name = "Marble Ball", Rarity = "Rare", Blurb = "Polished stone.", Primary = { 200, 205, 215 } },
	{ Key = "ball_lava", Slot = "BallModel", Name = "Lava Core", Rarity = "Unique", Blurb = "Molten center.", Primary = { 255, 110, 30 } },
	{ Key = "ball_golden", Slot = "BallModel", Name = "Golden Orb", Rarity = "Legendary", Blurb = "Worth more than your bag.", Primary = { 255, 205, 70 } },
	{ Key = "ball_blackhole", Slot = "BallModel", Name = "Black Hole", Rarity = "Mythical", Blurb = "Light bends around it.", Primary = { 15, 5, 30 } },
	-- Ball trails
	{ Key = "trail_chalk", Slot = "BallTrail", Name = "Chalk Dust", Rarity = "Common", Blurb = "A faint white streak.", Primary = { 240, 240, 240 }, Default = true },
	{ Key = "trail_grass", Slot = "BallTrail", Name = "Grass Cuttings", Rarity = "Uncommon", Blurb = "Fresh-mown confetti.", Primary = { 90, 200, 90 } },
	{ Key = "trail_ocean", Slot = "BallTrail", Name = "Ocean Wake", Rarity = "Rare", Blurb = "Spray in the air.", Primary = { 60, 150, 255 } },
	{ Key = "trail_lightning", Slot = "BallTrail", Name = "Lightning Trail", Rarity = "Unique", Blurb = "Crackling arcs.", Primary = { 90, 170, 255 } },
	{ Key = "trail_comet", Slot = "BallTrail", Name = "Comet Tail", Rarity = "Legendary", Blurb = "Streaks across the sky.", Primary = { 255, 200, 90 } },
	{ Key = "trail_nova", Slot = "BallTrail", Name = "Rainbow Nova", Rarity = "Mythical", Blurb = "Every color at once.", Primary = { 255, 90, 200 } },
	-- Hole-drop effects
	{ Key = "hole_confetti", Slot = "HoleEffect", Name = "Confetti Pop", Rarity = "Common", Blurb = "A little paper party.", Primary = { 255, 220, 120 }, Default = true },
	{ Key = "hole_sparks", Slot = "HoleEffect", Name = "Spark Pop", Rarity = "Uncommon", Blurb = "Fizzing sparks.", Primary = { 255, 200, 80 } },
	{ Key = "hole_splash", Slot = "HoleEffect", Name = "Water Splash", Rarity = "Rare", Blurb = "Cup full of ocean.", Primary = { 70, 160, 255 } },
	{ Key = "hole_firework", Slot = "HoleEffect", Name = "Firework", Rarity = "Unique", Blurb = "Boom, in the cup.", Primary = { 255, 90, 120 } },
	{ Key = "hole_crown", Slot = "HoleEffect", Name = "Crown Hole", Rarity = "Legendary", Blurb = "Long live the putt.", Primary = { 255, 205, 70 } },
	{ Key = "hole_supernova", Slot = "HoleEffect", Name = "Supernova", Rarity = "Mythical", Blurb = "The cup goes critical.", Primary = { 255, 120, 230 } },
}

local function registerFlat(defs: { FlatDef }, category: ItemCategory)
	for _, def in defs do
		register({
			Id = def.Key,
			Name = def.Name,
			Description = def.Blurb,
			Category = category,
			Slot = def.Slot,
			Rarity = def.Rarity,
			Default = def.Default == true,
			Visual = { Primary = def.Primary, AssetId = PLACEHOLDER_ASSET },
		})
	end
end

registerFlat(ANIMATIONS, "Animation")
registerFlat(BALL_COSMETICS, "BallCosmetic")

-- ---------------------------------------------------------------------------
-- Indexes (built once; everything below is frozen afterwards)
-- ---------------------------------------------------------------------------
-- Sort by Id so every server enumerates items in the same order.
table.sort(allItems, function(a: Item, b: Item)
	return a.Id < b.Id
end)

local function emptyRarityMap(): { [RarityId]: { Item } }
	local map: { [RarityId]: { Item } } = {}
	for _, rarityId in Rarity.Order do
		map[rarityId] = {}
	end
	return map
end

-- ByCategory[category][rarity] -> sorted array. Case pools & trade-up rewards.
local byCategory: { [ItemCategory]: { [RarityId]: { Item } } } = {}
for _, category in ItemDatabase.Categories do
	byCategory[category] = emptyRarityMap()
end

-- ShopPool[rarity] -> sorted array of every purchasable (non-default) item.
local shopPool = emptyRarityMap()

for _, item in allItems do
	table.insert(byCategory[item.Category][item.Rarity], item)
	if not item.Default then
		table.insert(shopPool[item.Rarity], item)
	end
end

ItemDatabase.Items = TableUtil.deepFreeze(itemsById) :: { [string]: Item }
ItemDatabase.Ordered = TableUtil.deepFreeze(allItems) :: { Item }
ItemDatabase.ByCategory = TableUtil.deepFreeze(byCategory) :: { [ItemCategory]: { [RarityId]: { Item } } }
ItemDatabase.ShopPool = TableUtil.deepFreeze(shopPool) :: { [RarityId]: { Item } }
ItemDatabase.DefaultItems = TableUtil.deepFreeze((function(): { Item }
	local defaults: { Item } = {}
	for _, item in allItems do
		if item.Default then
			table.insert(defaults, item)
		end
	end
	return defaults
end)()) :: { Item }

-- ---------------------------------------------------------------------------
-- Lookups
-- ---------------------------------------------------------------------------
-- Takes untrusted input (remote arguments) so it accepts `any` and returns nil
-- for unknown ids instead of erroring.
function ItemDatabase.get(id: any): Item?
	if type(id) ~= "string" then
		return nil
	end
	return ItemDatabase.Items[id]
end

function ItemDatabase.isCategory(value: any): boolean
	return value == "ClubSkin" or value == "Animation" or value == "BallCosmetic"
end

-- All items of a category at one rarity (sorted by Id).
function ItemDatabase.list(category: ItemCategory, rarity: RarityId): { Item }
	return ItemDatabase.ByCategory[category][rarity]
end

return ItemDatabase
