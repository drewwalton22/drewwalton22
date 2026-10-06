--!strict
--[[
	Prng.luau  (ReplicatedStorage.GolfRivals.Shared)

	A small deterministic pseudo-random generator (mulberry32) for anything that
	must be IDENTICAL on every server and every run - chiefly the daily shop
	rotation. (Case rolls use the server's unpredictable Random instead; this
	generator is predictable by design and must never decide a player's loot.)

	Why not Roblox's Random.new(seed)? Its algorithm is an implementation detail
	we don't control. Here the algorithm is explicit, and tools/verify_shared.luau
	checks its output against an independent reference implementation, so a
	future Roblox change can never silently reshuffle the shop mid-day.

	mulberry32 step (all arithmetic mod 2^32):
	    a = a + 0x6D2B79F5
	    t = imul(a ^ (a >> 15), a | 1)
	    t = ((t + imul(t ^ (t >> 7), t | 61)) mod 2^32) ^ t
	    out = (t ^ (t >> 14)) / 2^32                         in [0, 1)
	imul is a 32-bit multiply; doubles can't hold a 64-bit product, so it is built
	from 16-bit halves (every intermediate stays below 2^53, so it is exact).
]]

export type Prng = {
	next: () -> number, -- float in [0, 1)
	nextInt: (n: number) -> number, -- integer in [1, n]
}

local Prng = {}

local TWO32 = 4294967296

-- Low 32 bits of a * b for 32-bit unsigned a, b.
local function imul(a: number, b: number): number
	local ah, al = bit32.rshift(a, 16), bit32.band(a, 0xFFFF)
	local bh, bl = bit32.rshift(b, 16), bit32.band(b, 0xFFFF)
	-- a*b = (ah*2^16 + al)(bh*2^16 + bl); the ah*bh*2^32 term vanishes mod 2^32.
	return (al * bl + ((ah * bl + al * bh) % 65536) * 65536) % TWO32
end

function Prng.new(seed: number): Prng
	local state = math.floor(seed) % TWO32

	local function next(): number
		state = (state + 0x6D2B79F5) % TWO32
		local t = imul(bit32.bxor(state, bit32.rshift(state, 15)), bit32.bor(state, 1))
		t = bit32.bxor((t + imul(bit32.bxor(t, bit32.rshift(t, 7)), bit32.bor(t, 61))) % TWO32, t)
		return bit32.bxor(t, bit32.rshift(t, 14)) / TWO32
	end

	local function nextInt(n: number): number
		return math.floor(next() * n) + 1
	end

	return { next = next, nextInt = nextInt }
end

return Prng
