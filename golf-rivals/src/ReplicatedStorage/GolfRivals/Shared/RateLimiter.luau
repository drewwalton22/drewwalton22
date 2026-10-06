--!strict
--[[
	RateLimiter.luau  (ReplicatedStorage.GolfRivals.Shared)

	Token-bucket rate limiter, one bucket per (player key, remote name).

	MATH
	  Each bucket holds up to `capacity` tokens and gains `refillPerSec` tokens
	  per second. Every call costs one token:

	      tokens = min(capacity, tokens + (now - lastSeen) * refillPerSec)
	      if tokens >= 1 then tokens -= 1 ; allow else deny

	  So a player may burst `capacity` calls at once, then is held to the
	  sustained `refillPerSec` rate. Example: Capacity 3, Refill 0.5/s lets a
	  player open 3 cases instantly, then one more every 2 seconds.

	The clock is injected (`os.clock` in game, a fake in tests) so the logic is
	deterministic and testable offline.
]]

type Bucket = {
	Tokens: number,
	LastSeen: number,
}

export type Limiter = {
	-- true = allow this call (a token was spent), false = over budget.
	allow: (key: string, bucketName: string, capacity: number, refillPerSec: number) -> boolean,
	-- Drop all buckets for a key (call when a player leaves to free memory).
	clear: (key: string) -> (),
}

local RateLimiter = {}

function RateLimiter.new(clock: () -> number): Limiter
	-- buckets[key][bucketName]
	local buckets: { [string]: { [string]: Bucket } } = {}

	local function allow(key: string, bucketName: string, capacity: number, refillPerSec: number): boolean
		local now = clock()
		local perKey = buckets[key]
		if perKey == nil then
			perKey = {}
			buckets[key] = perKey
		end

		local bucket = perKey[bucketName]
		if bucket == nil then
			-- First call starts with a full bucket.
			bucket = { Tokens = capacity, LastSeen = now }
			perKey[bucketName] = bucket
		end

		-- Refill for the time since we last saw this bucket (never above capacity).
		bucket.Tokens = math.min(capacity, bucket.Tokens + (now - bucket.LastSeen) * refillPerSec)
		bucket.LastSeen = now

		if bucket.Tokens >= 1 then
			bucket.Tokens -= 1
			return true
		end
		return false
	end

	local function clear(key: string)
		buckets[key] = nil
	end

	return { allow = allow, clear = clear }
end

return RateLimiter
