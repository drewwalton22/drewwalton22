--!strict
-- ROBLOX-ONLY: OrderedDataStore and Players APIs.
--[[
	LeaderboardService.luau  (ServerScriptService.GolfRivals.Server)

	The lobby leaderboard: top players by OVR (average rating of their equipped bag).

	  * OVR is written to an OrderedDataStore when a profile loads and when the player
	    leaves (only if it changed), so the board reflects the whole game, not just
	    this server.
	  * A background loop refreshes the top 25 every 60 s; the GetLeaderboard remote
	    returns the cached copy (no DataStore call per request).
	  * Names are resolved once and cached.
	  * If the OrderedDataStore is unavailable (Studio without API access, outage) the
	    board falls back to the players on this server so it is never empty.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Logger = require(Shared.Logger)
local ProfileOps = require(Shared.ProfileOps)
local ProfileTemplate = require(Shared.ProfileTemplate)
local Remotes = require(Shared.Remotes)
local ProfileService = require(script.Parent.ProfileService)

type ProfileData = ProfileTemplate.ProfileData

export type Entry = { Rank: number, UserId: number, Name: string, Ovr: number }

local LeaderboardService = {}

local STORE_NAME = "GolfRivalsOvr_v1"
local TOP_COUNT = 25
local REFRESH_SECONDS = 60

local store = DataStoreService:GetOrderedDataStore(STORE_NAME)
local entries: { Entry } = {}
local nameCache: { [number]: string } = {}
local lastSent: { [number]: number } = {}
local firstLoadDone = false

local function nameFor(userId: number): string
	local cached = nameCache[userId]
	if cached then
		return cached
	end
	local player = Players:GetPlayerByUserId(userId)
	if player then
		nameCache[userId] = player.DisplayName
		return player.DisplayName
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	local resolved = if ok and type(name) == "string" then name else `Player {userId}`
	nameCache[userId] = resolved
	return resolved
end

local function publish(player: Player, data: ProfileData)
	local ovr = ProfileOps.playerOvr(data)
	if lastSent[player.UserId] == ovr then
		return
	end
	local ok, err = pcall(function()
		store:SetAsync(tostring(player.UserId), ovr)
		return true
	end)
	if ok then
		lastSent[player.UserId] = ovr
	else
		Logger.info("Leaderboard", `could not publish OVR for {player.Name}: {tostring(err)}`)
	end
end

-- Players on this server, best first (used when the global board can't be read).
local function localFallback(): { Entry }
	local list: { Entry } = {}
	for _, online in ProfileService.online() do
		table.insert(list, { Rank = 0, UserId = online.Player.UserId, Name = online.Player.DisplayName, Ovr = ProfileOps.playerOvr(online.Data) })
	end
	table.sort(list, function(a: Entry, b: Entry)
		return a.Ovr > b.Ovr
	end)
	for rank, entry in list do
		entry.Rank = rank
	end
	return list
end

local function refresh()
	local ok, page = pcall(function()
		return store:GetSortedAsync(false, TOP_COUNT):GetCurrentPage()
	end)
	if ok and type(page) == "table" then
		local list: { Entry } = {}
		for rank, record in page do
			local userId = tonumber(record.key)
			if userId and type(record.value) == "number" then
				table.insert(list, { Rank = rank, UserId = userId, Name = nameFor(userId), Ovr = record.value })
			end
		end
		entries = list
	else
		entries = localFallback()
	end
	firstLoadDone = true
end

function LeaderboardService.start()
	ProfileService.onLoaded(function(player: Player, data: ProfileData)
		task.spawn(publish, player, data)
	end)
	ProfileService.onLeaving(function(player: Player, data: ProfileData)
		task.spawn(publish, player, data)
	end)

	task.spawn(function()
		while true do
			refresh()
			task.wait(REFRESH_SECONDS)
		end
	end)

	Remotes.onInvoke("GetLeaderboard", function(player: Player)
		-- First request right after boot: give the initial refresh a moment.
		local waited = 0.0
		while not firstLoadDone and waited < 5 do
			task.wait(0.25)
			waited += 0.25
		end
		local data = ProfileService.get(player)
		return {
			ok = true,
			Entries = entries,
			YourOvr = if data then ProfileOps.playerOvr(data) else 0,
		}
	end)

	Logger.info("Leaderboard", "Leaderboard service started (OVR, top " .. TOP_COUNT .. ").")
end

return LeaderboardService
