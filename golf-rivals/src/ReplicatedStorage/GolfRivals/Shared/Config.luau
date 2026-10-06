--!strict
--[[
	Config.luau  (ReplicatedStorage.GolfRivals.Shared)

	Global tuning knobs. Everything a designer might want to rebalance lives
	here (not buried in system code). Sections are filled in as each system is
	built; swing physics, bots and quests get their own sections later.
]]

local Types = require(script.Parent.Types)

export type LeagueDef = {
	Id: string,
	DisplayName: string,
	EntryFee: number, -- coins each player pays to queue
	WinPayout: number, -- coins the winner receives
}

local Config = {}

-- ECONOMY ---------------------------------------------------------------
Config.Economy = {
	StartingCoins = 2500,
	StartingGems = 0,
	-- Cap on cases opened in one request (the "Open x3" UI + anti-spam).
	MaxCasesPerOpen = 10,
}

-- DAILY ROTATING SHOP ---------------------------------------------------
-- Rotation index = floor(os.time() / RotationSeconds). Every server computes
-- the same index from the same clock, so all servers show the same shop with
-- no cross-server messaging. The server seeds an RNG with that index and
-- draws SlotsPerRarity items (from a deterministically sorted pool) per tier.
Config.Shop = {
	RotationSeconds = 24 * 60 * 60,
	SlotsPerRarity = {
		Common = 3,
		Uncommon = 3,
		Rare = 2,
		Unique = 2,
		Legendary = 1,
		Mythical = 1,
	} :: { [Types.RarityId]: number },
}

-- TRADE-UP CONTRACT -----------------------------------------------------
Config.TradeUp = {
	InputCount = 5, -- items consumed per contract
	-- true: all 5 inputs must share a category (club skins with club skins...)
	-- and the reward is rolled from that same category.
	RequireSameCategory = true,
}

-- CLUB UPGRADES ---------------------------------------------------------
-- Each club has three stats, each upgraded independently with coins.
--   stat(level) = min(StatCap, base + level * PointsPerUpgrade)
--   cost(level -> level+1) = round_to_50( CostBase * CostGrowth ^ level )
Config.Clubs = {
	StatCap = 100,
	MaxUpgradeLevel = 10,
	PointsPerUpgrade = 2,
	UpgradeCostBase = 500,
	UpgradeCostGrowth = 1.35,
	-- Overall (OVR) = weighted stat average. 0.4/0.3/0.3 reproduces the mockup:
	-- Distance 92, Accuracy 78, Forgiveness 85 -> 36.8 + 23.4 + 25.5 = 85.7 -> 86.
	OVRWeights = { Distance = 0.4, Accuracy = 0.3, Forgiveness = 0.3 },
}

-- RANKED LEAGUES --------------------------------------------------------
-- Both players pay EntryFee; the winner takes WinPayout.
--   WinPayout == 2 * EntryFee  -> zero-sum (the pot), no coins minted.
--   WinPayout >  2 * EntryFee  -> the difference is minted (a coin faucet).
-- Rookie/Amateur/Pro are zero-sum. Champion pays 25,000 on a 10,000 fee, so
-- it mints 5,000 coins per match (matches the design mockup). That is a
-- deliberate top-league reward; MaxPayoutMultiplier caps how generous any
-- league may get and DatabaseValidator rejects anything above it.
Config.LeagueRules = {
	MaxPayoutMultiplier = 2.5, -- WinPayout / EntryFee must be <= this
}
Config.Leagues = {
	{ Id = "Rookie", DisplayName = "Rookie League", EntryFee = 100, WinPayout = 200 },
	{ Id = "Amateur", DisplayName = "Amateur League", EntryFee = 500, WinPayout = 1000 },
	{ Id = "Pro", DisplayName = "Pro League", EntryFee = 2500, WinPayout = 5000 },
	{ Id = "Champion", DisplayName = "Champion League", EntryFee = 10000, WinPayout = 25000 },
} :: { LeagueDef }

return Config
