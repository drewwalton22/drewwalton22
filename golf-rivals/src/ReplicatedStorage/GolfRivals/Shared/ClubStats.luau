--!strict
--[[
	ClubStats.luau  (ReplicatedStorage.GolfRivals.Shared)

	THE single source of truth for what a club IS in Golf Rivals:

	  1. the six club CATEGORIES (and nothing else - the bag is exactly these):
	        DR  Driver        - maximum distance off the tee
	        FW  Fairway Wood  - long second shots from the short grass
	        LI  Long Iron     - controlled long approaches
	        SI  Short Iron    - mid/short approaches into the green
	        WG  Wedge         - pitches, chips and bunker shots
	        PT  Putter        - rolling the ball on the green
	     Each category carries its ball-flight personality (launch angle, backspin,
	     full-power carry). Product clubs in ClubDatabase only add stats on top.

	  2. the three club STATS (0-100) and exactly what each one does:
	        Power     ball speed:  speed *= 1 + PowerSpeedPerPoint * (Power - 50)
	                  (BaseCarryYds below is the carry at Power 50)
	        Accuracy  wider "perfect" timing window and less hook/slice on a miss
	                  (applied in SwingMath)
	        Spin      grip and control:
	                    * landing check: the backspin brake on landing is multiplied by
	                      gripFactor = 1 + SpinGripPerPoint * (Spin - 50)
	                      -> high Spin stops the ball quickly on the green
	                    * bad lies: a lie's accuracy penalty is reduced by
	                      LieSpinReduction * Spin/100 (spin the ball out of rough/sand)
	                  Spin never changes carry, so club reach stays predictable.

	  3. the upgrade economy and the OVR rating:
	        stat(level) = min(StatCap, base + level * PointsPerUpgrade)
	        cost(level) = round_to_50(UpgradeCostBase * UpgradeCostGrowth ^ level)
	        OVR         = 0.4 * Power + 0.3 * Accuracy + 0.3 * Spin   (Config.Clubs)

	Everything that needs club behaviour (SwingMath, ClubAdvisor, bots, UI) reads it
	from here, so rebalancing a category or a stat is a one-line change.
]]

local Types = require(script.Parent.Types)
local Config = require(script.Parent.Config)
local TableUtil = require(script.Parent.TableUtil)

export type Stats = {
	Power: number,
	Accuracy: number,
	Spin: number,
}

export type Category = {
	Label: string, -- two-letter key used in profiles, remotes and the UI ("DR", "FW", ...)
	Class: Types.ClubClass, -- the category id (also the club-skin slot)
	DisplayName: string,
	Blurb: string, -- one line for the loadout screen
	LoftDeg: number,
	-- Ball launch angle (degrees above horizontal). Lower than loft on long clubs.
	LaunchDeg: number,
	-- Backspin at launch (rpm) for a full-power fairway shot. Drives lift and how
	-- hard the ball checks up on landing. Putter is 0.
	BackspinRpm: number,
	-- Full-power (100%) carry in yards at Power 50 from a flat fairway, no wind.
	-- Putter is 0: putting uses a roll-speed model (Config.Swing.PuttFullPowerYards).
	BaseCarryYds: number,
}

export type StatInfo = {
	Id: Types.StatId,
	DisplayName: string,
	Blurb: string,
}

local ClubStats = {}

-- ---------------------------------------------------------------------------
-- 1) The six categories, in bag order (longest club first, putter last).
--    Carries step ~35 yds apart; the power gauge covers everything in between.
-- ---------------------------------------------------------------------------
local CATEGORIES: { Category } = {
	{ Label = "DR", Class = "Driver", DisplayName = "Driver", Blurb = "Maximum distance off the tee.", LoftDeg = 10.5, LaunchDeg = 11.5, BackspinRpm = 2450, BaseCarryYds = 250 },
	{ Label = "FW", Class = "FairwayWood", DisplayName = "Fairway Wood", Blurb = "Long second shots from the short grass.", LoftDeg = 16, LaunchDeg = 11.5, BackspinRpm = 3900, BaseCarryYds = 220 },
	{ Label = "LI", Class = "LongIron", DisplayName = "Long Iron", Blurb = "Controlled, piercing long approaches.", LoftDeg = 26, LaunchDeg = 13.5, BackspinRpm = 5100, BaseCarryYds = 185 },
	{ Label = "SI", Class = "ShortIron", DisplayName = "Short Iron", Blurb = "Accurate approaches into the green.", LoftDeg = 38, LaunchDeg = 18.5, BackspinRpm = 7400, BaseCarryYds = 150 },
	{ Label = "WG", Class = "Wedge", DisplayName = "Wedge", Blurb = "High, soft pitches, chips and bunker shots.", LoftDeg = 52, LaunchDeg = 28, BackspinRpm = 9800, BaseCarryYds = 110 },
	{ Label = "PT", Class = "Putter", DisplayName = "Putter", Blurb = "Rolls the ball on the green.", LoftDeg = 3, LaunchDeg = 0, BackspinRpm = 0, BaseCarryYds = 0 },
}

