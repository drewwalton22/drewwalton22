--!strict
--[[
	ZoneRewards.luau  (ReplicatedStorage.GolfRivals.Shared)

	Coin faucets in the lobby - the DRIVING RANGE and the AFK LOUNGE - with the
	anti-abuse rules both share:

	  * Daily caps per zone (Config.Range.DailyCoinCap / Config.Afk.DailyCoinCap),
	    tracked in profile.Earnings and reset when the UTC day changes
	    (day = floor(os.time() / 86400)). A payout is clamped to what is left.
	  * AFK pays per FULL uninterrupted TickSeconds inside the lounge. Stepping out
	    restarts the timer, so walking in and out can't farm partial ticks.
	  * Everything here is server-side bookkeeping; clients are only told results.

	Pure (mutates the profile through ProfileOps only); tested offline.
]]

local Config = require(script.Parent.Config)
local ProfileOps = require(script.Parent.ProfileOps)
local ProfileTemplate = require(script.Parent.ProfileTemplate)

type ProfileData = ProfileTemplate.ProfileData

export type Zone = "Range" | "Afk"

-- Per-player AFK timer (kept by the server, not saved).
export type AfkTimer = {
	NextPayAt: number?, -- nil while outside the lounge
}

local ZoneRewards = {}

local SECONDS_PER_DAY = 86400

function ZoneRewards.dayOf(unixTime: number): number
	return math.floor(unixTime / SECONDS_PER_DAY)
end

local function capOf(zone: Zone): number
	return if zone == "Range" then Config.Range.DailyCoinCap else Config.Afk.DailyCoinCap
end

-- Reset today's counters when the day rolled over.
local function roll(data: ProfileData, unixTime: number)
	local today = ZoneRewards.dayOf(unixTime)
	if data.Earnings.Day ~= today then
		data.Earnings.Day = today
		data.Earnings.Range = 0
		data.Earnings.Afk = 0
	end
end

function ZoneRewards.earnedToday(data: ProfileData, zone: Zone, unixTime: number): number
	roll(data, unixTime)
	return if zone == "Range" then data.Earnings.Range else data.Earnings.Afk
end

function ZoneRewards.remaining(data: ProfileData, zone: Zone, unixTime: number): number
	return math.max(0, capOf(zone) - ZoneRewards.earnedToday(data, zone, unixTime))
end

function ZoneRewards.cap(zone: Zone): number
	return capOf(zone)
end

-- Pays up to `coins` from a zone, respecting today's cap. Returns what was paid.
function ZoneRewards.pay(data: ProfileData, zone: Zone, coins: number, unixTime: number): number
	if type(coins) ~= "number" or coins ~= coins or coins < 1 then
		return 0
	end
	local amount = math.min(math.floor(coins), ZoneRewards.remaining(data, zone, unixTime))
	if amount < 1 then
		return 0
	end
	local ok = ProfileOps.add(data, "Coins", amount)
	if not ok then
		return 0
	end
	if zone == "Range" then
		data.Earnings.Range += amount
	else
		data.Earnings.Afk += amount
	end
	return amount
end

-- One AFK sample: is the player inside the lounge right now? Returns the new
-- timer and how many ticks are due (0 or 1 per sample; a late sample never
-- back-pays ticks the player didn't sit through with checks).
function ZoneRewards.afkStep(timer: AfkTimer, inside: boolean, now: number): (AfkTimer, number)
	if not inside then
		return { NextPayAt = nil }, 0
	end
	local nextPayAt = timer.NextPayAt
	if nextPayAt == nil then
		return { NextPayAt = now + Config.Afk.TickSeconds }, 0
	end
	if now >= nextPayAt then
		return { NextPayAt = now + Config.Afk.TickSeconds }, 1
	end
	return { NextPayAt = nextPayAt }, 0
end

-- Seconds until the next AFK payout (for the lounge HUD), nil when outside.
function ZoneRewards.afkSecondsLeft(timer: AfkTimer, now: number): number?
	if timer.NextPayAt == nil then
		return nil
	end
	return math.max(0, (timer.NextPayAt :: number) - now)
end

return ZoneRewards
