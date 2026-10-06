--!strict
--[[
	LobbyController.luau  (Client/Lobby)

	Wires the lobby together:

	  * builds the HUD (currency, menu, Play / Loadout / Trade-Up) and the window host
	  * registers every screen: Shop, Play, Cases, Loadout, TradeUp, Quests, Leaderboard
	  * keeps the HUD in step with the profile (ClientState.changed) and refreshes the
	    open screen when the profile changes underneath it
	  * ranked queue: shows the "searching" banner with a live timer, cancel refunds
	  * hides the whole lobby UI while a match is on screen and restores it afterwards
	  * the quest badge: how many finished-but-unclaimed quests (computed locally from
	    a COPY of the profile so display logic can never touch the real one)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local ModeView = require(Shared.ModeView)
local ProfileOps = require(Shared.ProfileOps)
local QuestEngine = require(Shared.QuestEngine)
local Remotes = require(Shared.Remotes)
local TableUtil = require(Shared.TableUtil)

local Bus = require(script.Parent.Parent.Bus)
local ClientState = require(script.Parent.Parent.ClientState)
local Toast = require(script.Parent.Parent.UI.Toast)
local CasesScreen = require(script.Parent.CasesScreen)
local LeaderboardScreen = require(script.Parent.LeaderboardScreen)
local LoadoutScreen = require(script.Parent.LoadoutScreen)
local LobbyHud = require(script.Parent.LobbyHud)
local ModalHost = require(script.Parent.ModalHost)
local ModeScreen = require(script.Parent.ModeScreen)
local QuestsScreen = require(script.Parent.QuestsScreen)
local Reasons = require(script.Parent.Reasons)
local ShopScreen = require(script.Parent.ShopScreen)
local TradeUpScreen = require(script.Parent.TradeUpScreen)

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
	ClientState.changed.connect(function()
		updateHud()
		updateQuestBadge()
		host.refreshCurrent()
	end)
	updateHud()
	updateQuestBadge()
	task.spawn(function()
		while true do
			task.wait(30)
			updateQuestBadge()
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