local byLabel: { [string]: Category } = {}
local byClass: { [string]: Category } = {}
for _, category in CATEGORIES do
	byLabel[category.Label] = category
	byClass[category.Class] = category
end

ClubStats.Categories = TableUtil.deepFreeze(CATEGORIES) :: { Category }
ClubStats.PUTTER = "PT"
ClubStats.DRIVER = "DR"

-- Category by its two-letter label; nil for anything else (safe on untrusted input).
function ClubStats.get(label: any): Category?
	if type(label) ~= "string" then
		return nil
	end
	return byLabel[label]
end

function ClubStats.forClass(class: Types.ClubClass): Category
	return byClass[class]
end

-- ---------------------------------------------------------------------------
-- 2) Stats
-- ---------------------------------------------------------------------------
ClubStats.StatIds = { "Power", "Accuracy", "Spin" } :: { Types.StatId }
ClubStats.StatInfo = TableUtil.deepFreeze({
	{ Id = "Power", DisplayName = "POWER", Blurb = "Ball speed and carry distance." },
	{ Id = "Accuracy", DisplayName = "ACCURACY", Blurb = "Bigger perfect zone, less hook and slice." },
	{ Id = "Spin", DisplayName = "SPIN", Blurb = "Stops the ball on greens; escapes bad lies." },
} :: { StatInfo }) :: { StatInfo }

-- A neutral stat line (every stat at the baseline): carries match BaseCarryYds.
function ClubStats.baseline(): Stats
	local b = Config.Swing.StatBaseline
	return { Power = b, Accuracy = b, Spin = b }
end

-- Ball-speed multiplier from Power.
function ClubStats.speedFactor(power: number): number
	local S = Config.Swing
	return 1 + S.PowerSpeedPerPoint * (math.clamp(power, 0, 100) - S.StatBaseline)
end

-- Landing-brake multiplier from Spin (1 at the baseline).
function ClubStats.gripFactor(spin: number): number
	local S = Config.Swing
	return 1 + S.SpinGripPerPoint * (math.clamp(spin, 0, 100) - S.StatBaseline)
end

-- A lie's accuracy penalty after Spin: 0 (clean lie) .. 0.45 (sand, Spin 0).
function ClubStats.liePenalty(lie: Types.LieId, spin: number): number
	local base = Config.Lies[lie].AccuracyPenalty
	return base * (1 - Config.Swing.LieSpinReduction * math.clamp(spin, 0, 100) / 100)
end

-- ---------------------------------------------------------------------------
-- 3) Upgrades & OVR
-- ---------------------------------------------------------------------------

-- Effective stat after `level` upgrades.
function ClubStats.statAtLevel(base: number, level: number): number
	local cfg = Config.Clubs
	return math.min(cfg.StatCap, base + level * cfg.PointsPerUpgrade)
end

-- Coins to raise one stat from `level` to `level + 1`; nil at MaxUpgradeLevel.
-- Defaults: 500, 700, 900, 1250, 1650, 2250, 3050, 4100, 5500, 7450.
function ClubStats.upgradeCost(level: number): number?
	local cfg = Config.Clubs
	if level >= cfg.MaxUpgradeLevel then
		return nil
	end
	local raw = cfg.UpgradeCostBase * cfg.UpgradeCostGrowth ^ level
	return math.floor(raw / 50 + 0.5) * 50
end

-- Overall rating from three (level-adjusted) stats.
function ClubStats.overall(s: Stats): number
	local w = Config.Clubs.OVRWeights
	return math.floor(s.Power * w.Power + s.Accuracy * w.Accuracy + s.Spin * w.Spin + 0.5)
end

return ClubStats
