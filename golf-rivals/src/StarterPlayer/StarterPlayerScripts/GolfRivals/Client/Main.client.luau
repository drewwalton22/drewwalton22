--!strict
--[[
	Main.client.luau  (StarterPlayerScripts.GolfRivals.Client)

	Client entry point. Currently a stub that proves the shared modules load on
	the client. Later steps register here, in order:
	  * 3-click swing input + power gauge UI
	  * client-side trajectory prediction (visual only; the server is authoritative)
	  * post-shot camera + live telemetry overlay
	  * lobby UI controllers (Shop, Cases, Trade-Up, Loadout, Quests, Leaderboard)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("GolfRivals"):WaitForChild("Shared")
local Logger = require(Shared:WaitForChild("Logger"))
local ItemDatabase = require(Shared:WaitForChild("ItemDatabase"))

Logger.info("Client", string.format("Client loaded. %d cosmetics in the catalogue.", #ItemDatabase.Ordered))
