--!strict
--[[
	LobbyController.luau  (Client/Lobby)

	Wires the lobby together:

	  * builds the HUD (currency, menu, Play / Loadout / Trade-Up) and the window host
	  * registers every screen: Shop, Play, Cases, Loadout, Inventory, TradeUp, Quests,
	    Wheel (daily wheelspin), Leaderboard
	  * the daily wheel tile shows "FREE" while the free spin is ready
	  * keeps the HUD in step with the profile (ClientState.changed) and refreshes the
	    open screen when the profile changes underneath it
	  * ranked queue: shows the "searching" banner with a live timer, cancel refunds
	  * hides the whole lobby UI while a match is on screen and restores it afterwards
	  * the quest badge: how many finished-but-unclaimed quests (computed locally from
	    a COPY of the profile so display logic can never touch the real one)
	  * DRIVING RANGE / AFK LOUNGE buttons walk the character straight to the zone
	  * the AFK lounge banner (live countdown to the next payout, today's total) from
	    the server's ZoneStatus events; the HUD hides while hitting range balls
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Config = require(Shared.Config)
local Format = require(Shared.Format)
local LobbyLayout = require(Shared.LobbyLayout)
local ModeView = require(Shared.ModeView)
local RangeRules = require(Shared.RangeRules)
local ProfileOps = require(Shared.ProfileOps)
local QuestEngine = require(Shared.QuestEngine)
local Remotes = require(Shared.Remotes)
local TableUtil = require(Shared.TableUtil)
local WheelRules = require(Shared.WheelRules)

local Bus = require(script.Parent.Parent.Bus)
local ClientState = require(script.Parent.Parent.ClientState)
local Toast = require(script.Parent.Parent.UI.Toast)
local CasesScreen = require(script.Parent.CasesScreen)
local InventoryScreen = require(script.Parent.InventoryScreen)
local LeaderboardScreen = require(script.Parent.LeaderboardScreen)
local LoadoutScreen = require(script.Parent.LoadoutScreen)
local LobbyHud = require(script.Parent.LobbyHud)
local ModalHost = require(script.Parent.ModalHost)
local ModeScreen = require(script.Parent.ModeScreen)
local QuestsScreen = require(script.Parent.QuestsScreen)
local Reasons = require(script.Parent.Reasons)
local ShopScreen = require(script.Parent.ShopScreen)
local TradeUpScreen = require(script.Parent.TradeUpScreen)
local WheelScreen = require(script.Parent.WheelScreen)
local Theme = require(script.Parent.Parent.UI.Theme)

local LobbyController = {}

function LobbyController.start()
	local hud = LobbyHud.new()
	local host = ModalHost.new()

	host.register("Shop", ShopScreen.factory)
	host.register("Play", ModeScreen.factory)
	host.register("Cases", CasesScreen.factory)
	host.register("Loadout", LoadoutScreen.factory)
	host.register("TradeUp", TradeUpScreen.factory)
	host.register("Quests", QuestsScreen.factory)
	host.register("Leaderboard", LeaderboardScreen.factory)
	host.register("Inventory", InventoryScreen.factory)
	host.register("Wheel", WheelScreen.factory)

	hud.onOpen.connect(function(name: any)
		host.open(tostring(name))
	end)
	Bus.OpenScreen.connect(function(name: any)
		host.open(tostring(name))
	end)

	-- ---- profile-driven HUD ------------------------------------------------------------------
	local function updateHud()
		local profile = ClientState.get()
		if profile == nil then
			return
		end
		hud.setCurrency(profile.Coins, profile.Gems)
		hud.setOvr(ProfileOps.playerOvr(profile))
	end
	local function updateQuestBadge()
		local profile = ClientState.get()
		if profile then
			-- QuestEngine starts new periods in place, so give it a throwaway copy.
			hud.setQuestBadge(QuestEngine.claimable(TableUtil.deepCopy(profile), os.time()))
		end
	end
	local function updateWheelBadge()
		local profile = ClientState.get()
		if profile and profile.Wheel then
			hud.setWheelBadge(WheelRules.state(profile, math.floor(workspace:GetServerTimeNow())).FreeReady)
		end
	end
	ClientState.changed.connect(function()
		updateHud()
		updateQuestBadge()
		updateWheelBadge()
		host.refreshCurrent()
	end)
	updateHud()
	updateQuestBadge()
	updateWheelBadge()
	task.spawn(function()
		while true do
			task.wait(30)
			updateQuestBadge()
			updateWheelBadge()
		end
	end)

	-- ---- ranked queue banner -------------------------------------------------------------------
	local queueStartedAt = 0.0
	local function endQueue()
		Bus.Queued = false
		hud.setQueue(nil)
		Bus.QueueEnded.fire()
	end
	Bus.QueueStarted.connect(function()
		queueStartedAt = os.clock()
		hud.setQueue(ModeView.queueText(0))
		task.spawn(function()
			while Bus.Queued do
				hud.setQueue(ModeView.queueText(os.clock() - queueStartedAt))
				task.wait(1)
			end
		end)
	end)
	hud.onCancelQueue.connect(function()
		local reply = Remotes.invoke("CancelQueue")
		if type(reply) == "table" and reply.ok then
			Toast.show("Search cancelled. Your entry fee was refunded.", "info")
			endQueue()
		else
			Toast.show(Reasons.text(if type(reply) == "table" then reply.reason else nil), "error")
		end
	end)

	-- ---- zones: travel buttons + AFK lounge banner ---------------------------------------------------
	hud.onGetGems.connect(function()
		Toast.show("Gem packs are coming soon!", "info")
	end)
	hud.onTravel.connect(function(zone: any)
		local character = Players.LocalPlayer.Character
		if character == nil then
			return
		end
		host.close()
		if zone == "Range" then
			-- In front of the middle bays, facing downrange.
			local bay = RangeRules.Bays[2]
			local spot = Vector3.new(RangeRules.ORIGIN.X + 14, 5, bay.WorldZ + 8)
			character:PivotTo(CFrame.lookAt(spot, spot + Vector3.new(-1, 0, 0)))
			Toast.show("Walk onto a bay and press E (or tap Hit balls) to start.", "info")
		elseif zone == "Afk" then
			local lounge = LobbyLayout.AFK_LOUNGE
			local spot = Vector3.new(lounge.X, 5, lounge.Z)
			character:PivotTo(CFrame.new(spot))
			Toast.show(`Relax here: +{Config.Afk.CoinsPerTick} coins every minute.`, "info")
		end
	end)

	local afkInside, afkSecondsLeft, afkReceivedAt, afkEarned, afkCap = false, 0, 0.0, 0, 0
	local function renderAfk()
		if not afkInside then
			hud.setZoneStatus(nil, nil)
		elseif afkEarned >= afkCap then
			hud.setZoneStatus(`AFK LOUNGE  ·  daily limit reached ({Format.commas(afkCap)})`, Theme.Colors.TextDim)
		else
			local left = math.max(0, afkSecondsLeft - (os.clock() - afkReceivedAt))
			hud.setZoneStatus(`AFK LOUNGE  ·  +{Config.Afk.CoinsPerTick} in {Format.clock(left)}  ·  {Format.commas(afkEarned)} / {Format.commas(afkCap)} today`, Theme.Colors.Teal)
		end
	end
	Remotes.onClientEvent("ZoneStatus", function(status: any)
		if type(status) ~= "table" or status.Zone ~= "Afk" then
			return
		end
		afkInside = status.Inside == true
		afkSecondsLeft = tonumber(status.SecondsLeft) or 0
		afkReceivedAt = os.clock()
		afkEarned = tonumber(status.Earned) or 0
		afkCap = tonumber(status.Cap) or Config.Afk.DailyCoinCap
		renderAfk()
	end)
	task.spawn(function()
		while true do
			task.wait(1)
			if afkInside then
				renderAfk()
			end
		end
	end)

	Bus.RangeEntered.connect(function()
		host.close()
		hud.setVisible(false)
	end)
	Bus.RangeExited.connect(function()
		hud.setVisible(true)
		updateHud()
	end)

	-- ---- match takeover ---------------------------------------------------------------------------
	Bus.MatchEntered.connect(function()
		if Bus.Queued then
			endQueue() -- the match we were waiting for started
		end
		hud.setVisible(false)
		host.setVisible(false)
	end)
	Bus.MatchExited.connect(function()
		host.setVisible(true)
		hud.setVisible(true)
		updateHud()
		updateQuestBadge()
	end)
end

return LobbyController
