--!strict
--[[
	Matchmaker.luau  (ServerScriptService.GolfRivals.Server)

	Ranked queues, one per league, pairing players of similar OVR.

	PAIRING (call findMatches every ~second)
	  Entries in a league are processed oldest-first. The oldest waiting player is
	  paired with the closest-OVR other player, provided the gap fits inside the
	  oldest player's acceptable window:

	      window(entry) = min(MaxOvrWindow, BaseOvrWindow + WindowGrowthPerSecond * secondsWaited)

	  so a fresh queue demands near-equal opponents, and the longer someone waits
	  the wider their net - nobody starves, and close matches are preferred while
	  traffic allows. Leagues never mix (entry fees differ).

	A player can be in at most one queue. `now` is injected (os.clock in game).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage") -- OFFLINE-STRIP
local Shared = ReplicatedStorage.GolfRivals.Shared -- OFFLINE-STRIP
local Config = require(Shared.Config)

export type Entry = {
	PlayerId: string,
	League: string,
	Ovr: number,
	QueuedAt: number,
}

export type Pair = {
	League: string,
	A: Entry, -- the longer-waiting player
	B: Entry,
}

export type Matchmaker = {
	enqueue: (playerId: string, league: string, ovr: number, now: number) -> boolean,
	dequeue: (playerId: string) -> Entry?,
	isQueued: (playerId: string) -> boolean,
	size: (league: string) -> number,
	-- Removes and returns every pair that can be made right now.
	findMatches: (now: number) -> { Pair },
}

local Matchmaker = {}

function Matchmaker.window(waitedSeconds: number): number
	local cfg = Config.Matchmaking
	return math.min(cfg.MaxOvrWindow, cfg.BaseOvrWindow + cfg.WindowGrowthPerSecond * math.max(0, waitedSeconds))
end

function Matchmaker.new(): Matchmaker
	local entries: { [string]: Entry } = {} -- by player id
	local sequence: { [string]: number } = {} -- arrival order, for stable tie-breaks
	local counter = 0

	local function enqueue(playerId: string, league: string, ovr: number, now: number): boolean
		if entries[playerId] ~= nil then
			return false -- already queued
		end
		counter += 1
		entries[playerId] = { PlayerId = playerId, League = league, Ovr = ovr, QueuedAt = now }
		sequence[playerId] = counter
		return true
	end

	local function dequeue(playerId: string): Entry?
		local entry = entries[playerId]
		entries[playerId] = nil
		sequence[playerId] = nil
		return entry
	end

	local function size(league: string): number
		local n = 0
		for _, entry in entries do
			if entry.League == league then
				n += 1
			end
		end
		return n
	end

	local function findMatches(now: number): { Pair }
		local found: { Pair } = {}

		-- Group by league, each group oldest-first.
		local byLeague: { [string]: { Entry } } = {}
		for _, entry in entries do
			byLeague[entry.League] = byLeague[entry.League] or {}
			table.insert(byLeague[entry.League], entry)
		end

		for league, group in byLeague do
			table.sort(group, function(a: Entry, b: Entry)
				return sequence[a.PlayerId] < sequence[b.PlayerId]
			end)
			local used: { [string]: boolean } = {}
			for i, oldest in group do
				if used[oldest.PlayerId] then
					continue
				end
				local allowed = Matchmaker.window(now - oldest.QueuedAt)
				local best: Entry? = nil
				local bestGap = math.huge
				for j = i + 1, #group do
					local candidate = group[j]
					if not used[candidate.PlayerId] then
						local gap = math.abs(candidate.Ovr - oldest.Ovr)
						-- Strictly better gap wins; on equal gaps the earlier arrival (lower j) stays.
						if gap <= allowed and gap < bestGap then
							best, bestGap = candidate, gap
						end
					end
				end
				if best then
					used[oldest.PlayerId] = true
					used[best.PlayerId] = true
					table.insert(found, { League = league, A = oldest, B = best })
					dequeue(oldest.PlayerId)
					dequeue(best.PlayerId)
				end
			end
		end
		return found
	end

	return {
		enqueue = enqueue,
		dequeue = dequeue,
		isQueued = function(playerId: string): boolean
			return entries[playerId] ~= nil
		end,
		size = size,
		findMatches = findMatches,
	}
end

return Matchmaker
