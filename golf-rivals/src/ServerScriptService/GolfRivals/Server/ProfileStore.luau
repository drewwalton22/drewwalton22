--!strict
--[[
	ProfileStore.luau  (ServerScriptService.GolfRivals.Server)

	Loads, autosaves and releases player profiles with SESSION LOCKING, written
	against an abstract Backend so the same logic runs on the real DataStore
	(ProfileService) and on MemoryBackend (tests / Studio fallback).

	WHY SESSION LOCKING
	  A player can be in two servers briefly (teleport, quick rejoin, a server
	  that crashed). If both load the profile and both save, the later save
	  overwrites the earlier one, which means lost purchases or duplicated
	  items. So a stored record is { Data, Lock = {JobId, Time}, Revision } and:

	  load  : atomically (inside the backend's UpdateAsync) take the lock iff
	          nobody else holds a FRESH one. A lock older than LockTimeoutSeconds
	          belongs to a crashed server and is taken over.
	  save  : atomically write ONLY IF we still hold the lock, refreshing its
	          timestamp (the autosave doubles as the heartbeat). If someone took
	          the lock, we got stale: write nothing and report "LostLock" so the
	          caller kicks the player rather than overwrite newer data.
	  release: save + clear the lock.

	All check-and-write steps happen inside one `backend.update` transform, which
	the DataStore executes atomically, so there is no read-modify-write race.
	The transform can run more than once (DataStore retries on conflict), so it
	resets its local flags on every call and never mutates captured state.

	BACKEND CONTRACT  update(key, transform) -> (status, record?)
	  "ok" (written, returns the new record) | "cancelled" (transform returned
	  nil, nothing written) | "error" (backend failed, nothing written).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage") -- OFFLINE-STRIP
local Shared = ReplicatedStorage.GolfRivals.Shared -- OFFLINE-STRIP
local Config = require(Shared.Config)
local ProfileTemplate = require(Shared.ProfileTemplate)
local TableUtil = require(Shared.TableUtil)

export type Lock = { JobId: string, Time: number }

export type StoredRecord = {
	Data: any,
	Lock: Lock?,
	Revision: number,
}

export type UpdateStatus = "ok" | "cancelled" | "error"

export type Backend = {
	update: (key: string, transform: (old: StoredRecord?) -> StoredRecord?) -> (UpdateStatus, StoredRecord?),
}

export type Options = {
	JobId: string,
	Clock: () -> number, -- seconds (os.time in game; fake in tests)
	Wait: (seconds: number) -> (), -- task.wait in game; no-op in tests
	LockTimeoutSeconds: number?,
	LoadAttempts: number?,
	RetrySeconds: number?,
	ReleaseAttempts: number?,
}

export type SaveStatus = "Saved" | "LostLock" | "Error" | "Inactive"

export type Profile = {
	Key: string,
	Data: ProfileTemplate.ProfileData, -- live table; mutate via ProfileOps
	isActive: () -> boolean,
	save: () -> SaveStatus,
	release: () -> SaveStatus,
}

export type LoadStatus = "Loaded" | "Locked" | "TooNew" | "Corrupt" | "Error"

export type LoadResult = {
	Status: LoadStatus,
	Profile: Profile?,
}

export type Store = {
	-- One attempt.
	loadOnce: (key: string) -> LoadResult,
	-- Retries "Locked" and "Error" with a delay between attempts.
	load: (key: string) -> LoadResult,
}

local ProfileStore = {}

function ProfileStore.new(backend: Backend, options: Options): Store
	local jobId = options.JobId
	local clock = options.Clock
	local wait = options.Wait
	local lockTimeout = options.LockTimeoutSeconds or Config.Data.LockTimeoutSeconds
	local loadAttempts = options.LoadAttempts or Config.Data.LoadAttempts
	local retrySeconds = options.RetrySeconds or Config.Data.LoadRetrySeconds
	local releaseAttempts = options.ReleaseAttempts or Config.Data.ReleaseAttempts

	local function makeProfile(key: string, data: ProfileTemplate.ProfileData): Profile
		local active = true

		-- Shared by save and release: write the snapshot iff we still own the lock.
		local function write(keepLock: boolean): SaveStatus
			if not active then
				return "Inactive"
			end
			local snapshot = TableUtil.deepCopy(data) -- consistent view at call time
			local lost = false
			local status = backend.update(key, function(old: StoredRecord?): StoredRecord?
				lost = false -- the transform may run several times
				local lock = if old then old.Lock else nil
				if old == nil or lock == nil or lock.JobId ~= jobId then
					lost = true
					return nil -- someone else owns this profile now: write nothing
				end
				return {
					Data = snapshot,
					Lock = if keepLock then { JobId = jobId, Time = clock() } else nil,
					Revision = old.Revision + 1,
				}
			end)
			if status == "ok" then
				if not keepLock then
					active = false
				end
				return "Saved"
			elseif status == "cancelled" and lost then
				active = false -- our session is dead; never write again
				return "LostLock"
			end
			return "Error" -- backend failure: stay active, retry on the next autosave
		end

		return {
			Key = key,
			Data = data,
			isActive = function(): boolean
				return active
			end,
			save = function(): SaveStatus
				return write(true)
			end,
			release = function(): SaveStatus
				local result: SaveStatus = "Error"
				for attempt = 1, releaseAttempts do
					result = write(false)
					if result ~= "Error" then
						break
					end
					if attempt < releaseAttempts then
						wait(retrySeconds)
					end
				end
				return result
			end,
		}
	end

	local function loadOnce(key: string): LoadResult
		local outcome = "ok"
		local status, record = backend.update(key, function(old: StoredRecord?): StoredRecord?
			outcome = "ok" -- reset: the transform may run several times
			local now = clock()
			if old ~= nil then
				-- Refuse to touch data written by a newer game version.
				local version = if type(old.Data) == "table" then old.Data.SchemaVersion else nil
				if type(version) == "number" and version > ProfileTemplate.CURRENT_VERSION then
					outcome = "too_new"
					return nil
				end
				local lock = old.Lock
				if lock ~= nil and lock.JobId ~= jobId and now - lock.Time < lockTimeout then
					outcome = "locked" -- another live server owns it
					return nil
				end
				return { Data = old.Data, Lock = { JobId = jobId, Time = now }, Revision = old.Revision }
			end
			-- First ever load: create the profile and take the lock in one write.
			return {
				Data = ProfileTemplate.new(now),
				Lock = { JobId = jobId, Time = now },
				Revision = 0,
			}
		end)

		if status == "error" then
			return { Status = "Error", Profile = nil }
		elseif status == "cancelled" then
			if outcome == "too_new" then
				return { Status = "TooNew", Profile = nil }
			end
			return { Status = "Locked", Profile = nil }
		end

		-- We hold the lock. Validate/repair the loaded data before the game sees it.
		local data, reason = ProfileTemplate.prepare((record :: StoredRecord).Data, clock())
		if data == nil then
			-- Corrupt: we hold the lock but must not overwrite the evidence. Release it untouched.
			backend.update(key, function(old: StoredRecord?): StoredRecord?
				if old == nil or old.Lock == nil or old.Lock.JobId ~= jobId then
					return nil
				end
				return { Data = old.Data, Lock = nil, Revision = old.Revision }
			end)
			return { Status = if reason == "too_new" then "TooNew" else "Corrupt", Profile = nil }
		end
		data.Meta.Sessions += 1
		return { Status = "Loaded", Profile = makeProfile(key, data) }
	end

	local function load(key: string): LoadResult
		local result: LoadResult = { Status = "Error", Profile = nil }
		for attempt = 1, loadAttempts do
			result = loadOnce(key)
			if result.Status ~= "Locked" and result.Status ~= "Error" then
				return result
			end
			if attempt < loadAttempts then
				wait(retrySeconds)
			end
		end
		return result
	end

	return { loadOnce = loadOnce, load = load }
end

return ProfileStore
