--!strict
--[[
	QuestEngine.luau  (ReplicatedStorage.GolfRivals.Shared)

	Quest state, progress and claiming on a profile (pure; the server calls it, and
	it never needs the clock except through the `now` argument).

	STATE  profile.Quests = {
	    Daily    = { Index, Ids, Baseline, Claimed },
	    Weekly   = { Index, Ids, Baseline, Claimed },
	    Lifetime = { Claimed },
	}
	  Index     UTC day number (daily) or Monday-start week number (weekly)
	  Ids       the quests active this period (picked by a seeded draw, so every
	            player sees the same set and it can't be rerolled by rejoining)
	  Baseline  copy of the numeric Stats when the period began
	  Claimed   questId -> true

	ROLLOVER  `refresh` replaces a stale period with a new one (new quests, fresh
	baseline, nothing claimed). Unclaimed rewards from a finished period are lost.

	WEEKS  Unix day 0 (1970-01-01) was a Thursday, so a Monday-start week index is
	floor((day + 3) / 7) and the next week begins on day 7*(index+1) - 3.
]]

local Config = require(script.Parent.Config)
local ProfileOps = require(script.Parent.ProfileOps)
local ProfileTemplate = require(script.Parent.ProfileTemplate)
local Prng = require(script.Parent.Prng)
local QuestDatabase = require(script.Parent.QuestDatabase)
local TableUtil = require(script.Parent.TableUtil)

type ProfileData = ProfileTemplate.ProfileData

export type QuestView = {
	Id: string,
	Period: QuestDatabase.Period,
	Name: string,
	Progress: number, -- clamped to Target for display
	Target: number,
	Complete: boolean,
	Claimed: boolean,
	Reward: QuestDatabase.Reward,
}

export type PeriodView = {
	Period: QuestDatabase.Period,
	Quests: { QuestView },
	ResetsAt: number?, -- unix seconds (nil for lifetime)
}

local QuestEngine = {}

local DAY = Config.Shop.RotationSeconds -- 86,400 s

function QuestEngine.dayIndex(now: number): number
	return math.floor(now / DAY)
end

function QuestEngine.weekIndex(now: number): number
	return math.floor((QuestEngine.dayIndex(now) + 3) / 7)
end

function QuestEngine.resetsAt(period: QuestDatabase.Period, now: number): number?
	if period == "Daily" then
		return (QuestEngine.dayIndex(now) + 1) * DAY
	elseif period == "Weekly" then
		return (7 * (QuestEngine.weekIndex(now) + 1) - 3) * DAY
	end
	return nil
end

local function currentIndex(period: QuestDatabase.Period, now: number): number
	return if period == "Daily" then QuestEngine.dayIndex(now) else QuestEngine.weekIndex(now)
end

-- Deterministic distinct picks from a sorted pool (partial Fisher-Yates).
local function pick(pool: { QuestDatabase.QuestDef }, count: number, seed: number): { string }
	local bag = table.clone(pool)
	local prng = Prng.new(seed)
	local ids: { string } = {}
	for i = 1, math.min(count, #bag) do
		local j = i + math.floor(prng.next() * (#bag - i + 1))
		bag[i], bag[j] = bag[j], bag[i]
		table.insert(ids, bag[i].Id)
	end
	return ids
end

local function numericStats(data: ProfileData): { [string]: number }
	local copy: { [string]: number } = {}
	for key, value in data.Stats :: any do
		if type(value) == "number" then
			copy[key] = value
		end
	end
	return copy
end

-- Make sure Daily/Weekly describe the CURRENT period, starting fresh ones as needed.
function QuestEngine.refresh(data: ProfileData, now: number)
	local quests = data.Quests :: any
	if type(quests.Lifetime) ~= "table" or type(quests.Lifetime.Claimed) ~= "table" then
		quests.Lifetime = { Claimed = {} }
	end
	for _, period in { "Daily", "Weekly" } :: { QuestDatabase.Period } do
		local index = currentIndex(period, now)
		local state = quests[period]
		if type(state) ~= "table" or state.Index ~= index or type(state.Ids) ~= "table" or type(state.Baseline) ~= "table" or type(state.Claimed) ~= "table" then
			local count = if period == "Daily" then QuestDatabase.DailyCount else QuestDatabase.WeeklyCount
			local salt = if period == "Daily" then 104729 else 130363
			quests[period] = {
				Index = index,
				Ids = pick(QuestDatabase.Pools[period], count, index * 7919 + salt),
				Baseline = numericStats(data),
				Claimed = {},
			}
		end
	end
end

local function progressOf(data: ProfileData, def: QuestDatabase.QuestDef, baseline: { [string]: number }?): number
	local current = (data.Stats :: any)[def.Stat]
	if type(current) ~= "number" then
		return 0
	end
	if def.Kind == "Value" or baseline == nil then
		return current
	end
	return math.max(0, current - (baseline[def.Stat] or 0))
end

local function viewOf(data: ProfileData, def: QuestDatabase.QuestDef, baseline: { [string]: number }?, claimed: { [string]: boolean }): QuestView
	local progress = progressOf(data, def, baseline)
	return {
		Id = def.Id,
		Period = def.Period,
		Name = def.Name,
		Progress = math.min(progress, def.Target),
		Target = def.Target,
		Complete = progress >= def.Target,
		Claimed = claimed[def.Id] == true,
		Reward = def.Reward,
	}
end

-- All three periods as the UI shows them. Starts new periods if needed (mutates).
function QuestEngine.list(data: ProfileData, now: number): { PeriodView }
	QuestEngine.refresh(data, now)
	local quests = data.Quests :: any
	local result: { PeriodView } = {}
	for _, period in { "Daily", "Weekly" } :: { QuestDatabase.Period } do
		local state = quests[period]
		local views: { QuestView } = {}
		for _, id in state.Ids do
			local def = QuestDatabase.ById[id]
			if def then
				table.insert(views, viewOf(data, def, state.Baseline, state.Claimed))
			end
		end
		local view: PeriodView = { Period = period, Quests = views, ResetsAt = QuestEngine.resetsAt(period, now) }
		table.insert(result, view)
	end
	local lifetime: { QuestView } = {}
	for _, def in QuestDatabase.Pools.Lifetime do
		table.insert(lifetime, viewOf(data, def, nil, quests.Lifetime.Claimed))
	end
	local lifetimeView: PeriodView = { Period = "Lifetime", Quests = lifetime, ResetsAt = nil }
	table.insert(result, lifetimeView)
	return result
end

-- How many finished-but-unclaimed quests there are (for the lobby badge).
function QuestEngine.claimable(data: ProfileData, now: number): number
	local count = 0
	for _, period in QuestEngine.list(data, now) do
		for _, view in period.Quests do
			if view.Complete and not view.Claimed then
				count += 1
			end
		end
	end
	return count
end

-- Claim a finished quest. Returns (true, nil, reward) or (false, reason).
function QuestEngine.claim(data: ProfileData, questId: any, now: number): (boolean, string?, QuestDatabase.Reward?)
	local def = QuestDatabase.get(questId)
	if def == nil then
		return false, "unknown_quest", nil
	end
	QuestEngine.refresh(data, now)
	local quests = data.Quests :: any
	local baseline: { [string]: number }? = nil
	local claimed: { [string]: boolean }
	if def.Period == "Lifetime" then
		claimed = quests.Lifetime.Claimed
	else
		local state = quests[def.Period]
		if table.find(state.Ids, def.Id) == nil then
			return false, "not_active", nil
		end
		baseline, claimed = state.Baseline, state.Claimed
	end
	if claimed[def.Id] then
		return false, "already_claimed", nil
	end
	if progressOf(data, def, baseline) < def.Target then
		return false, "not_complete", nil
	end

	-- Grant first, mark claimed only after everything succeeded.
	local snapshot = TableUtil.deepCopy(data)
	local okCoins, okGems = true, true
	if def.Reward.Coins then
		okCoins = ProfileOps.grant(data, "Coins", def.Reward.Coins)
	end
	if def.Reward.Gems then
		okGems = ProfileOps.grant(data, "Gems", def.Reward.Gems)
	end
	if not (okCoins and okGems) then
		local live = data :: any
		for key in live do
			live[key] = nil
		end
		for key, value in snapshot do
			live[key] = value
		end
		return false, "grant_failed", nil
	end
	claimed[def.Id] = true
	return true, nil, def.Reward
end

return QuestEngine
