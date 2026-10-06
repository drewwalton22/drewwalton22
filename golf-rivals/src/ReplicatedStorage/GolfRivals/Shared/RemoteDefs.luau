--!strict
--[[
	RemoteDefs.luau  (ReplicatedStorage.GolfRivals.Shared)

	The complete, declarative list of every RemoteEvent / RemoteFunction in the
	game. Remotes.luau reads this list to create the instances (server) and to
	look them up (client), so adding a remote = adding one entry here.

	Pure data (no Roblox APIs) so it can be validated offline.

	NETWORK SECURITY MODEL
	  * The client is untrusted. ClientToServer remotes carry only INTENT
	    ("open 3 of this case", "swing with these inputs"), never results
	    ("I won 5000 coins", "the ball landed here").
	  * The server re-validates every argument (Validate.luau), re-checks
	    ownership/prices/cooldowns, and computes every outcome itself.
	  * Each ClientToServer remote has a token-bucket rate limit (see
	    RateLimiter.luau): `Capacity` calls may burst, refilling at
	    `RefillPerSec`. Calls over budget are dropped.

	KIND
	  Event    - fire-and-forget (no reply).
	  Function - request/response; the server's return value is the reply.
	             Used for anything the UI must wait on (open case, buy item).
	             Servers must never let a client-invoked function yield forever;
	             handlers should return quickly or a { ok = false, reason } table.
]]

export type RemoteKind = "Event" | "Function"
export type Direction = "ClientToServer" | "ServerToClient"

export type RateLimit = {
	Capacity: number, -- max burst
	RefillPerSec: number, -- sustained calls per second
}

export type RemoteDef = {
	Name: string,
	Kind: RemoteKind,
	Direction: Direction,
	Doc: string, -- arguments / return shape, for the human developer
	Limit: RateLimit?, -- required for ClientToServer, forbidden otherwise
}

local RemoteDefs = {}

-- Reusable budgets.
local UI_ACTION: RateLimit = { Capacity = 5, RefillPerSec = 1 } -- buttons: buy, equip, upgrade
local UI_QUERY: RateLimit = { Capacity = 5, RefillPerSec = 2 } -- read-only fetches
local HEAVY_ACTION: RateLimit = { Capacity = 3, RefillPerSec = 0.5 } -- case opens, trade-ups
local SWING: RateLimit = { Capacity = 6, RefillPerSec = 2 } -- 3 clicks per shot, with slack

