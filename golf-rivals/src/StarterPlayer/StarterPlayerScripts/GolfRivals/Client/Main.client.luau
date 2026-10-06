--!strict
--[[
	Main.client.luau  (StarterPlayerScripts.GolfRivals.Client)

	Client entry point. Boot order:
	  1. wait for the game to finish loading (so everything in ReplicatedStorage exists)
	  2. connect to the server's remotes and fetch / subscribe to the player's profile
	  3. toasts for server notifications
	  4. the in-match experience (listens for MatchState / ShotResult)
	  5. the lobby: HUD, screens (Shop, Play, Cases, Loadout, Inventory, Trade-Up, Quests,
	     Daily Wheel, Leaderboard), the 3D daily wheel and the lobby ambience (depth
	     of field, neon accent tweens, ambient particles)
	  6. the driving range (bay prompts -> range mode); the AFK lounge needs no client
	     logic beyond the lobby banner (the server tracks presence)
]]

if not game:IsLoaded() then
	game.Loaded:Wait()
end

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Logger = require(Shared.Logger)
local Remotes = require(Shared.Remotes)

local ClientState = require(script.Parent.ClientState)
local LobbyAmbience = require(script.Parent.Lobby.LobbyAmbience)
local LobbyController = require(script.Parent.Lobby.LobbyController)
local WheelController = require(script.Parent.Lobby.WheelController)
local MatchController = require(script.Parent.Match.MatchController)
local RangeController = require(script.Parent.Zones.RangeController)
local Toast = require(script.Parent.UI.Toast)

Logger.info("Client", "Starting Golf Rivals client...")

ClientState.init() -- waits for the server's remotes, then loads the profile

Remotes.onClientEvent("Notify", function(message: any, kind: any)
	Toast.show(tostring(message), if type(kind) == "string" then kind else "info")
end)

MatchController.start()
LobbyController.start()
WheelController.start()
LobbyAmbience.start()
RangeController.start()

Logger.info("Client", "Client ready.")
