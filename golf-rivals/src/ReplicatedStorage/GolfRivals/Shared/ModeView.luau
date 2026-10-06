--!strict
--[[
	ModeView.luau  (ReplicatedStorage.GolfRivals.Shared)

	The Matchmaking / Leagues screen (mockup panel 8) plus the bot practice picker:
	league cards with entry fee and winnings, affordability, and the queue timer text.
]]

local Config = require(script.Parent.Config)
local Format = require(script.Parent.Format)
local ProfileOps = require(script.Parent.ProfileOps)
local ProfileTemplate = require(script.Parent.ProfileTemplate)

export type LeagueCard = {
	Id: string,
	DisplayName: string,
	EntryFee: number,
	WinPayout: number,
	FeeText: string,
	PayoutText: string,
	CanAfford: boolean,
	Shortfall: number, -- coins missing (0 when affordable)
}

export type BotCard = {
	Difficulty: string,
	Label: string,
	Blurb: string,
	Ovr: number,
}

local ModeView = {}

function ModeView.leagues(profile: ProfileTemplate.ProfileData): { LeagueCard }
	local cards: { LeagueCard } = {}
	for _, league in Config.Leagues do
		local canAfford = ProfileOps.canAfford(profile, { Currency = "Coins", Amount = league.EntryFee })
		table.insert(cards, {
			Id = league.Id,
			DisplayName = league.DisplayName,
			EntryFee = league.EntryFee,
			WinPayout = league.WinPayout,
			FeeText = Format.commas(league.EntryFee),
			PayoutText = Format.commas(league.WinPayout),
			CanAfford = canAfford,
			Shortfall = math.max(0, league.EntryFee - profile.Coins),
		})
	end
	return cards
end

local BLURBS: { [string]: string } = {
	Easy = "Relaxed rounds. Great for learning the swing.",
	Medium = "Reads the wind and avoids trouble most of the time.",
	Hard = "Plays smart golf and rarely misses the green zone.",
}

function ModeView.bots(): { BotCard }
	local cards: { BotCard } = {}
	for _, difficulty in Config.BotDifficulties do
		local stats = Config.Bots[difficulty].Stats
		local weights = Config.Clubs.OVRWeights
		table.insert(cards, {
			Difficulty = difficulty,
			Label = string.upper(difficulty),
			Blurb = BLURBS[difficulty] or "",
			Ovr = math.floor(stats.Distance * weights.Distance + stats.Accuracy * weights.Accuracy + stats.Forgiveness * weights.Forgiveness + 0.5),
		})
	end
	return cards
end

function ModeView.queueText(secondsWaiting: number): string
	return "SEARCHING FOR AN OPPONENT  " .. Format.clock(secondsWaiting)
end

return ModeView
