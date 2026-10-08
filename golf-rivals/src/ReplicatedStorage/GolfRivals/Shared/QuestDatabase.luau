--!strict
--[[
	QuestDatabase.luau  (ReplicatedStorage.GolfRivals.Shared)

	Every quest. Progress is DERIVED from the player's lifetime stat counters
	(profile.Stats), so quests need no event hooks scattered through the game:

	    Delta quest  progress = Stats[stat] - Baseline[stat]
	                 (baseline = the counter when the day/week began; lifetime: 0)
	    Value quest  progress = Stats[stat]           (e.g. longest drive, a maximum)

	Periods
	  Daily     5 quests, chosen deterministically from the pool per UTC day
	  Weekly    3 quests per UTC week (Monday start)
	  Lifetime  all of them, forever; claim each once

	Rewards are Coins and/or Gems (spec). The `Stat` must be a numeric counter that
	exists in ProfileTemplate's Stats (verified by DatabaseValidator).
]]

export type Period = "Daily" | "Weekly" | "Lifetime"

export type Reward = {
	Coins: number?,
	Gems: number?,
}

export type QuestDef = {
	Id: string,
	Period: Period,
	Name: string,
	Stat: string,
	Kind: "Delta" | "Value",
	Target: number,
	Reward: Reward,
}

local QuestDatabase = {}

QuestDatabase.DailyCount = 5
QuestDatabase.WeeklyCount = 3

local function quest(id: string, period: Period, name: string, stat: string, target: number, reward: Reward, kind: ("Delta" | "Value")?): QuestDef
	return { Id = id, Period = period, Name = name, Stat = stat, Kind = kind or "Delta", Target = target, Reward = reward }
end

local list: { QuestDef } = {
	-- Daily pool (5 are active per day)
	quest("d_holes_10", "Daily", "Play 10 Holes", "HolesPlayed", 10, { Coins = 500 }),
	quest("d_earn_5000", "Daily", "Earn 5,000 Coins", "TotalCoinsEarned", 5000, { Gems = 10 }),
	quest("d_cases_2", "Daily", "Open 2 Cases", "CasesOpened", 2, { Coins = 300 }),
	quest("d_fairways_5", "Daily", "Hit 5 Fairways", "FairwaysHit", 5, { Coins = 250 }),
	quest("d_fairways_10", "Daily", "Hit 10 Fairways", "FairwaysHit", 10, { Coins = 600 }),
	quest("d_play_match", "Daily", "Finish a Match", "MatchesPlayed", 1, { Coins = 150 }),
	quest("d_upgrade", "Daily", "Upgrade a Club", "ClubUpgrades", 1, { Coins = 300 }),
	quest("d_shop_buy", "Daily", "Buy from the Daily Shop", "ShopPurchases", 1, { Coins = 200 }),
	quest("d_win_2", "Daily", "Win 2 Ranked Matches", "Wins", 2, { Coins = 700 }),
	quest("d_trade_up", "Daily", "Complete a Trade-Up", "TradeUps", 1, { Coins = 250 }),
	quest("d_cases_5", "Daily", "Open 5 Cases", "CasesOpened", 5, { Gems = 15 }),
	quest("d_rookie_win", "Daily", "Win a Rookie League Match", "RookieWins", 1, { Coins = 400 }),
	quest("d_holes_20", "Daily", "Play 20 Holes", "HolesPlayed", 20, { Coins = 900 }),

	-- Weekly pool (3 are active per week)
	quest("w_win_10", "Weekly", "Win 10 Ranked Matches", "Wins", 10, { Coins = 3000, Gems = 25 }),
	quest("w_holes_60", "Weekly", "Play 60 Holes", "HolesPlayed", 60, { Coins = 3500 }),
	quest("w_cases_15", "Weekly", "Open 15 Cases", "CasesOpened", 15, { Coins = 2500, Gems = 40 }),
	quest("w_earn_50000", "Weekly", "Earn 50,000 Coins", "TotalCoinsEarned", 50000, { Coins = 5000, Gems = 30 }),
	quest("w_fairways_50", "Weekly", "Hit 50 Fairways", "FairwaysHit", 50, { Coins = 3000 }),
	quest("w_pro_wins_3", "Weekly", "Win 3 Matches in the Pro League", "ProWins", 3, { Coins = 6000, Gems = 35 }),

	-- Lifetime achievements (all active, claim once)
	quest("l_first_win", "Lifetime", "Win Your First Ranked Match", "Wins", 1, { Coins = 500 }),
	quest("l_wins_25", "Lifetime", "Win 25 Ranked Matches", "Wins", 25, { Coins = 5000, Gems = 25 }),
	quest("l_holes_100", "Lifetime", "Play 100 Holes", "HolesPlayed", 100, { Coins = 2000 }),
	quest("l_holes_1000", "Lifetime", "Play 1,000 Holes", "HolesPlayed", 1000, { Coins = 15000, Gems = 75 }),
	quest("l_ace", "Lifetime", "Hole in One", "HolesInOne", 1, { Gems = 50 }),
	quest("l_drive_300", "Lifetime", "Drive the Ball 300 Yards", "LongestDriveYds", 300, { Gems = 25 }, "Value"),
	quest("l_cases_100", "Lifetime", "Open 100 Cases", "CasesOpened", 100, { Coins = 5000, Gems = 100 }),
	quest("l_trade_10", "Lifetime", "Complete 10 Trade-Ups", "TradeUps", 10, { Gems = 25 }),
	quest("l_champion", "Lifetime", "Win a Champion League Match", "ChampionWins", 1, { Gems = 100 }),
	quest("l_upgrades_50", "Lifetime", "Upgrade Clubs 50 Times", "ClubUpgrades", 50, { Coins = 4000, Gems = 30 }),
}

local byId: { [string]: QuestDef } = {}
local byPeriod: { [Period]: { QuestDef } } = { Daily = {}, Weekly = {}, Lifetime = {} }
for _, def in list do
	assert(byId[def.Id] == nil, "duplicate quest id " .. def.Id)
	byId[def.Id] = def
	table.insert(byPeriod[def.Period], def)
end
for _, pool in byPeriod do
	table.sort(pool, function(a: QuestDef, b: QuestDef)
		return a.Id < b.Id
	end)
end

QuestDatabase.All = list
QuestDatabase.ById = byId
QuestDatabase.Pools = byPeriod

function QuestDatabase.get(id: any): QuestDef?
	if type(id) ~= "string" then
		return nil
	end
	return byId[id]
end

return QuestDatabase
