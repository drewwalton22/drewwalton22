--!strict
--[[
	MemoryBackend.luau  (ServerScriptService.GolfRivals.Server)

	An in-memory stand-in for the DataStore with the same `update` contract as
	the real adapter (ProfileService's DataStore backend):

	    backend.update(key, transform) -> (status, record?)
	      status "ok"        transform returned a record; it was stored and is returned
	      status "cancelled" transform returned nil; nothing was written
	      status "error"     the backend itself failed (throttle/outage); nothing was written

	Used for (a) offline tests, with failure injection to exercise retry paths,
	and (b) a Studio fallback when API access to DataStores is switched off, so
	you can still play-test without publishing the place.

	Like the real DataStore it round-trips values through a deep copy, so code
	can't accidentally depend on sharing live tables with the "database".
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage") -- OFFLINE-STRIP
local Shared = ReplicatedStorage.GolfRivals.Shared -- OFFLINE-STRIP
local TableUtil = require(Shared.TableUtil)
local ProfileStore = require(script.Parent.ProfileStore)

export type MemoryBackend = ProfileStore.Backend & {
	-- Make the next `count` update calls fail with status "error".
	failNext: (count: number) -> (),
	-- Read the stored record without going through update (for assertions).
	peek: (key: string) -> ProfileStore.StoredRecord?,
	-- Number of update calls made (for retry assertions).
	calls: () -> number,
}

local MemoryBackend = {}

function MemoryBackend.new(): MemoryBackend
	local records: { [string]: ProfileStore.StoredRecord } = {}
	local failuresLeft = 0
	local callCount = 0

	local function update(key: string, transform: (old: ProfileStore.StoredRecord?) -> ProfileStore.StoredRecord?): (ProfileStore.UpdateStatus, ProfileStore.StoredRecord?)
		callCount += 1
		if failuresLeft > 0 then
			failuresLeft -= 1
			return "error", nil
		end
		-- The transform sees a copy of the stored value, like UpdateAsync.
		local old = if records[key] then (TableUtil.deepCopy(records[key]) :: ProfileStore.StoredRecord) else nil
		local new = transform(old)
		if new == nil then
			return "cancelled", nil
		end
		records[key] = TableUtil.deepCopy(new) :: ProfileStore.StoredRecord
		return "ok", TableUtil.deepCopy(new) :: ProfileStore.StoredRecord
	end

	return {
		update = update,
		failNext = function(count: number)
			failuresLeft = count
		end,
		peek = function(key: string): ProfileStore.StoredRecord?
			local record = records[key]
			return if record then (TableUtil.deepCopy(record) :: ProfileStore.StoredRecord) else nil
		end,
		calls = function(): number
			return callCount
		end,
	}
end

return MemoryBackend
