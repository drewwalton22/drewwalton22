--!strict
--[[
	ClubDatabase.luau  (ReplicatedStorage.GolfRivals.Shared)

	Every club a player can own. What a club category IS (launch, spin, carry) and
	what the stats DO lives in ClubStats; this module only lists the products.

	BAG MODEL
	  The bag has exactly six slots, one per ClubStats category:
	    DR Driver | FW Fairway Wood | LI Long Iron | SI Short Iron | WG Wedge | PT Putter
	  Clubs are grouped into product LINES (e.g. "Tatermade Swift"). A line lists
	  which categories it covers and shares one set of base stats.

	PARODY BRANDS (not real trademarks): Tatermade, Title-Less, Pong, Call-A-Way.

	STATS (0-100): Power, Accuracy, Spin (see ClubStats). Upgraded per club per
	stat with coins. OVR = 0.4*Power + 0.3*Accuracy + 0.3*Spin.

	CLUB IDS are "<line key>_<category label lowercased>", e.g. "pong_gale_dr".
]]

local Types = require(script.Parent.Types)
local ClubStats = require(script.Parent.ClubStats)
local TableUtil = require(script.Parent.TableUtil)

type RarityId = Types.RarityId

export type Stats = ClubStats.Stats
-- A bag slot IS a club category (kept as an alias: most code thinks in "slots").
export type BagSlot = ClubStats.Category

export type Club = {
	Id: string,
	Name: string,
	Brand: string,
	Line: string,
	Class: Types.ClubClass,
	SlotLabel: string, -- which category / bag slot this club fills ("DR", "PT", ...)
	LoftDeg: number,
	BaseCarryYds: number,
	BaseStats: Stats,
	Rarity: RarityId,
	-- Coin price in the club shop. 0 = starter club (owned from first join).
	Price: number,
	Starter: boolean,
}

local ClubDatabase = {}

-- ---------------------------------------------------------------------------
-- Product lines
-- ---------------------------------------------------------------------------
type ClubLine = {
	Key: string,
	Brand: string,
	Line: string,
	Rarity: RarityId,
	Stats: Stats,
	Price: number, -- coins per club; 0 marks the free starter line
	Labels: { string }, -- categories this line covers
}

local ALL = { "DR", "FW", "LI", "SI", "WG", "PT" }
local WOODS = { "DR", "FW" }
local IRONS = { "LI", "SI" }

local function stats(power: number, accuracy: number, spin: number): Stats
	return { Power = power, Accuracy = accuracy, Spin = spin }
end

local LINES: { ClubLine } = {
	-- Starter set: the full six-club bag, free, mediocre everywhere.
	{ Key = "tatermade_swift", Brand = "Tatermade", Line = "Swift", Rarity = "Common", Stats = stats(55, 60, 65), Price = 0, Labels = ALL },

	-- Driver & fairway wood
	{ Key = "titleless_vector", Brand = "Title-Less", Line = "Vector", Rarity = "Uncommon", Stats = stats(68, 66, 70), Price = 4000, Labels = WOODS },
	{ Key = "pong_gale", Brand = "Pong", Line = "Gale", Rarity = "Rare", Stats = stats(78, 72, 75), Price = 12000, Labels = WOODS },
	-- Stats chosen to match the mockup driver card (OVR 86).
	{ Key = "tatermade_shadow", Brand = "Tatermade", Line = "Shadow", Rarity = "Unique", Stats = stats(92, 78, 85), Price = 40000, Labels = WOODS },
	{ Key = "callaway_phoenix", Brand = "Call-A-Way", Line = "Phoenix", Rarity = "Legendary", Stats = stats(98, 82, 88), Price = 150000, Labels = WOODS },

	-- Long & short irons
	{ Key = "pong_forge", Brand = "Pong", Line = "Forge", Rarity = "Uncommon", Stats = stats(64, 68, 66), Price = 2500, Labels = IRONS },
	{ Key = "callaway_comet", Brand = "Call-A-Way", Line = "Comet", Rarity = "Rare", Stats = stats(74, 76, 72), Price = 7000, Labels = IRONS },
	{ Key = "titleless_tour", Brand = "Title-Less", Line = "Tour", Rarity = "Unique", Stats = stats(82, 88, 70), Price = 20000, Labels = IRONS },

	-- Wedges (Spin is the wedge stat)
	{ Key = "pong_zip", Brand = "Pong", Line = "Zip", Rarity = "Uncommon", Stats = stats(58, 70, 72), Price = 2500, Labels = { "WG" } },
	{ Key = "titleless_spin", Brand = "Title-Less", Line = "Spin", Rarity = "Rare", Stats = stats(60, 82, 86), Price = 6000, Labels = { "WG" } },

	-- Putters (Power = pace on long putts)
	{ Key = "callaway_blade", Brand = "Call-A-Way", Line = "Blade", Rarity = "Uncommon", Stats = stats(60, 70, 62), Price = 2000, Labels = { "PT" } },
	{ Key = "titleless_mallet", Brand = "Title-Less", Line = "Mallet", Rarity = "Rare", Stats = stats(66, 78, 80), Price = 6000, Labels = { "PT" } },
	{ Key = "pong_laser", Brand = "Pong", Line = "Laser", Rarity = "Legendary", Stats = stats(80, 94, 90), Price = 60000, Labels = { "PT" } },
}

