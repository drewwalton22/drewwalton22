--!strict
-- ROBLOX-ONLY: binds remotes, Players, task scheduling and Random. The rules it
-- drives live in the offline-tested MatchEngine / BotBrain / Matchmaker /
-- MatchSettlement modules.
--[[
	MatchService.luau  (ServerScriptService.GolfRivals.Server)

	Runs every live match on this server.

	REMOTES (all rate limited; the client only sends intent)
	  QueueRanked(leagueId)   charge the entry fee, enter that league's queue
	  CancelQueue()           leave the queue, fee refunded
	  StartBotMatch(level)    free practice vs an AI bot (Easy | Medium | Hard)
	  LeaveMatch()            forfeit
	  SelectClub(label) / SetAim(deg) / SubmitSwing(power, offset)   (events)

	LOOP (every 0.25 s)
	  - pair queued players (Matchmaker) and start their matches
	  - tick each match's engine (turn timers, flight pauses, hole changes)
	  - let bots take their turn after a human-like "thinking" pause
	  - broadcast: ShotResult for every shot, MatchState after any change
	  - settle finished matches (payouts / refunds / stats), then clean up

	MONEY SAFETY
	  The ranked entry fee is charged at queue time and held by this service until
	  the match settles; cancelling, leaving the queue, or a failed pairing refunds
	  it. Settlement uses MatchSettlement (winner paid, draws refunded). Known
	  limit: if the whole server crashes mid-match the fee is not refunded.

	LEAVING: ProfileService.onLeaving runs before the final save, so a player who
	quits mid-queue is refunded and a player who quits mid-match forfeits, with the
	result written to their profile and the opponent's.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local ClubDatabase = require(Shared.ClubDatabase)
local Config = require(Shared.Config)
local CourseDatabase = require(Shared.CourseDatabase)
local Logger = require(Shared.Logger)
local ProfileOps = require(Shared.ProfileOps)
local ProfileTemplate = require(Shared.ProfileTemplate)
local Remotes = require(Shared.Remotes)
local Validate = require(Shared.Validate)
local BotBrain = require(script.Parent.BotBrain)
local Matchmaker = require(script.Parent.Matchmaker)
local MatchEngine = require(script.Parent.MatchEngine)
local MatchSettlement = require(script.Parent.MatchSettlement)
local ProfileService = require(script.Parent.ProfileService)

type ProfileData = ProfileTemplate.ProfileData

type Match = {
	Id: number,
	Mode: MatchSettlement.Mode,
	League: Config.LeagueDef?,
	Difficulty: string?,
	Engine: MatchEngine.Engine,
	Humans: { Player },
	PlayStats: { [string]: MatchSettlement.PlayStats }, -- by player id
	BotId: string?,
	BotActAt: number?, -- when the bot's "thinking" pause ends
	Settled: boolean,
	CleanupAt: number?,
}

local MatchService = {}

local BOT_ID = "bot"
local random = Random.new()
local rng = function(): number
	return random:NextNumber()
end

local matchmaker = Matchmaker.new()
local matches: { [number]: Match } = {}
local playerMatch: { [Player]: Match } = {}
local queued: { [Player]: Config.LeagueDef } = {} -- escrowed fee = league.EntryFee
local nextMatchId = 0

local function idOf(player: Player): string
	return tostring(player.UserId)
end

local function notify(player: Player, message: string, kind: string)
	Remotes.fireClient("Notify", player, message, kind)
end

local function pushProfile(player: Player, data: ProfileData, keys: { string })
	local view = ProfileTemplate.clientView(data)
	local patch: { [string]: any } = {}
	for _, key in keys do
		patch[key] = view[key]
	end
	ProfileService.notify(player, patch)
	ProfileService.saveSoon(player)
end

local function findLeague(leagueId: any): Config.LeagueDef?
	if type(leagueId) ~= "string" then
		return nil
	end
	for _, league in Config.Leagues do
		if league.Id == leagueId then
			return league
		end
	end
	return nil
end

-- Freeze the player's equipped-club stats at match start: upgrading or swapping
-- clubs mid-match must not change a match already underway.
local function frozenBag(data: ProfileData): (string) -> ClubDatabase.Stats
	local bag: { [string]: ClubDatabase.Stats } = {}
	for _, slot in ClubDatabase.BagSlots do
		local clubId = data.EquippedClubs[slot.Label]
		local stats = if clubId then ProfileOps.clubStats(data, clubId) else nil
		bag[slot.Label] = stats or { Distance = 50, Accuracy = 50, Forgiveness = 50 }
	end
	return function(label: string): ClubDatabase.Stats
		return bag[label] or bag.D
	end
end

-- ---------------------------------------------------------------------------
-- Broadcasting
-- ---------------------------------------------------------------------------

local function broadcastState(match: Match)
	local snapshot = match.Engine.snapshot(os.clock())
	for _, player in match.Humans do
		if player.Parent == Players then
			Remotes.fireClient("MatchState", player, snapshot)
		end
	end
end

-- Drain engine events: stream shots to clients and keep per-player play stats.
local function flush(match: Match)
	local events = match.Engine.drainEvents()
	if #events == 0 then
		return
	end
	for _, event in events do
		local data = event.Data
		if event.Type == "Shot" then
			for _, player in match.Humans do
				if player.Parent == Players then
					Remotes.fireClient("ShotResult", player, data)
				end
			end
			local stats = match.PlayStats[data.PlayerId]
			if stats then
				if data.HoleInOne then
					stats.HolesInOne += 1
				end
				-- Longest drive: a real driver shot that finished in play.
				if data.ClubLabel == "D" and not data.Penalty and data.Telemetry.CarryYds > stats.LongestDriveYds then
					stats.LongestDriveYds = data.Telemetry.CarryYds
				end
			end
		elseif event.Type == "HoleComplete" then
			for id, stats in match.PlayStats do
				if not table.find(match.Engine.result().ForfeitedIds, id) then
					stats.HolesPlayed += 1
				end
			end
		end
	end
	broadcastState(match)
end

-- ---------------------------------------------------------------------------
-- Settlement & cleanup
-- ---------------------------------------------------------------------------

local function settle(match: Match)
	if match.Settled then
		return
	end
	match.Settled = true
	match.CleanupAt = os.clock() + Config.Match.EndScreenSeconds

	local result = match.Engine.result()
	local ids: { string } = {}
	for _, player in match.Humans do
		table.insert(ids, idOf(player))
	end
	local outcomes = MatchSettlement.settle(result, match.Mode, match.League, ids)
	for _, player in match.Humans do
		local id = idOf(player)
		local data = ProfileService.get(player)
		if data then
			local credited = MatchSettlement.applyToProfile(data, outcomes[id], match.PlayStats[id])
			pushProfile(player, data, { "Coins", "Stats" })
			if outcomes[id].Won and credited > 0 then
				notify(player, `You won {credited} coins!`, "success")
			elseif outcomes[id].Drew and credited > 0 then
				notify(player, `Match drawn - {credited} coins refunded.`, "info")
			end
		end
	end
	broadcastState(match)
	Logger.info("Matches", `match {match.Id} settled: winner={tostring(result.WinnerId)} draw={tostring(result.Draw)} reason={result.Reason}`)
end

local function cleanup(match: Match)
	matches[match.Id] = nil
	for _, player in match.Humans do
		if playerMatch[player] == match then
			playerMatch[player] = nil
		end
	end
end

-- ---------------------------------------------------------------------------
-- Match creation
-- ---------------------------------------------------------------------------

local function createMatch(mode: MatchSettlement.Mode, humans: { Player }, league: Config.LeagueDef?, difficulty: string?): Match?
	local specs: { MatchEngine.PlayerSpec } = {}
	local playStats: { [string]: MatchSettlement.PlayStats } = {}
	for _, player in humans do
		local data = ProfileService.get(player)
		if data == nil then
			return nil
		end
		table.insert(specs, {
			Id = idOf(player),
			Name = player.DisplayName,
			IsBot = false,
			StatsFor = frozenBag(data),
			Cosmetics = table.clone(data.EquippedItems),
		})
		playStats[idOf(player)] = { HolesPlayed = 0, HolesInOne = 0, LongestDriveYds = 0 }
	end

	local botId: string? = nil
	if mode == "Bot" and difficulty then
		botId = BOT_ID
		table.insert(specs, {
			Id = BOT_ID,
			Name = `Rival Bot ({difficulty})`,
			IsBot = true,
			StatsFor = BotBrain.statsFor(difficulty),
		})
	end

	nextMatchId += 1
	local startHole = random:NextInteger(1, #CourseDatabase.Holes)
	local engine = MatchEngine.new({
		Players = specs,
		Holes = CourseDatabase.sequence(startHole, Config.Match.HolesPerMatch),
		Seed = random:NextInteger(1, 2147483646),
		Now = os.clock(),
	})
	local match: Match = {
		Id = nextMatchId, Mode = mode, League = league, Difficulty = difficulty, Engine = engine,
		Humans = humans, PlayStats = playStats, BotId = botId, BotActAt = nil, Settled = false, CleanupAt = nil,
	}
	matches[match.Id] = match
	for _, player in humans do
		playerMatch[player] = match
		notify(player, if mode == "Ranked" then "Match found!" else "Practice match starting...", "info")
	end
	Logger.info("Matches", `match {match.Id} started ({mode}{if difficulty then " " .. difficulty else ""}, {#humans} human)`)
	flush(match)
	broadcastState(match)
	return match
end

-- ---------------------------------------------------------------------------
-- Queue
-- ---------------------------------------------------------------------------

local function refundQueueFee(player: Player, data: ProfileData?)
	local league = queued[player]
	queued[player] = nil
	matchmaker.dequeue(idOf(player))
	if league and data then
		ProfileOps.refund(data, "Coins", league.EntryFee)
		pushProfile(player, data, { "Coins" })
	end
end

local function pairingTick()
	for _, pair in matchmaker.findMatches(os.clock()) do
		local playerA = Players:GetPlayerByUserId(tonumber(pair.A.PlayerId) or 0)
		local playerB = Players:GetPlayerByUserId(tonumber(pair.B.PlayerId) or 0)
		local league = if playerA then queued[playerA] else nil
		if playerA and playerB and league then
			queued[playerA] = nil
			queued[playerB] = nil
			if createMatch("Ranked", { playerA, playerB }, league, nil) == nil then
				-- A profile vanished between pairing and start: give both fees back.
				for _, p in { playerA, playerB } do
					local data = ProfileService.get(p)
					if data then
						ProfileOps.refund(data, "Coins", league.EntryFee)
						pushProfile(p, data, { "Coins" })
					end
				end
			end
		else
			-- Someone left: refund whoever is still here.
			for _, p in { playerA, playerB } do
				if p and queued[p] then
					refundQueueFee(p, ProfileService.get(p))
				end
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Loop
-- ---------------------------------------------------------------------------

local function tickMatch(match: Match, now: number)
	local engine = match.Engine
	engine.tick(now)

	-- Bots: pause like a person, then play.
	local activeId = engine.activeId()
	if match.BotId and activeId == match.BotId and engine.phase() == "Swing" and match.Difficulty then
		if match.BotActAt == nil then
			local think = Config.Match.BotThinkSeconds
			match.BotActAt = now + think.Min + random:NextNumber() * (think.Max - think.Min)
		elseif now >= match.BotActAt then
			match.BotActAt = nil
			BotBrain.play(engine, match.BotId, match.Difficulty, rng, now)
		end
	end

	flush(match)
	if engine.isFinished() and not match.Settled then
		settle(match)
	end
	if match.CleanupAt and now >= match.CleanupAt then
		cleanup(match)
	end
end

local function loop()
	local lastPairing = 0.0
	while true do
		task.wait(0.25)
		local now = os.clock()
		if now - lastPairing >= Config.Matchmaking.TickSeconds then
			lastPairing = now
			pairingTick()
		end
		for _, match in matches do
			local ok, err = pcall(tickMatch, match, now)
			if not ok then
				Logger.info("Matches", `match {match.Id} tick error: {tostring(err)}`)
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Start
-- ---------------------------------------------------------------------------

function MatchService.start()
	Remotes.onInvoke("QueueRanked", function(player: Player, leagueId: any)
		local data = ProfileService.get(player)
		if data == nil then
			return { ok = false, reason = "not_loaded" }
		end
		local league = findLeague(leagueId)
		if league == nil then
			return { ok = false, reason = "unknown_league" }
		end
		if playerMatch[player] or queued[player] then
			return { ok = false, reason = "already_busy" }
		end
		local spent, why = ProfileOps.spend(data, { Currency = "Coins", Amount = league.EntryFee })
		if not spent then
			return { ok = false, reason = why }
		end
		queued[player] = league
		matchmaker.enqueue(idOf(player), league.Id, ProfileOps.playerOvr(data), os.clock())
		pushProfile(player, data, { "Coins" })
		return { ok = true, Fee = league.EntryFee }
	end)

	Remotes.onInvoke("CancelQueue", function(player: Player)
		if queued[player] == nil then
			return { ok = false, reason = "not_queued" }
		end
		refundQueueFee(player, ProfileService.get(player))
		return { ok = true }
	end)

	Remotes.onInvoke("StartBotMatch", function(player: Player, difficulty: any)
		if ProfileService.get(player) == nil then
			return { ok = false, reason = "not_loaded" }
		end
		if not Validate.oneOf(difficulty, Config.BotDifficulties) then
			return { ok = false, reason = "bad_difficulty" }
		end
		if playerMatch[player] or queued[player] then
			return { ok = false, reason = "already_busy" }
		end
		local match = createMatch("Bot", { player }, nil, difficulty :: string)
		return { ok = match ~= nil }
	end)

	Remotes.onInvoke("LeaveMatch", function(player: Player)
		local match = playerMatch[player]
		if match == nil or match.Settled then
			return { ok = false, reason = "not_in_match" }
		end
		match.Engine.forfeit(idOf(player), os.clock())
		flush(match)
		return { ok = true }
	end)

	Remotes.onEvent("SelectClub", function(player: Player, label: any)
		local match = playerMatch[player]
		if match and not match.Settled and match.Engine.setClub(idOf(player), label) then
			broadcastState(match)
		end
	end)

	Remotes.onEvent("SetAim", function(player: Player, aimDeg: any)
		local match = playerMatch[player]
		if match and not match.Settled and match.Engine.setAim(idOf(player), aimDeg) then
			broadcastState(match)
		end
	end)

	Remotes.onEvent("SubmitSwing", function(player: Player, power: any, offset: any)
		local match = playerMatch[player]
		if match == nil or match.Settled then
			return
		end
		local ok, reason = match.Engine.submitSwing(idOf(player), power, offset, os.clock())
		if not ok and reason ~= "not_your_turn" then
			notify(player, `Swing rejected ({tostring(reason)})`, "error")
		end
		flush(match)
	end)

	-- Leaving: refund a queued fee, or forfeit a live match, BEFORE the final save.
	ProfileService.onLeaving(function(player: Player, data: ProfileData)
		if queued[player] then
			refundQueueFee(player, data)
		end
		local match = playerMatch[player]
		if match and not match.Settled then
			match.Engine.forfeit(idOf(player), os.clock())
			flush(match)
			if match.Engine.isFinished() then
				settle(match)
			end
		end
		playerMatch[player] = nil
	end)

	task.spawn(loop)
	Logger.info("Matches", "Match service started (ranked queues, bot practice, turn loop).")
end

return MatchService
