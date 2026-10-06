--!strict
-- ROBLOX-ONLY: binds remotes and reads character positions. The rules it applies
-- (targets, payouts, caps, AFK timing) are the offline-tested RangeRules,
-- ZoneRewards and LobbyLayout modules.
--[[
	ZoneService.luau  (ServerScriptService.GolfRivals.Server)

	The two lobby coin zones.

	DRIVING RANGE (west of the plaza)
	  RangeJoin(bayId)   take a free bay you are standing next to
	  RangeSwing(club, aim, power, offset)
	                     the server checks the swing timing (same anti-cheat as
	                     matches, measured from when this bay's next ball was ready),
	                     simulates the ball with the player's EQUIPPED club stats,
	                     and pays the target's coins for a ball at rest on a green,
	                     clamped to the daily cap. The reply carries the trajectory
	                     so the client can play swing -> impact -> flight.
	  RangeLeave()       give the bay back (also on leaving, idling, or queueing)

	AFK LOUNGE (south-east of the plaza)
	  Every CheckSeconds the server samples each character's position. A full,
	  uninterrupted TickSeconds on the lounge deck pays CoinsPerTick, up to the
	  daily cap. Players in a match or at a range bay don't earn here. Clients get a
	  ZoneStatus event on enter / leave / payout for the lounge HUD.

	Nothing a client sends can create coins: payouts come only from server-side
	simulation (range) or server-side position checks (AFK), both capped per day.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local ClubStats = require(Shared.ClubStats)
local Config = require(Shared.Config)
local LobbyLayout = require(Shared.LobbyLayout)
local Logger = require(Shared.Logger)
local ProfileOps = require(Shared.ProfileOps)
local ProfileTemplate = require(Shared.ProfileTemplate)
local RangeRules = require(Shared.RangeRules)
local Remotes = require(Shared.Remotes)
local SwingMath = require(Shared.SwingMath)
local Validate = require(Shared.Validate)
local ZoneRewards = require(Shared.ZoneRewards)
local MatchService = require(script.Parent.MatchService)
local ProfileService = require(script.Parent.ProfileService)

type ProfileData = ProfileTemplate.ProfileData

type BaySession = {
	Bay: RangeRules.Bay,
	ReadyAt: number, -- os.clock() when the next ball may be struck (gauge opens)
	LastActive: number,
}

local ZoneService = {}

local sessions: { [Player]: BaySession } = {}
local bayOwner: { [number]: Player } = {}
local afkTimers: { [Player]: ZoneRewards.AfkTimer } = {}

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	return if root and root:IsA("BasePart") then root else nil
end

local function pushEarnings(player: Player, data: ProfileData)
	ProfileService.notify(player, { Coins = data.Coins, Earnings = table.clone(data.Earnings), Stats = table.clone(data.Stats) })
	ProfileService.saveSoon(player)
end

local function releaseBay(player: Player, why: string?)
	local session = sessions[player]
	if session == nil then
		return
	end
	sessions[player] = nil
	if bayOwner[session.Bay.Id] == player then
		bayOwner[session.Bay.Id] = nil
	end
	if why and player.Parent == Players then
		Remotes.fireClient("Notify", player, why, "info")
	end
end

-- ---------------------------------------------------------------------------
-- Driving range
-- ---------------------------------------------------------------------------

local function onJoin(player: Player, bayId: any): any
	local data = ProfileService.get(player)
	if data == nil then
		return { ok = false, reason = "not_loaded" }
	end
	if MatchService.isBusy(player) then
		return { ok = false, reason = "busy" }
	end
	local bay = RangeRules.bay(bayId)
	if bay == nil then
		return { ok = false, reason = "unknown_bay" }
	end
	local owner = bayOwner[bay.Id]
	if owner and owner ~= player and owner.Parent == Players then
		return { ok = false, reason = "bay_taken" }
	end
	local root = rootOf(player)
	if root == nil then
		return { ok = false, reason = "no_character" }
	end
	local offset = Vector3.new(root.Position.X - RangeRules.ORIGIN.X, 0, root.Position.Z - bay.WorldZ)
	if offset.Magnitude > Config.Range.JoinRadiusStuds then
		return { ok = false, reason = "too_far" }
	end
	releaseBay(player, nil) -- switching bays
	local now = os.clock()
	sessions[player] = { Bay = bay, ReadyAt = now, LastActive = now }
	bayOwner[bay.Id] = player
	local unix = os.time()
	return { ok = true, BayId = bay.Id, Earned = ZoneRewards.earnedToday(data, "Range", unix), Cap = ZoneRewards.cap("Range") }
end

local function onSwing(player: Player, label: any, aimDeg: any, power: any, offset: any): any
	local session = sessions[player]
	if session == nil then
		return { ok = false, reason = "no_bay" }
	end
	local data = ProfileService.get(player)
	if data == nil then
		return { ok = false, reason = "not_loaded" }
	end
	local category = ClubStats.get(label)
	if category == nil or category.Class == "Putter" then
		return { ok = false, reason = "bad_club" }
	end
	if not Validate.numberInRange(aimDeg, -RangeRules.MaxAimDegrees, RangeRules.MaxAimDegrees) then
		return { ok = false, reason = "bad_aim" }
	end
	local now = os.clock()
	if now < session.ReadyAt then
		return { ok = false, reason = "ball_not_ready" }
	end
	local valid, why = SwingMath.validateSubmission(power, offset, now - session.ReadyAt)
	if not valid then
		return { ok = false, reason = why }
	end

	-- The player's own equipped club for that category (upgrades count here too).
	local clubId = data.EquippedClubs[category.Label]
	local stats = (clubId and ProfileOps.clubStats(data, clubId)) or ClubStats.baseline()
	local shot = RangeRules.resolve(session.Bay, category.Label, stats, power :: number, offset :: number, aimDeg :: number)
	if shot == nil then
		return { ok = false, reason = "bad_club" }
	end

	local unix = os.time()
	local paid = ZoneRewards.pay(data, "Range", shot.Coins, unix)
	if paid > 0 then
		pushEarnings(player, data)
	end
	session.ReadyAt = now + Config.Match.SwingLeadSeconds + shot.TotalSeconds + Config.Range.ReadyPadSeconds
	session.LastActive = now
	return {
		ok = true,
		Shot = shot,
		Paid = paid,
		ImpactDelay = Config.Match.SwingLeadSeconds,
		Earned = ZoneRewards.earnedToday(data, "Range", unix),
		Cap = ZoneRewards.cap("Range"),
	}
end

-- ---------------------------------------------------------------------------
-- AFK lounge + housekeeping loop
-- ---------------------------------------------------------------------------

local function sendAfkStatus(player: Player, data: ProfileData, timer: ZoneRewards.AfkTimer, now: number)
	local unix = os.time()
	Remotes.fireClient("ZoneStatus", player, {
		Zone = "Afk",
		Inside = timer.NextPayAt ~= nil,
		SecondsLeft = ZoneRewards.afkSecondsLeft(timer, now),
		Earned = ZoneRewards.earnedToday(data, "Afk", unix),
		Cap = ZoneRewards.cap("Afk"),
	})
end

local function afkSample(now: number)
	for _, entry in ProfileService.online() do
		local player, data = entry.Player, entry.Data
		local root = rootOf(player)
		local inside = root ~= nil
			and LobbyLayout.insideAfk(root.Position.X, root.Position.Y, root.Position.Z)
			and not MatchService.isBusy(player)
			and sessions[player] == nil
		local before = afkTimers[player] or { NextPayAt = nil }
		local after, due = ZoneRewards.afkStep(before, inside, now)
		afkTimers[player] = after
		local changed = (before.NextPayAt == nil) ~= (after.NextPayAt == nil)
		if due > 0 then
			local paid = ZoneRewards.pay(data, "Afk", Config.Afk.CoinsPerTick * due, os.time())
			if paid > 0 then
				pushEarnings(player, data)
				Remotes.fireClient("Notify", player, `AFK lounge: +{paid} coins`, "success")
			end
			changed = true
		end
		if changed then
			sendAfkStatus(player, data, after, now)
		end
	end
end

local function rangeHousekeeping(now: number)
	for player, session in sessions do
		if player.Parent ~= Players then
			releaseBay(player, nil)
		elseif MatchService.isBusy(player) then
			releaseBay(player, nil) -- queued / matched: the client leaves the range
		elseif now - session.LastActive > Config.Range.IdleKickSeconds then
			releaseBay(player, "Range bay released (idle).")
		end
	end
end

function ZoneService.start()
	Remotes.onInvoke("RangeJoin", onJoin)
	Remotes.onInvoke("RangeSwing", onSwing)
	Remotes.onEvent("RangeLeave", function(player: Player)
		releaseBay(player, nil)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		releaseBay(player, nil)
		afkTimers[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(Config.Afk.CheckSeconds)
			local now = os.clock()
			local ok, err = pcall(function()
				afkSample(now)
				rangeHousekeeping(now)
				return true
			end)
			if not ok then
				Logger.info("Zones", `zone tick error: {tostring(err)}`)
			end
		end
	end)
	Logger.info("Zones", `Zone service started (driving range: {#RangeRules.Bays} bays, {#RangeRules.Targets} targets; AFK lounge: {Config.Afk.CoinsPerTick} coins / {Config.Afk.TickSeconds}s).`)
end

return ZoneService
