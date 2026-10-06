--!strict
-- ROBLOX-ONLY: uses game/Instance APIs; skipped by tools/check.sh (its logic
-- lives in the offline-verified RemoteDefs / Validate / RateLimiter modules).
--[[
	Remotes.luau  (ReplicatedStorage.GolfRivals.Shared)

	One module, used by BOTH sides, that owns every RemoteEvent/RemoteFunction.

	SERVER                                    CLIENT
	  Remotes.init()      create instances      Remotes.waitUntilReady()
	  Remotes.onEvent     listen (rate limited) Remotes.onEvent     listen
	  Remotes.onInvoke    answer (rate limited) Remotes.invoke      request/reply
	  Remotes.fireClient  push to a player      Remotes.fire        send intent
	  Remotes.fireAll     push to everyone

	Calling a function on the wrong side, or with a remote whose declared
	Direction/Kind doesn't fit, errors immediately (a developer mistake, caught
	at the first run, not a silent no-op).

	Instances live in ReplicatedStorage.GolfRivals.Remotes (created by the
	server). The server sets the folder attribute "Ready" once every remote
	exists, so clients never race against creation.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local RemoteDefs = require(script.Parent.RemoteDefs)
local RateLimiter = require(script.Parent.RateLimiter)
local Logger = require(script.Parent.Logger)

local FOLDER_NAME = "Remotes"
local ROOT_NAME = "GolfRivals"

local Remotes = {}

-- Server-side limiter; os.clock is monotonic and cheap. Keyed by UserId.
local limiter = RateLimiter.new(os.clock)

local function getDef(name: string, kind: RemoteDefs.RemoteKind, direction: RemoteDefs.Direction): RemoteDefs.RemoteDef
	local def = RemoteDefs.ByName[name]
	assert(def, "unknown remote: " .. name)
	assert(def.Kind == kind, `remote {name} is a {def.Kind}, not a {kind}`)
	assert(def.Direction == direction, `remote {name} is {def.Direction}, not {direction}`)
	return def
end

local function getFolder(): Folder
	local root = ReplicatedStorage:WaitForChild(ROOT_NAME)
	return root:WaitForChild(FOLDER_NAME) :: Folder
end

local function getInstance(name: string): Instance
	return getFolder():WaitForChild(name, 10)
		or error("remote instance never replicated: " .. name)
end

-- ===========================================================================
-- SERVER
-- ===========================================================================

-- Create every remote from RemoteDefs. Call once, first thing at boot.
function Remotes.init()
	assert(RunService:IsServer(), "Remotes.init is server-only")

	local errors = RemoteDefs.validate()
	if #errors > 0 then
		error("RemoteDefs invalid:\n - " .. table.concat(errors, "\n - "))
	end

	local root = ReplicatedStorage:WaitForChild(ROOT_NAME)
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	for _, def in RemoteDefs.List do
		local remote: Instance = if def.Kind == "Event" then Instance.new("RemoteEvent") else Instance.new("RemoteFunction")
		remote.Name = def.Name
		remote.Parent = folder
	end
	folder.Parent = root
	-- Parent first, THEN flag ready, so a client that sees Ready also sees all children.
	folder:SetAttribute("Ready", true)

	-- Free rate-limit memory when someone leaves.
	Players.PlayerRemoving:Connect(function(player: Player)
		limiter.clear(tostring(player.UserId))
	end)

	Logger.info("Remotes", `Created {#RemoteDefs.List} remotes.`)
end

-- Listen to a ClientToServer RemoteEvent. Over-budget calls are dropped.
-- `handler` receives (player, ...args) - validate the args yourself.
function Remotes.onEvent(name: string, handler: (player: Player, ...any) -> ())
	assert(RunService:IsServer(), "Remotes.onEvent (server) is server-only")
	local def = getDef(name, "Event", "ClientToServer")
	local limit = def.Limit :: RemoteDefs.RateLimit
	local remote = getInstance(name) :: RemoteEvent
	remote.OnServerEvent:Connect(function(player: Player, ...)
		if not limiter.allow(tostring(player.UserId), name, limit.Capacity, limit.RefillPerSec) then
			return -- silently drop spam; no reply channel on events
		end
		handler(player, ...)
	end)
end

-- Answer a ClientToServer RemoteFunction. Over-budget calls get a
-- { ok = false, reason = "rate_limited" } reply so the UI can recover.
-- A handler error is caught and turned into { ok = false, reason = "server_error" }
-- so a bug (or crafted input) can't leave the client's invoke hanging.
function Remotes.onInvoke(name: string, handler: (player: Player, ...any) -> any)
	assert(RunService:IsServer(), "Remotes.onInvoke is server-only")
	local def = getDef(name, "Function", "ClientToServer")
	local limit = def.Limit :: RemoteDefs.RateLimit
	local remote = getInstance(name) :: RemoteFunction
	remote.OnServerInvoke = function(player: Player, ...)
		if not limiter.allow(tostring(player.UserId), name, limit.Capacity, limit.RefillPerSec) then
			return { ok = false, reason = "rate_limited" }
		end
		local args = table.pack(...)
		local success, result = pcall(function()
			return handler(player, table.unpack(args, 1, args.n))
		end)
		if not success then
			Logger.info("Remotes", `{name} handler errored: {tostring(result)}`)
			return { ok = false, reason = "server_error" }
		end
		return result
	end
end

-- Push to one player (ServerToClient events only).
function Remotes.fireClient(name: string, player: Player, ...: any)
	assert(RunService:IsServer(), "Remotes.fireClient is server-only")
	getDef(name, "Event", "ServerToClient")
	local remote = getInstance(name) :: RemoteEvent
	remote:FireClient(player, ...)
end

-- Push to every player (ServerToClient events only).
function Remotes.fireAll(name: string, ...: any)
	assert(RunService:IsServer(), "Remotes.fireAll is server-only")
	getDef(name, "Event", "ServerToClient")
	local remote = getInstance(name) :: RemoteEvent
	remote:FireAllClients(...)
end

-- ===========================================================================
-- CLIENT
-- ===========================================================================

-- Yield until the server has created every remote.
function Remotes.waitUntilReady()
	assert(RunService:IsClient(), "Remotes.waitUntilReady is client-only")
	local folder = getFolder()
	while not folder:GetAttribute("Ready") do
		folder:GetAttributeChangedSignal("Ready"):Wait()
	end
end

-- Send intent to the server (ClientToServer events only).
function Remotes.fire(name: string, ...: any)
	assert(RunService:IsClient(), "Remotes.fire is client-only")
	getDef(name, "Event", "ClientToServer")
	local remote = getInstance(name) :: RemoteEvent
	remote:FireServer(...)
end

-- Ask the server and wait for the reply (ClientToServer functions only).
function Remotes.invoke(name: string, ...: any): any
	assert(RunService:IsClient(), "Remotes.invoke is client-only")
	getDef(name, "Function", "ClientToServer")
	local remote = getInstance(name) :: RemoteFunction
	return remote:InvokeServer(...)
end

-- Listen to a ServerToClient event.
function Remotes.onClientEvent(name: string, handler: (...any) -> ()): RBXScriptConnection
	assert(RunService:IsClient(), "Remotes.onClientEvent is client-only")
	getDef(name, "Event", "ServerToClient")
	local remote = getInstance(name) :: RemoteEvent
	return remote.OnClientEvent:Connect(handler)
end

return Remotes
