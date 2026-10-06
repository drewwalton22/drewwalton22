--!strict
--[[
	Main.server.luau  (ServerScriptService.GolfRivals.Server)

	Server entry point. Boot order (each step is added as its system is built):
	  1. Validate the static databases.
	  2. Create the network remotes (Remotes.init).
	  3. DataStore + player profiles
	  4. Economy: shop rotation, cases, trade-up, upgrades
	  5. Matchmaking, AI bots, match orchestration
	  6. Quests

	If validation fails the error aborts this script on purpose: a server with
	broken economy data must not accept players.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("GolfRivals"):WaitForChild("Shared")
local Logger = require(Shared:WaitForChild("Logger"))
local DatabaseValidator = require(Shared:WaitForChild("DatabaseValidator"))
local ItemDatabase = require(Shared:WaitForChild("ItemDatabase"))
local ClubDatabase = require(Shared:WaitForChild("ClubDatabase"))
local CaseDatabase = require(Shared:WaitForChild("CaseDatabase"))
local Remotes = require(Shared:WaitForChild("Remotes"))

Logger.info("Server", "Booting Golf Rivals server...")
Logger.info("Server", "Step 1: validating item / club / case databases (economy exploit checks included)")

DatabaseValidator.assertValid()

Logger.info(
	"Server",
	string.format(
		"Databases OK: %d items, %d clubs, %d cases.",
		#ItemDatabase.Ordered,
		#ClubDatabase.Ordered,
		#CaseDatabase.Order
	)
)
Logger.info("Server", "Step 2: creating network remotes (all client->server calls are rate limited + validated)")
Remotes.init()

Logger.info("Server", "Next build step: swing physics (3-click swing, wind, slope, lie).")
