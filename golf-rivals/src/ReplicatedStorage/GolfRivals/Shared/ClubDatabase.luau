--!strict
--[[
	ClubDatabase.luau  (ReplicatedStorage.GolfRivals.Shared)

	Every club a player can own, plus the stat/upgrade math.

	BAG MODEL
	  A bag has 14 slots (BagSlots) - one club equipped per slot:
	  Driver, 3W, 5W, 4i-9i, PW, GW, SW, LW, Putter.
	  Clubs are grouped into product LINES (e.g. "Tatermade Swift"). A line
	  lists which slots it covers and shares one set of base stats, so adding a
	  new iron set is one entry instead of six.

	PARODY BRANDS (not real trademarks): Tatermade, Title-Less, Pong, Call-A-Way.
	Model names are original so we only parody the brand.

	STATS (0-100): Distance, Accuracy, Forgiveness.
	  * Distance    scales carry (applied in the swing-physics step).
	  * Accuracy    shrinks hook/slice from a Click-3 timing miss.
	  * Forgiveness softens bad lies and mis-timed power.
	  Upgrades are bought per club per stat with coins (see upgradeCost).

	OVR = 0.4*Distance + 0.3*Accuracy + 0.3*Forgiveness, rounded (weights in Config).
]]

local Types = require(script.Parent.Types)
local Config = require(script.Parent.Config)
local TableUtil = require(script.Parent.TableUtil)

type RarityId = Types.RarityId

export type Stats = {
	Distance: number,
	Accuracy: number,
	Forgiveness: number,
}

export type BagSlot = {
	Label: string, -- short label used by the UI and as the slot key: "D", "3W", "7i"...
	DisplayName: string,
	Class: Types.ClubClass,
	LoftDeg: number,
	-- Full-power (100%) carry in yards with base stats on a flat fairway lie,
	-- zero wind. Distance stat / lie / wind modify this in the physics step.
	-- Putter is 0: putting uses a separate roll-speed model, not a carry.
	BaseCarryYds: number,
}

export type Club = {
	Id: string,
	Name: string,
	Brand: string,
	Line: string,
	Class: Types.ClubClass,
	SlotLabel: string, -- which BagSlot this club fills
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
-- Bag slots (fixed, in the order the bag UI lists them)
-- ---------------------------------------------------------------------------
local BAG_SLOTS: { BagSlot } = {
	{ Label = "D", DisplayName = "Driver", Class = "Driver", LoftDeg = 10.5, BaseCarryYds = 250 },
	{ Label = "3W", DisplayName = "3 Wood", Class = "Wood", LoftDeg = 15, BaseCarryYds = 230 },
	{ Label = "5W", DisplayName = "5 Wood", Class = "Wood", LoftDeg = 18, BaseCarryYds = 215 },
	{ Label = "4i", DisplayName = "4 Iron", Class = "Iron", LoftDeg = 24, BaseCarryYds = 190 },
	{ Label = "5i", DisplayName = "5 Iron", Class = "Iron", LoftDeg = 27, BaseCarryYds = 180 },
	{ Label = "6i", DisplayName = "6 Iron", Class = "Iron", LoftDeg = 30, BaseCarryYds = 170 },
	{ Label = "7i", DisplayName = "7 Iron", Class = "Iron", LoftDeg = 34, BaseCarryYds = 160 },
	{ Label = "8i", DisplayName = "8 Iron", Class = "Iron", LoftDeg = 38, BaseCarryYds = 150 },
	{ Label = "9i", DisplayName = "9 Iron", Class = "Iron", LoftDeg = 42, BaseCarryYds = 140 },
	{ Label = "PW", DisplayName = "Pitching Wedge", Class = "Wedge", LoftDeg = 46, BaseCarryYds = 125 },
	{ Label = "GW", DisplayName = "Gap Wedge", Class = "Wedge", LoftDeg = 50, BaseCarryYds = 110 },
	{ Label = "SW", DisplayName = "Sand Wedge", Class = "Wedge", LoftDeg = 56, BaseCarryYds = 95 },
	{ Label = "LW", DisplayName = "Lob Wedge", Class = "Wedge", LoftDeg = 60, BaseCarryYds = 80 },
	{ Label = "PT", DisplayName = "Putter", Class = "Putter", LoftDeg = 3, BaseCarryYds = 0 },
}

local slotByLabel: { [string]: BagSlot } = {}
for _, slot in BAG_SLOTS do
	slotByLabel[slot.Label] = slot
end

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
	Labels: { string }, -- bag slots this line covers
}

local ALL_SLOTS = { "D", "3W", "5W", "4i", "5i", "6i", "7i", "8i", "9i", "PW", "GW", "SW", "LW", "PT" }
local IRONS = { "4i", "5i", "6i", "7i", "8i", "9i" }
local WEDGES = { "PW", "GW", "SW", "LW" }