-- ---------------------------------------------------------------------------
-- Expand lines -> individual clubs
-- ---------------------------------------------------------------------------
local clubsById: { [string]: Club } = {}
local allClubs: { Club } = {}

for _, line in LINES do
	for _, label in line.Labels do
		local category = ClubStats.get(label)
		assert(category, `line {line.Key} references unknown category {label}`)
		local id = `{line.Key}_{string.lower(label)}`
		assert(clubsById[id] == nil, "duplicate club id: " .. id)
		local club: Club = {
			Id = id,
			Name = `{line.Brand} {line.Line} {category.DisplayName}`,
			Brand = line.Brand,
			Line = line.Line,
			Class = category.Class,
			SlotLabel = label,
			LoftDeg = category.LoftDeg,
			BaseCarryYds = category.BaseCarryYds,
			BaseStats = line.Stats,
			Rarity = line.Rarity,
			Price = line.Price,
			Starter = line.Price == 0,
		}
		clubsById[id] = club
		table.insert(allClubs, club)
	end
end

-- Stable order (shop listings must match across servers).
table.sort(allClubs, function(a: Club, b: Club)
	return a.Id < b.Id
end)

local starterClubs: { Club } = {}
for _, club in allClubs do
	if club.Starter then
		table.insert(starterClubs, club)
	end
end

ClubDatabase.BagSlots = ClubStats.Categories
ClubDatabase.Clubs = TableUtil.deepFreeze(clubsById) :: { [string]: Club }
ClubDatabase.Ordered = TableUtil.deepFreeze(allClubs) :: { Club }
ClubDatabase.StarterClubs = TableUtil.deepFreeze(starterClubs) :: { Club }

-- Takes untrusted input; nil for unknown ids.
function ClubDatabase.get(id: any): Club?
	if type(id) ~= "string" then
		return nil
	end
	return ClubDatabase.Clubs[id]
end

-- Category for a bag label ("DR"...); nil for unknown/untrusted input.
function ClubDatabase.getSlot(label: any): BagSlot?
	return ClubStats.get(label)
end

-- Stat math lives in ClubStats; re-exported so existing callers keep one import.
ClubDatabase.statAtLevel = ClubStats.statAtLevel
ClubDatabase.upgradeCost = ClubStats.upgradeCost
ClubDatabase.overall = ClubStats.overall

-- ---------------------------------------------------------------------------
-- Legacy (schema v1, 14-slot bag) -> six categories. Used by the v1 -> v2
-- profile migration only.
-- ---------------------------------------------------------------------------
ClubDatabase.LegacyLabelMap = TableUtil.deepFreeze({
	D = "DR",
	["3W"] = "FW",
	["5W"] = "FW",
	["4i"] = "LI",
	["5i"] = "LI",
	["6i"] = "LI",
	["7i"] = "SI",
	["8i"] = "SI",
	["9i"] = "SI",
	PW = "WG",
	GW = "WG",
	SW = "WG",
	LW = "WG",
	PT = "PT",
}) :: { [string]: string }

-- The old slot whose equipped club wins when several old slots merge into one
-- category (the club the player hit most from that range).
ClubDatabase.LegacyPreferred = TableUtil.deepFreeze({
	DR = "D",
	FW = "3W",
	LI = "5i",
	SI = "7i",
	WG = "PW",
	PT = "PT",
}) :: { [string]: string }

-- "pong_gale_3w" -> "pong_gale_fw" (nil if the id isn't a legacy club id or the
-- mapped club doesn't exist).
function ClubDatabase.migrateLegacyId(oldId: any): string?
	if type(oldId) ~= "string" then
		return nil
	end
	local lineKey, oldLabel = string.match(oldId, "^(.+)_([%w]+)$")
	if lineKey == nil or oldLabel == nil then
		return nil
	end
	for legacy, label in ClubDatabase.LegacyLabelMap do
		if string.lower(legacy) == oldLabel then
			local newId = `{lineKey}_{string.lower(label)}`
			return if clubsById[newId] then newId else nil
		end
	end
	return nil
end

return ClubDatabase
