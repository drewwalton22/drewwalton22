--!strict
-- ROBLOX-ONLY: uses DataStoreService / Players / game:BindToClose. The logic it
-- drives (session locking, validation) lives in the offline-tested ProfileStore.
--[[
	ProfileService.luau  (ServerScriptService.GolfRivals.Server)

	Owns every player's loaded profile for the lifetime of their visit:

	  PlayerAdded    -> ProfileStore.load (session lock, retries); on failure the
	                    player is kicked with a clear message rather than being
	                    allowed to play on temporary data that would never save.
	  every 60 s     -> autosave each profile (also refreshes the session lock).
	  PlayerRemoving -> release (final save + unlock).
	  BindToClose    -> release everyone, waiting up to ~25 s (Roblox's shutdown budget is 30 s).

	Other server systems use:
	  ProfileService.get(player)             -> live ProfileData or nil (not loaded yet)
	  ProfileService.waitFor(player, timeout)-> yields until loaded (or nil)
	  ProfileService.onLoaded(callback)      -> callback(player, data) after each load
	  ProfileService.notify(player, patch)   -> pushes a partial update to that client

	Mutate profiles ONLY through ProfileOps, and never yield between a check and
	the mutation it protects (see ProfileOps header).

	The DataStore adapter maps UpdateAsync to the Backend contract:
	  returned value        -> "ok"
	  transform returned nil-> "cancelled" (tracked with a flag; UpdateAsync returns nil)
	  pcall failure         -> "error"  (throttle / outage / API access disabled)
	In Studio, if DataStore access is disabled, it falls back to MemoryBackend so
	you can still play-test (data is NOT persisted in that mode and a warning is logged).
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Config = require(Shared.Config)
local Logger = require(Shared.Logger)
local Remotes = require(Shared.Remotes)
local ProfileTemplate = require(Shared.ProfileTemplate)
local ProfileStore = require(script.Parent.ProfileStore)
local MemoryBackend = require(script.Parent.MemoryBackend)

local ProfileService = {}

local profiles: { [Player]: ProfileStore.Profile } = {}
local loadedCallbacks: { (player: Player, data: ProfileTemplate.ProfileData) -> () } = {}
local store: ProfileStore.Store? = nil
local pendingReleases = 0 -- releases in flight; BindToClose waits for this to reach 0

local KICK_MESSAGES: { [string]: string } = {
	Locked = "Your data is still saving from your last session. Please rejoin in a moment.",
	Error = "Couldn't load your data (Roblox data services are unavailable). Please rejoin shortly.",
	TooNew = "Your data was saved by a newer version of Golf Rivals. Please rejoin another server.",
	Corrupt = "Your data couldn't be read. Nothing was changed; please contact support.",
	LostLock = "Your session ended because your data was opened on another server.",
}

local function createDataStoreBackend(): ProfileStore.Backend
	local dataStore = DataStoreService:GetDataStore(Config.Data.StoreName)
	return {
		update = function(key: string, transform: (old: ProfileStore.StoredRecord?) -> ProfileStore.StoredRecord?): (ProfileStore.UpdateStatus, ProfileStore.StoredRecord?)
			local cancelled = false
			local ok, result = pcall(function()
				return dataStore:UpdateAsync(key, function(old: any)
					cancelled = false -- UpdateAsync may re-run this callback on conflict
					local new = transform(old)
					if new == nil then
						cancelled = true
					end
					return new
				end)
			end)
			if not ok then
				Logger.info("Profiles", `DataStore error on {key}: {tostring(result)}`)
				return "error", nil
			end
			if cancelled then
				return "cancelled", nil
			end
			return "ok", result :: ProfileStore.StoredRecord
		end,
	}
end

-- In Studio without "Enable Studio Access to API Services", DataStore calls throw.
-- Detect that once at startup and fall back to memory so play-testing still works.
local function chooseBackend(): ProfileStore.Backend
	if RunService:IsStudio() then
		local probeStore = DataStoreService:GetDataStore(Config.Data.StoreName)
		local ok = pcall(function()
			probeStore:GetAsync("__probe")
		end)
		if not ok then
			Logger.info("Profiles", "WARNING: DataStore unavailable in Studio; using in-memory backend. Progress will NOT be saved.")
			return MemoryBackend.new()
		end
	end
	return createDataStoreBackend()
end

local function keyFor(player: Player): string
	return Config.Data.KeyPrefix .. tostring(player.UserId)
end

local function releaseProfile(profile: ProfileStore.Profile)
	pendingReleases += 1
	local status = profile.release()
	pendingReleases -= 1
	if status ~= "Saved" and status ~= "Inactive" then
		Logger.info("Profiles", `release of {profile.Key} ended with {status}`)
	end
end

local function loadPlayer(player: Player)
	local activeStore = store :: ProfileStore.Store
	local result = activeStore.load(keyFor(player))

	if result.Status ~= "Loaded" or result.Profile == nil then
		Logger.info("Profiles", `{player.Name}: load failed ({result.Status})`)
		player:Kick(KICK_MESSAGES[result.Status] or KICK_MESSAGES.Error)
		return
	end

	local profile = result.Profile
	-- Player left while we were loading: don't strand the lock for 10 minutes.
	if player.Parent ~= Players then
		releaseProfile(profile)
		return
	end

	profiles[player] = profile
	Logger.info("Profiles", `{player.Name}: loaded (coins {profile.Data.Coins}, sessions {profile.Data.Meta.Sessions})`)
	for _, callback in loadedCallbacks do
		task.spawn(callback, player, profile.Data)
	end
end

local function autosaveLoop()
	while true do
		task.wait(Config.Data.AutosaveSeconds)
		local snapshot: { [Player]: ProfileStore.Profile } = {}
		for player, profile in profiles do
			snapshot[player] = profile
		end
		for player, profile in snapshot do
			task.spawn(function()
				local status = profile.save()
				if status == "LostLock" then
					player:Kick(KICK_MESSAGES.LostLock)
				elseif status == "Error" then
					Logger.info("Profiles", `autosave failed for {player.Name}; will retry next cycle`)
				end
			end)
			task.wait(0.25) -- spread requests; DataStore budgets are per-minute
		end
	end
end

-- Call once, after Remotes.init().
function ProfileService.start()
	store = ProfileStore.new(chooseBackend(), {
		JobId = if game.JobId ~= "" then game.JobId else "studio-" .. tostring(os.time()),
		Clock = os.time,
		Wait = task.wait,
	})

	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(loadPlayer, player)
	end)
	-- Anyone who joined before start() ran.
	for _, player in Players:GetPlayers() do
		task.spawn(loadPlayer, player)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		local profile = profiles[player]
		profiles[player] = nil
		if profile then
			task.spawn(releaseProfile, profile)
		end
	end)

	game:BindToClose(function()
		local remaining: { ProfileStore.Profile } = {}
		for player, profile in profiles do
			profiles[player] = nil
			table.insert(remaining, profile)
		end
		for _, profile in remaining do
			task.spawn(releaseProfile, profile)
		end
		-- Wait for ALL in-flight releases, including ones PlayerRemoving started.
		local deadline = os.clock() + 25
		while pendingReleases > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)

	task.spawn(autosaveLoop)

	-- The client's way to fetch its own profile (UI bootstrap).
	Remotes.onInvoke("GetProfile", function(player: Player)
		local data = ProfileService.waitFor(player, 10)
		if data == nil then
			return { ok = false, reason = "not_loaded" }
		end
		return { ok = true, profile = ProfileTemplate.clientView(data) }
	end)

	Logger.info("Profiles", "Profile service started (session-locked saves, autosave every " .. Config.Data.AutosaveSeconds .. "s).")
end

function ProfileService.get(player: Player): ProfileTemplate.ProfileData?
	local profile = profiles[player]
	return if profile then profile.Data else nil
end

-- Yields until the player's profile is loaded; nil if they leave or time runs out.
function ProfileService.waitFor(player: Player, timeoutSeconds: number?): ProfileTemplate.ProfileData?
	local deadline = os.clock() + (timeoutSeconds or 30)
	while os.clock() < deadline do
		local data = ProfileService.get(player)
		if data then
			return data
		end
		if player.Parent ~= Players then
			return nil
		end
		task.wait(0.1)
	end
	return nil
end

function ProfileService.onLoaded(callback: (player: Player, data: ProfileTemplate.ProfileData) -> ())
	table.insert(loadedCallbacks, callback)
end

-- Push a partial profile update (e.g. { Coins = 1200 }) to the owning client.
function ProfileService.notify(player: Player, patch: { [string]: any })
	Remotes.fireClient("ProfileChanged", player, patch)
end

return ProfileService