local function stats(distance: number, accuracy: number, forgiveness: number): Stats
	return { Distance = distance, Accuracy = accuracy, Forgiveness = forgiveness }
end

local LINES: { ClubLine } = {
	-- Starter set: a full 14-club bag, free, mediocre everywhere.
	{ Key = "tatermade_swift", Brand = "Tatermade", Line = "Swift", Rarity = "Common", Stats = stats(55, 60, 65), Price = 0, Labels = ALL_SLOTS },

	-- Drivers & woods
	{ Key = "titleless_vector", Brand = "Title-Less", Line = "Vector", Rarity = "Uncommon", Stats = stats(68, 66, 70), Price = 4000, Labels = { "D", "3W", "5W" } },
	{ Key = "pong_gale", Brand = "Pong", Line = "Gale", Rarity = "Rare", Stats = stats(78, 72, 75), Price = 12000, Labels = { "D", "3W", "5W" } },
	-- Stats chosen to match the mockup driver card (OVR 86).
	{ Key = "tatermade_shadow", Brand = "Tatermade", Line = "Shadow", Rarity = "Unique", Stats = stats(92, 78, 85), Price = 40000, Labels = { "D", "3W", "5W" } },
	{ Key = "callaway_phoenix", Brand = "Call-A-Way", Line = "Phoenix", Rarity = "Legendary", Stats = stats(98, 82, 88), Price = 150000, Labels = { "D", "3W" } },

	-- Irons
	{ Key = "pong_forge", Brand = "Pong", Line = "Forge", Rarity = "Uncommon", Stats = stats(64, 68, 66), Price = 2500, Labels = IRONS },
	{ Key = "callaway_comet", Brand = "Call-A-Way", Line = "Comet", Rarity = "Rare", Stats = stats(74, 76, 72), Price = 7000, Labels = IRONS },
	{ Key = "titleless_tour", Brand = "Title-Less", Line = "Tour", Rarity = "Unique", Stats = stats(82, 88, 70), Price = 20000, Labels = IRONS },

	-- Wedges
	{ Key = "pong_zip", Brand = "Pong", Line = "Zip", Rarity = "Uncommon", Stats = stats(58, 70, 66), Price = 2500, Labels = WEDGES },
	{ Key = "titleless_spin", Brand = "Title-Less", Line = "Spin", Rarity = "Rare", Stats = stats(60, 82, 72), Price = 6000, Labels = WEDGES },

	-- Putters (Distance = pace control for long putts)
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
		local slot = slotByLabel[label]
		assert(slot, `line {line.Key} references unknown bag slot {label}`)
		local id = `{line.Key}_{string.lower(label)}`
		assert(clubsById[id] == nil, "duplicate club id: " .. id)
		local club: Club = {
			Id = id,
			Name = `{line.Brand} {line.Line} {slot.DisplayName}`,
			Brand = line.Brand,
			Line = line.Line,
			Class = slot.Class,
			SlotLabel = label,
			LoftDeg = slot.LoftDeg,
			BaseCarryYds = slot.BaseCarryYds,
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

ClubDatabase.BagSlots = TableUtil.deepFreeze(BAG_SLOTS) :: { BagSlot }
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

function ClubDatabase.getSlot(label: string): BagSlot?
	return slotByLabel[label]
end

-- ---------------------------------------------------------------------------
-- Stat & upgrade math
-- ---------------------------------------------------------------------------

-- Effective stat after `level` upgrades:
--   stat = min(StatCap, base + level * PointsPerUpgrade)
function ClubDatabase.statAtLevel(base: number, level: number): number
	local cfg = Config.Clubs
	return math.min(cfg.StatCap, base + level * cfg.PointsPerUpgrade)
end

-- Coins to raise one stat from `level` to `level + 1`:
--   cost = round_to_50( CostBase * CostGrowth ^ level )
-- With the defaults: 500, 700, 900, 1250, 1650, 2250, 3050, 4100, 5500, 7450
-- (growth is exponential so maxing a club is a real coin sink).
-- Returns nil once the stat is at MaxUpgradeLevel.
function ClubDatabase.upgradeCost(level: number): number?
	local cfg = Config.Clubs
	if level >= cfg.MaxUpgradeLevel then
		return nil
	end
	local raw = cfg.UpgradeCostBase * cfg.UpgradeCostGrowth ^ level
	return math.floor(raw / 50 + 0.5) * 50
end

-- Overall rating from three stat values (already level-adjusted).
function ClubDatabase.overall(s: Stats): number
	local w = Config.Clubs.OVRWeights
	return math.floor(s.Distance * w.Distance + s.Accuracy * w.Accuracy + s.Forgiveness * w.Forgiveness + 0.5)
end

return ClubDatabase
