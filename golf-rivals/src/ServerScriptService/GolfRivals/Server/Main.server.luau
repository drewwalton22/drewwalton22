--!strict
-- ROBLOX-ONLY: entry script (game services); syntax-checked only by tools/check.sh.
--[[
	Main.server.luau  (ServerScriptService.GolfRivals.Server)

	Server entry point. Boot order (each step is added as its system is built):
	  1. Validate the static databases.
	  2. Create the network remotes (Remotes.init).
	  3. Player profiles (session-locked DataStore saves, autosave, GetProfile remote)
	  4. Economy service: shop rotation, cases, sell, trade-up, upgrades, equip
	  5. Match service: ranked queues, AI bots, match orchestration
	  6. Quests, leaderboard, and the lobby world
	  7. Lobby coin zones: driving range bays + AFK lounge
	  8. Daily wheelspin + Robux receipt processing

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
local ProfileService = require(script.Parent:WaitForChild("ProfileService"))
local EconomyService = require(script.Parent:WaitForChild("EconomyService"))
local MatchService = require(script.Parent:WaitForChild("MatchService"))
local CourseRegistry = require(script.Parent:WaitForChild("CourseRegistry"))
local QuestService = require(script.Parent:WaitForChild("QuestService"))
local LeaderboardService = require(script.Parent:WaitForChild("LeaderboardService"))
local LobbyBuilder = require(script.Parent:WaitForChild("LobbyBuilder"))
local ZoneService = require(script.Parent:WaitForChild("ZoneService"))
local WheelService = require(script.Parent:WaitForChild("WheelService"))
local ReceiptService = require(script.Parent:WaitForChild("ReceiptService"))
local TerrainBuilder = require(script.Parent:WaitForChild("TerrainBuilder"))

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

Logger.info("Server", "Step 3: starting player profile service (session-locked DataStore saves)")
ProfileService.start()

Logger.info("Server", "Step 4: starting economy service (client requests are validated, atomic, server-rolled)")
EconomyService.start()

Logger.info("Server", "Step 5: starting match service (ranked queues, bot practice, turn loop)")
TerrainBuilder.applyLook() -- tall rough (Terrain.GrassLength) + fairway / rough colours, for every course
CourseRegistry.load() -- hand-built holes in Workspace.GolfCourses (optional)
MatchService.start()

Logger.info("Server", "Step 6: quests, leaderboard and the lobby world")
QuestService.start()
LeaderboardService.start()
LobbyBuilder.build()

Logger.info("Server", "Step 7: lobby coin zones (driving range + AFK lounge, server-simulated and daily-capped)")
ZoneService.start()

Logger.info("Server", "Step 8: daily wheelspin (24 h free spin saved in the profile; gem / Robux spins)")
WheelService.start()
ReceiptService.start()

Logger.info("Server", "Server ready.")
