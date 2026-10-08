--!strict
--[[
	MatchSettlement.luau  (ServerScriptService.GolfRivals.Server)

	Turns a finished match into profile changes. Pure, so the money rules are
	testable.

	RANKED (both players paid LeagueDef.EntryFee when they queued)
	  winner  -> credited WinPayout
	  loser   -> nothing (the fee is already gone)
	  draw    -> each player's EntryFee is refunded (no money moves)
	  abandoned (nobody left to win) -> nothing
	  Net effect: WinPayout == 2 x EntryFee is zero-sum; a payout above that is a
	  deliberate mint (Champion league) capped by Config.LeagueRules.

	BOT PRACTICE
	  No fee and NO coin payout - bots can't be farmed. Matches still count toward
	  MatchesPlayed / HolesPlayed (and later quests); Wins/Losses are ranked-only.

	Refunds go through ProfileOps.refund (not .add) so returning your own entry fee
	doesn't inflate the TotalCoinsEarned stat.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage") -- OFFLINE-STRIP
local Shared = ReplicatedStorage.GolfRivals.Shared -- OFFLINE-STRIP
local Config = require(Shared.Config)
local ProfileOps = require(Shared.ProfileOps)
local ProfileTemplate = require(Shared.ProfileTemplate)
local MatchEngine = require(script.Parent.MatchEngine)

export type Mode = "Ranked" | "Bot"

export type Outcome = {
	PlayerId: string,
	Won: boolean,
	Lost: boolean,
	Drew: boolean,
	Winnings: number, -- coins earned (counts toward TotalCoinsEarned)
	Refund: number, -- coins returned (entry fee on a draw)
	Ranked: boolean,
	LeagueId: string?, -- the league played (ranked only)
}

-- What the engine/service observed for one player, beyond win/loss.
export type PlayStats = {
	HolesPlayed: number,
	HolesInOne: number,
	LongestDriveYds: number,
	FairwaysHit: number,
}

local MatchSettlement = {}

function MatchSettlement.settle(result: MatchEngine.MatchResult, mode: Mode, league: Config.LeagueDef?, playerIds: { string }): { [string]: Outcome }
	local outcomes: { [string]: Outcome } = {}
	local ranked = mode == "Ranked" and league ~= nil
	for _, id in playerIds do
		local won = result.WinnerId == id
		local drew = result.Draw
		local outcome: Outcome = {
			PlayerId = id,
			Won = won,
			Lost = not won and not drew and result.WinnerId ~= nil,
			Drew = drew,
			Winnings = 0,
			Refund = 0,
			Ranked = ranked,
			LeagueId = if ranked and league then league.Id else nil,
		}
		if ranked and league then
			if won then
				outcome.Winnings = league.WinPayout
			elseif drew then
				outcome.Refund = league.EntryFee
			end
		end
		outcomes[id] = outcome
	end
	return outcomes
end

-- Apply one player's outcome and play stats to their profile. Returns the coins
-- credited in total (for notifications).
function MatchSettlement.applyToProfile(data: ProfileTemplate.ProfileData, outcome: Outcome, play: PlayStats): number
	local stats = data.Stats
	stats.MatchesPlayed += 1
	stats.HolesPlayed += play.HolesPlayed
	stats.HolesInOne += play.HolesInOne
	stats.FairwaysHit += play.FairwaysHit
	stats.LongestDriveYds = math.max(stats.LongestDriveYds, math.floor(play.LongestDriveYds))
	if outcome.Ranked then
		if outcome.Won then
			stats.Wins += 1
			-- Per-league win counters ("Win 3 matches in the Pro League" quests).
			local key = (outcome.LeagueId or "") .. "Wins"
			local counters = stats :: any
			if type(counters[key]) == "number" then
				counters[key] += 1
			end
		elseif outcome.Lost then
			stats.Losses += 1
		end
	end
	local credited = 0
	if outcome.Winnings > 0 then
		ProfileOps.add(data, "Coins", outcome.Winnings)
		credited += outcome.Winnings
	end
	if outcome.Refund > 0 then
		ProfileOps.refund(data, "Coins", outcome.Refund)
		credited += outcome.Refund
	end
	return credited
end

return MatchSettlement
