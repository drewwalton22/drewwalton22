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

for _, caseId in CaseDatabase.Order do
	print(`case {caseId}: expected sell value {CaseDatabase.expectedSellValue(caseId)} vs price {CaseDatabase.Cases[caseId].Price.Amount}`)
end

if failures > 0 then
	error(`{failures} check(s) failed`)
end
print("ALL CHECKS PASSED")
