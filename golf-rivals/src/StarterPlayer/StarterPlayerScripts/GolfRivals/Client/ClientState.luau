--!strict
--[[
	ClientState.luau  (Client)

	The client's copy of the player's profile, kept in sync with the server:

	  * `ClientState.init()` fetches the full profile (GetProfile, retried until the
	    server has loaded it) and listens to `ProfileChanged` patches.
	  * A patch replaces whole top-level sections (Coins, OwnedItems, Stats...), the
	    same granularity the server sends, so nothing is ever half-merged.
	  * Screens read `ClientState.get()` and subscribe with `ClientState.changed`
	    (fired with the list of changed section names).

	The server is the only authority: this copy is for display and for greying out
	buttons the player can't afford. Every real action is re-validated server-side.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Remotes = require(Shared.Remotes)
local Signal = require(Shared.Signal)
local ProfileTemplate = require(Shared.ProfileTemplate)

local ClientState = {}

ClientState.changed = Signal.new() -- fires (sections: { string })
ClientState.loaded = Signal.new() -- fires once the first full profile arrives

local profile: ProfileTemplate.ProfileData? = nil

function ClientState.get(): ProfileTemplate.ProfileData?
	return profile
end

function ClientState.isLoaded(): boolean
	return profile ~= nil
end

-- Full refresh from the server (used at start and after reconnect-ish events).
function ClientState.refresh(): boolean
	local reply = Remotes.invoke("GetProfile")
	if type(reply) == "table" and reply.ok and type(reply.profile) == "table" then
		local first = profile == nil
		profile = reply.profile :: any
		if first then
			ClientState.loaded.fire()
		end
		local sections: { string } = {}
		for key in reply.profile do
			table.insert(sections, key)
		end
		ClientState.changed.fire(sections)
		return true
	end
	return false
end

function ClientState.init()
	Remotes.waitUntilReady()
	Remotes.onClientEvent("ProfileChanged", function(patch: any)
		if profile == nil or type(patch) ~= "table" then
			return
		end
		local sections: { string } = {}
		for key, value in patch do
			(profile :: any)[key] = value
			table.insert(sections, key)
		end
		ClientState.changed.fire(sections)
	end)
	-- The server may still be loading our data for a moment after we join.
	task.spawn(function()
		while not ClientState.refresh() do
			task.wait(1)
		end
	end)
end

return ClientState