RemoteDefs.List = {
	-- ---- Gameplay ----------------------------------------------------------
	{
		Name = "SubmitSwing",
		Kind = "Event",
		Direction = "ClientToServer",
		Doc = "(power: number 0-100, accuracyOffset: number -1..1) Click-2 locked power and the Click-3 timing offset from the green zone's center. The server recomputes the whole shot from these two numbers.",
		Limit = SWING,
	},
	{
		Name = "ShotResult",
		Kind = "Event",
		Direction = "ServerToClient",
		Doc = "(result: table) Authoritative flight: sampled trajectory points plus carry/total/roll yards, apex height and spin RPM for the telemetry overlay.",
	},
	{
		Name = "MatchState",
		Kind = "Event",
		Direction = "ServerToClient",
		Doc = "(state: table) Whose turn, hole number, par, yards-to-pin, wind, scores. Sent on every change.",
	},

	-- ---- Profile / inventory ----------------------------------------------
	{
		Name = "GetProfile",
		Kind = "Function",
		Direction = "ClientToServer",
		Doc = "() -> profile snapshot: currencies, owned items, equipped loadout, club upgrade levels, quests.",
		Limit = UI_QUERY,
	},
	{
		Name = "ProfileChanged",
		Kind = "Event",
		Direction = "ServerToClient",
		Doc = "(patch: table) Partial profile update (e.g. new coin balance) so the UI never has to poll.",
	},
	{
		Name = "EquipItem",
		Kind = "Function",
		Direction = "ClientToServer",
		Doc = "(itemId: string) -> { ok, reason? } Equip an owned cosmetic into its slot.",
		Limit = UI_ACTION,
	},
	{
		Name = "EquipClub",
		Kind = "Function",
		Direction = "ClientToServer",
		Doc = "(clubId: string) -> { ok, reason? } Put an owned club into its bag slot.",
		Limit = UI_ACTION,
	},
	{
		Name = "UpgradeClub",
		Kind = "Function",
		Direction = "ClientToServer",
		Doc = "(clubId: string, stat: 'Distance'|'Accuracy'|'Forgiveness') -> { ok, reason?, newLevel? } Spend coins to upgrade one stat.",
		Limit = UI_ACTION,
	},

	-- ---- Shop / cases / trade-up -------------------------------------------
	{
		Name = "GetShop",
		Kind = "Function",
		Direction = "ClientToServer",
		Doc = "() -> { offers = {itemIds}, rotationEndsAt: number } Today's rotating shop.",
		Limit = UI_QUERY,
	},
	{
		Name = "BuyShopItem",
		Kind = "Function",
		Direction = "ClientToServer",
		Doc = "(itemId: string) -> { ok, reason? } Buy a currently offered item at its rarity price.",
		Limit = UI_ACTION,
	},
	{
		Name = "OpenCases",
		Kind = "Function",
		Direction = "ClientToServer",
		Doc = "(caseId: string, count: integer 1..MaxCasesPerOpen) -> { ok, reason?, drops? } Server charges, rolls and grants everything atomically.",
		Limit = HEAVY_ACTION,
	},
	{
		Name = "SellItems",
		Kind = "Function",
		Direction = "ClientToServer",
		Doc = "(itemIds: {string}) -> { ok, reason?, coinsGained? } Sell owned duplicates for coins.",
		Limit = UI_ACTION,
	},
	{
		Name = "TradeUp",
		Kind = "Function",
		Direction = "ClientToServer",
		Doc = "(itemIds: {string} of length TradeUp.InputCount) -> { ok, reason?, reward? } Consume inputs, grant one item of the next rarity.",
		Limit = HEAVY_ACTION,
	},

	-- ---- Matchmaking -------------------------------------------------------
	{
		Name = "QueueRanked",
		Kind = "Function",
		Direction = "ClientToServer",
		Doc = "(leagueId: string) -> { ok, reason? } Pay the entry fee and enter that league's queue.",
		Limit = UI_ACTION,
	},
	{
		Name = "CancelQueue",
		Kind = "Function",
		Direction = "ClientToServer",
		Doc = "() -> { ok } Leave the queue and refund the entry fee if no match started.",
		Limit = UI_ACTION,
	},
	{
		Name = "StartBotMatch",
		Kind = "Function",
		Direction = "ClientToServer",
		Doc = "(difficulty: 'Easy'|'Medium'|'Hard') -> { ok, reason? } Offline practice vs AI; no entry fee.",
		Limit = UI_ACTION,
	},

	-- ---- Quests / social ---------------------------------------------------
	{
		Name = "ClaimQuest",
		Kind = "Function",
		Direction = "ClientToServer",
		Doc = "(questId: string) -> { ok, reason? } Claim a completed quest's coin/gem reward once.",
		Limit = UI_ACTION,
	},
	{
		Name = "GetLeaderboard",
		Kind = "Function",
		Direction = "ClientToServer",
		Doc = "() -> { {rank, name, ovr}... } Top players for the lobby board.",
		Limit = UI_QUERY,
	},
	{
		Name = "Notify",
		Kind = "Event",
		Direction = "ServerToClient",
		Doc = "(message: string, kind: 'info'|'success'|'error') Toast text for the HUD.",
	},
} :: { RemoteDef }

-- name -> def, for O(1) lookup by Remotes.luau.
local byName: { [string]: RemoteDef } = {}
for _, def in RemoteDefs.List do
	byName[def.Name] = def
end
RemoteDefs.ByName = byName

-- Returns a list of problems (empty = valid). Run by the offline check and
-- by the server on boot.
function RemoteDefs.validate(): { string }
	local errors: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, def in RemoteDefs.List do
		if seen[def.Name] then
			table.insert(errors, "duplicate remote name: " .. def.Name)
		end
		seen[def.Name] = true

		if def.Kind ~= "Event" and def.Kind ~= "Function" then
			table.insert(errors, `{def.Name}: invalid kind`)
		end
		if def.Direction == "ClientToServer" then
			-- Every client-callable remote MUST be rate limited.
			local limit = def.Limit
			if limit == nil or limit.Capacity < 1 or limit.RefillPerSec <= 0 then
				table.insert(errors, `{def.Name}: ClientToServer remote needs a positive rate limit`)
			end
		elseif def.Direction == "ServerToClient" then
			if def.Limit ~= nil then
				table.insert(errors, `{def.Name}: ServerToClient remote must not define a rate limit`)
			end
			-- Servers cannot invoke clients: RemoteFunction:InvokeClient can hang
			-- the server thread forever if the client never replies.
			if def.Kind == "Function" then
				table.insert(errors, `{def.Name}: ServerToClient must be an Event (InvokeClient is unsafe)`)
			end
		else
			table.insert(errors, `{def.Name}: invalid direction`)
		end
	end
	return errors
end

return RemoteDefs
