--!strict
-- Offline verification entry point (run via tools/check.sh, standalone Luau).
-- Loads the Shared data modules, runs the database validator, and prints a
-- summary plus spot-checks of the math the design mockup depends on.

local Config = require("./Config")
local Rarity = require("./Rarity")
local ItemDatabase = require("./ItemDatabase")
local CaseDatabase = require("./CaseDatabase")
local ClubDatabase = require("./ClubDatabase")
local DatabaseValidator = require("./DatabaseValidator")
local RemoteDefs = require("./RemoteDefs")
local Validate = require("./Validate")
local RateLimiter = require("./RateLimiter")

local failures = 0
local function expect(label: string, condition: boolean)
	if condition then
		print("  PASS  " .. label)
	else
		failures += 1
		print("  FAIL  " .. label)
	end
end

local errors = DatabaseValidator.run()
for _, message in errors do
	print("  VALIDATOR: " .. message)
end
expect("DatabaseValidator reports no errors", #errors == 0)

print(`items={#ItemDatabase.Ordered} clubs={#ClubDatabase.Ordered} cases={#CaseDatabase.Order}`)

-- Mockup spot checks ------------------------------------------------------
expect("Rarity chain ends at Mythical", Rarity.nextTier("Legendary") == "Mythical" and Rarity.nextTier("Mythical") == nil)
expect("OVR 92/78/85 -> 86 (driver card)", ClubDatabase.overall({ Distance = 92, Accuracy = 78, Forgiveness = 85 }) == 86)
local shadow = ClubDatabase.get("tatermade_shadow_d")
expect("Tatermade Shadow driver is OVR 86", shadow ~= nil and ClubDatabase.overall(shadow.BaseStats) == 86)
expect("Case drop percents are 45/30/15/7/2/1", (function()
	local p = CaseDatabase.getDropPercents("club_skins_case")
	return p.Common == 45 and p.Uncommon == 30 and p.Rare == 15 and p.Unique == 7 and p.Legendary == 2 and p.Mythical == 1
end)())

local costs = {}
for level = 0, Config.Clubs.MaxUpgradeLevel - 1 do
	table.insert(costs, tostring(ClubDatabase.upgradeCost(level)))
end
print("upgrade costs L0->L10: " .. table.concat(costs, ", "))
expect("upgradeCost is nil at max level", ClubDatabase.upgradeCost(Config.Clubs.MaxUpgradeLevel) == nil)

-- Frozen data must reject writes (guards against accidental mutation).
local okWrite = pcall(function()
	(ItemDatabase.Ordered[1] :: any).Rarity = "Mythical"
end)
expect("Item data is frozen", not okWrite)

-- Network layer -------------------------------------------------------------
print("-- network")
local remoteErrors = RemoteDefs.validate()
for _, message in remoteErrors do
	print("  REMOTES: " .. message)
end
expect("RemoteDefs valid (unique, rate limited, server->client are events)", #remoteErrors == 0)
print(`remotes={#RemoteDefs.List}`)

expect("Validate rejects NaN / inf / strings", not Validate.isFiniteNumber(0 / 0) and not Validate.isFiniteNumber(math.huge) and not Validate.isFiniteNumber("5"))
expect("Validate.numberInRange bounds are inclusive", Validate.numberInRange(0, 0, 100) and Validate.numberInRange(100, 0, 100) and not Validate.numberInRange(100.01, 0, 100))
expect("Validate.integerInRange rejects fractions", Validate.integerInRange(3, 1, 10) and not Validate.integerInRange(2.5, 1, 10))
expect("Validate.string rejects empty / too long / non-string", Validate.string("a", 5) and not Validate.string("", 5) and not Validate.string("toolong", 5) and not Validate.string(5, 5))
local isString = function(v: any): boolean
	return Validate.string(v, 20)
end
expect("Validate.array accepts proper arrays", Validate.array({ "a", "b", "c" }, 5, isString))
local badArrays: { { any } } = {
	{ { "a", "b", "c" }, 2 }, -- oversize
	{ { x = "a" }, 5 }, -- dictionary
	{ { [1] = "a", [3] = "c" }, 5 }, -- hole
	{ { "a", 5 }, 5 }, -- bad element
	{ "a", 5 }, -- not a table
}
local allRejected = true
for _, case in badArrays do
	if Validate.array(case[1], case[2], isString) then
		allRejected = false
	end
end
expect("Validate.array rejects oversize / dict / holes / bad element / non-table", allRejected)
expect("Validate.oneOf", Validate.oneOf("Easy", { "Easy", "Hard" }) and not Validate.oneOf("Nope", { "Easy", "Hard" }) and not Validate.oneOf(nil, { "Easy" }))

-- Token bucket with a fake clock: capacity 3, refill 0.5/s.
local now = 0
local limiter = RateLimiter.new(function()
	return now
end)
local function call(key: string): boolean
	return limiter.allow(key, "OpenCases", 3, 0.5)
end
-- Spend n tokens in a row; returns how many calls were allowed.
local function burst(key: string, n: number): number
	local allowed = 0
	for _ = 1, n do
		if call(key) then
			allowed += 1
		end
	end
	return allowed
end
expect("RateLimiter allows a burst of `capacity`", burst("p1", 3) == 3)
expect("RateLimiter denies the 4th immediate call", not call("p1"))
now = 1.9
expect("RateLimiter still denies before a full token refills (1.9s * 0.5 = 0.95)", not call("p1"))
now = 2.0
expect("RateLimiter allows once a full token refills (2.0s)", call("p1"))
expect("RateLimiter denies again right after", not call("p1"))
expect("RateLimiter buckets are per player", call("p2"))
now = 1000
expect("RateLimiter refill is capped at capacity (only 3 of 10 pass)", burst("p1", 10) == 3)
limiter.clear("p1")
expect("RateLimiter.clear resets a player", call("p1"))

for _, caseId in CaseDatabase.Order do
	print(`case {caseId}: expected sell value {CaseDatabase.expectedSellValue(caseId)} vs price {CaseDatabase.Cases[caseId].Price.Amount}`)
end

if failures > 0 then
	error(`{failures} check(s) failed`)
end
print("ALL CHECKS PASSED")
