--!strict
-- ROBLOX-ONLY: binds remotes and os.time. Quest rules live in the pure QuestEngine.
--[[
	QuestService.luau  (ServerScriptService.GolfRivals.Server)

	  GetQuests()          Daily / Weekly / Lifetime quests with live progress
	                       (starts a new period first if the old one has ended)
	  ClaimQuest(questId)  validate (complete, active, not yet claimed), pay the coin /
	                       gem reward, mark it claimed, push the new balances

	Progress comes from the profile's lifetime counters, so nothing here needs to hear
	about gameplay events.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Logger = require(Shared.Logger)
local ProfileTemplate = require(Shared.ProfileTemplate)
local QuestEngine = require(Shared.QuestEngine)
local Remotes = require(Shared.Remotes)
local ProfileService = require(script.Parent.ProfileService)

local QuestService = {}

local function indexOf(data: ProfileTemplate.ProfileData, period: string): number
	local state = (data.Quests :: any)[period]
	return if type(state) == "table" and type(state.Index) == "number" then state.Index else -1
end

function QuestService.start()
	Remotes.onInvoke("GetQuests", function(player: Player)
		local data = ProfileService.get(player)
		if data == nil then
			return { ok = false, reason = "not_loaded" }
		end
		local now = os.time()
		local dailyBefore, weeklyBefore = indexOf(data, "Daily"), indexOf(data, "Weekly")
		local periods = QuestEngine.list(data, now)
		-- A new day/week was just started: persist it (and tell the client).
		if indexOf(data, "Daily") ~= dailyBefore or indexOf(data, "Weekly") ~= weeklyBefore then
			ProfileService.saveSoon(player)
		end
		return { ok = true, Periods = periods, Now = now }
	end)

	Remotes.onInvoke("ClaimQuest", function(player: Player, questId: any)
		local data = ProfileService.get(player)
		if data == nil then
			return { ok = false, reason = "not_loaded" }
		end
		local ok, reason, reward = QuestEngine.claim(data, questId, os.time())
		if not ok then
			return { ok = false, reason = reason }
		end
		ProfileService.notify(player, { Coins = data.Coins, Gems = data.Gems })
		ProfileService.saveSoon(player)
		return { ok = true, Reward = reward }
	end)

	Logger.info("Quests", "Quest service started (daily / weekly / lifetime).")
end

return QuestService
