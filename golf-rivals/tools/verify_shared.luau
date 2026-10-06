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
local ShotPhysics = require("./ShotPhysics")
local SwingMath = require("./SwingMath")
local SwingStateMachine = require("./SwingStateMachine")

local Types = require("./Types")
local P_YD = Config.Physics.YardsToMeters -- metres per yard

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


-- Swing state machine -------------------------------------------------------
print("-- swing state machine")
local function swing(c1: number, c2: number, c3: number?): SwingStateMachine.SwingResult?
	local sm = SwingStateMachine.new()
	sm.click(c1)
	sm.click(c2)
	if c3 then
		sm.click(c3)
	end
	return sm.result()
end
do
	-- Rise 1.1s, fall 0.9s, window 0.3s. Click 2 at 0.55s = 50% power,
	-- centre at 0.55 + 0.5*0.9 = 1.0s after click 1... (t2 = 0.55, tCenter = 1.0)
	local r = swing(0, 0.55, 1.0)
	expect("Perfectly timed 50% swing: power 50, offset 0", r ~= nil and math.abs(r.Power - 50) < 1e-9 and math.abs(r.AccuracyOffset) < 1e-9)
	local early = swing(0, 0.55, 0.85)
	expect("Early click -> negative offset (-0.5)", early ~= nil and math.abs(early.AccuracyOffset - -0.5) < 1e-9)
	local late = swing(0, 0.55, 1.15)
	expect("Late click -> positive offset (+0.5)", late ~= nil and math.abs(late.AccuracyOffset - 0.5) < 1e-9)
	local veryEarly = swing(0, 1.0, 1.0)
	expect("Offset clamps at -1 (clicked instantly after click 2)", veryEarly ~= nil and veryEarly.AccuracyOffset == -1)

	local sm = SwingStateMachine.new()
	expect("Starts Idle", sm.phase() == "Idle" and sm.result() == nil)
	sm.click(10)
	expect("Click 1 -> PowerRising", sm.phase() == "PowerRising")
	expect("Marker rises linearly (0.55s -> 0.5)", math.abs(sm.gauge(10.55).Marker - 0.5) < 1e-9)
	sm.click(10.55)
	expect("Click 2 -> AccuracyFalling with locked power", sm.phase() == "AccuracyFalling" and math.abs((sm.gauge(10.55).LockedPower :: number) - 0.5) < 1e-9)
	expect("Marker falls to 0 exactly at the centre (t=11.0)", math.abs(sm.gauge(11.0).Marker) < 1e-9)
	sm.click(11.0)
	expect("Click 3 -> Done; extra clicks ignored", sm.phase() == "Done" and (function()
		sm.click(12)
		local r = sm.result()
		return r ~= nil and math.abs(r.AccuracyOffset) < 1e-9
	end)())
	sm.reset()
	expect("reset() returns to Idle", sm.phase() == "Idle")

	-- Auto-lock: never click 2 -> power locks at exactly 100% at t1+1.1.
	local auto = SwingStateMachine.new()
	auto.click(0)
	auto.update(5) -- polled long after the deadline
	local g = auto.gauge(5)
	expect("No click 2: auto-locks at 100% power", g.Phase == "AccuracyFalling" or g.Phase == "Done")
	-- tCenter = 1.1 + 0.9 = 2.0; deadline = 2.3 -> offset +1
	local ar = auto.result()
	expect("No click 3 either: auto-locks power 100, offset +1 (late hook)", ar ~= nil and ar.Power == 100 and ar.AccuracyOffset == 1)
	-- Same result no matter how often the UI polls.
	local a2 = SwingStateMachine.new()
	a2.click(0)
	for step = 1, 30 do
		a2.update(step * 0.1)
	end
	local ar2 = a2.result()
	expect("Auto-lock is independent of polling frequency", ar2 ~= nil and ar ~= nil and ar2.Power == ar.Power and ar2.AccuracyOffset == ar.AccuracyOffset)
end

-- Submission plausibility (anti-cheat) --------------------------------------
print("-- submission validation")
do
	local ok1 = SwingMath.validateSubmission(100, 0, 10)
	expect("Normal swing accepted", ok1)
	local ok2, why2 = SwingMath.validateSubmission(100, 0, 0.5)
	expect("Full-power perfect swing in 0.5s rejected as too_fast", not ok2 and why2 == "too_fast")
	local okEarly = SwingMath.validateSubmission(100, -1, 1.5)
	expect("Very early click is faster, so 1.5s is plausible for (100, -1)", okEarly)
	local _, whyNaN = SwingMath.validateSubmission(0 / 0, 0, 10)
	local _, whyRange = SwingMath.validateSubmission(150, 0, 10)
	local _, whyOffset = SwingMath.validateSubmission(50, 2, 10)
	local _, whyLow = SwingMath.validateSubmission(0, 0, 10)
	local _, whyType = SwingMath.validateSubmission("100", 0, 10)
	expect("Rejects NaN / out-of-range / wrong type / whiff", whyNaN == "bad_power" and whyRange == "bad_power" and whyOffset == "bad_offset" and whyLow == "power_too_low" and whyType == "bad_power")
	-- Every state-machine result a human can really produce must validate.
	local allValid = true
	for _, c2 in { 0.2, 0.55, 1.1 } do
		for _, c3 in { 0.0, 0.2, 0.5, 1.0, 1.6, 2.5 } do
			local sm = SwingStateMachine.new()
			sm.click(0)
			sm.click(c2)
			sm.click(c2 + c3)
			local r = sm.result()
			if r and r.Power >= Config.Swing.MinPower then
				local ok = SwingMath.validateSubmission(r.Power, r.AccuracyOffset, c2 + c3)
				if not ok then
					allValid = false
				end
			end
		end
	end
	expect("Genuine swings from the state machine always pass validation", allValid)
end

-- Shot physics ----------------------------------------------------------------
print("-- shot physics")
do
	local baseStats = { Distance = 50, Accuracy = 60, Forgiveness = 60 }
	local fairway = ShotPhysics.flatTerrain("Fairway")
	local function shot(label: string, stats: ClubDatabase.Stats, power: number, offset: number, lie: Types.LieId?, wind: ShotPhysics.Wind?): SwingMath.ResolvedShot
		local slot = ClubDatabase.getSlot(label) :: ClubDatabase.BagSlot
		local theLie: Types.LieId = lie or "Fairway"
		return SwingMath.resolveShot({
			Slot = slot, Stats = stats, Power = power, AccuracyOffset = offset, Lie = theLie, Wind = wind,
		}, ShotPhysics.flatTerrain(theLie), nil)
	end

	-- Calibration: every non-putter's full-power carry equals BaseCarryYds.
	local calibrated = true
	for _, slot in ClubDatabase.BagSlots do
		if slot.Class ~= "Putter" then
			local carry = shot(slot.Label, baseStats, 100, 0).Result.CarryYds
			if math.abs(carry - slot.BaseCarryYds) > 0.5 then
				calibrated = false
				print(`  calibration miss {slot.Label}: {carry} vs {slot.BaseCarryYds}`)
			end
		end
	end
	expect("Full-power carry matches BaseCarryYds for all 13 clubs (+/-0.5 yd)", calibrated)

	-- Mockup driver card: Distance 92 / Acc 78 / Forg 85 -> ~278 carry, ~312 total, 2450 rpm.
	local mock = shot("D", { Distance = 92, Accuracy = 78, Forgiveness = 85 }, 100, 0).Result
	print(`  mockup driver: carry {mock.CarryYds} total {mock.TotalYds} roll {mock.RollYds} apex {mock.ApexFeet}ft spin {mock.SpinRpm}`)
	expect("Mockup driver carry within 270-285 yds (mockup: 278)", mock.CarryYds > 270 and mock.CarryYds < 285)
	expect("Mockup driver total within 300-325 (mockup: 312) and roll positive", mock.TotalYds > 300 and mock.TotalYds < 325 and mock.RollYds > 0)
	expect("Mockup driver apex within 95-125 ft (mockup: 112)", mock.ApexFeet > 95 and mock.ApexFeet < 125)
	expect("Telemetry: spin 2450 rpm, carry + roll = total", math.abs(mock.SpinRpm - 2450) < 1 and math.abs(mock.CarryYds + mock.RollYds - mock.TotalYds) < 1e-6)

	-- Power is ~linear in distance.
	local linear = true
	for _, label in { "D", "5W", "7i", "PW", "LW" } do
		local slot = ClubDatabase.getSlot(label) :: ClubDatabase.BagSlot
		for _, p in { 25, 50, 75 } do
			local pct = shot(label, baseStats, p, 0).Result.CarryYds / slot.BaseCarryYds * 100
			if math.abs(pct - p) > 6 then
				linear = false
				print(`  power miss {label}@{p}: {pct}%`)
			end
		end
	end
	expect("Carry% tracks power% within 6 points (25/50/75, 5 clubs)", linear)
	local lowP = shot("D", baseStats, 25, 0).Result.CarryYds
	local highP = shot("D", baseStats, 75, 0).Result.CarryYds
	expect("More power -> strictly more carry", lowP < highP and highP < shot("D", baseStats, 100, 0).Result.CarryYds)

	-- Distance stat.
	local weak = shot("D", { Distance = 50, Accuracy = 60, Forgiveness = 60 }, 100, 0).Result.CarryYds
	local strong = shot("D", { Distance = 90, Accuracy = 60, Forgiveness = 60 }, 100, 0).Result.CarryYds
	expect("Higher Distance stat -> more carry", strong > weak + 15)

	-- Curve direction & monotonic severity.
	local straight = shot("D", baseStats, 100, 0).Result
	local slice = shot("D", baseStats, 100, -0.6).Result
	local hook = shot("D", baseStats, 100, 0.6).Result
	expect("Perfect timing flies dead straight (|lateral| < 0.01 yd)", math.abs(straight.LateralYds) < 0.01)
	expect("Early click (offset<0) slices RIGHT (lateral > 0)", slice.LateralYds > 10)
	expect("Late click (offset>0) hooks LEFT (lateral < 0)", hook.LateralYds < -10)
	expect("Slice and hook are mirror images", math.abs(slice.LateralYds + hook.LateralYds) < 0.01)
	local m1, m2, m3 = shot("D", baseStats, 100, -0.3).Result.LateralYds, slice.LateralYds, shot("D", baseStats, 100, -1).Result.LateralYds
	expect("Bigger timing miss -> bigger curve", m1 < m2 and m2 < m3)
	local insideGreen = shot("D", baseStats, 100, 0.05)
	expect("Inside the green zone: Perfect quality, no curve", insideGreen.Quality == "Perfect" and math.abs(insideGreen.Result.LateralYds) < 0.01)
	expect("Quality bands: Good at 0.2, Poor at 0.8", shot("D", baseStats, 100, 0.2).Quality == "Good" and shot("D", baseStats, 100, 0.8).Quality == "Poor")
	local lowAcc = shot("D", { Distance = 50, Accuracy = 20, Forgiveness = 60 }, 100, -0.6).Result.LateralYds
	local highAcc = shot("D", { Distance = 50, Accuracy = 95, Forgiveness = 60 }, 100, -0.6).Result.LateralYds
	expect("Higher Accuracy stat -> smaller curve for the same miss", highAcc < lowAcc * 0.8)

	-- Wind.
	local head = shot("D", baseStats, 100, 0, nil, SwingMath.windToLocal(15, 180, 0)).Result
	local tail = shot("D", baseStats, 100, 0, nil, SwingMath.windToLocal(15, 0, 0)).Result
	local cross = shot("D", baseStats, 100, 0, nil, SwingMath.windToLocal(15, 90, 0)).Result
	expect("Headwind shortens, tailwind lengthens carry", head.CarryYds < straight.CarryYds - 10 and tail.CarryYds > straight.CarryYds + 10)
	expect("Wind from the left (blowing right) pushes the ball right", cross.LateralYds > 10)
	local windLocal = SwingMath.windToLocal(10, 90, 90)
	expect("windToLocal: wind along the aim is a pure tailwind", math.abs(windLocal.Z) < 1e-9 and windLocal.X > 4.4 and windLocal.X < 4.5)

	-- Lies.
	local lieCarry = {}
	for _, lie in { "Fairway", "Rough", "Sand" } do
		lieCarry[lie] = shot("7i", baseStats, 100, 0, lie :: Types.LieId).Result.CarryYds
	end
	expect("Lie penalty: Fairway > Rough > Sand carry", lieCarry.Fairway > lieCarry.Rough and lieCarry.Rough > lieCarry.Sand)
	local sandLowF = shot("7i", { Distance = 50, Accuracy = 60, Forgiveness = 10 }, 100, -0.5, "Sand").Result.LateralYds
	local sandHighF = shot("7i", { Distance = 50, Accuracy = 60, Forgiveness = 95 }, 100, -0.5, "Sand").Result.LateralYds
	expect("Forgiveness softens the lie's accuracy penalty", sandHighF < sandLowF)

	-- Roll / bounce / spin.
	local function onGreenAt(distanceM: number): ShotPhysics.Terrain
		local g = ShotPhysics.flatTerrain("Green")
		return {
			heightAt = g.heightAt,
			slopeAt = g.slopeAt,
			lieAt = function(x: number, _z: number): Types.LieId
				return if x > distanceM then "Green" else "Fairway"
			end,
		}
	end
	local function toGreen(label: string): ShotPhysics.ShotResult
		local slot = ClubDatabase.getSlot(label) :: ClubDatabase.BagSlot
		-- Green starts 20 m short of the ball's carry.
		local terrain = onGreenAt(slot.BaseCarryYds * P_YD - 20)
		return SwingMath.resolveShot({ Slot = slot, Stats = baseStats, Power = 100, AccuracyOffset = 0, Lie = "Fairway" }, terrain, nil).Result
	end
	local driverGreen, lwGreen = toGreen("D"), toGreen("LW")
	expect("Driver releases forward on a green; lob wedge checks up (roll: driver > 10 yd, wedge < 2 yd)", driverGreen.RollYds > 10 and lwGreen.RollYds < 2)
	expect("Flight samples are time-ordered and start at the origin", (function()
		local s = driverGreen.Samples
		if #s < 10 or s[1].X ~= 0 or s[1].T ~= 0 then
			return false
		end
		for i = 2, #s do
			if s[i].T < s[i - 1].T then
				return false
			end
		end
		return true
	end)())

	-- Water.
	local lakeTerrain: ShotPhysics.Terrain = {
		heightAt = fairway.heightAt,
		slopeAt = fairway.slopeAt,
		lieAt = function(x: number, _z: number): Types.LieId
			return if x > 100 then "Water" else "Fairway"
		end,
	}
	local drowned = SwingMath.resolveShot({
		Slot = ClubDatabase.getSlot("D") :: ClubDatabase.BagSlot, Stats = baseStats, Power = 100, AccuracyOffset = 0, Lie = "Fairway",
	}, lakeTerrain, nil).Result
	expect("Landing in water ends the shot with Outcome Water (no roll)", drowned.Outcome == "Water" and math.abs(drowned.RollYds) < 1e-6)

	-- Putting.
	local function putt(power: number, offset: number, terrain: ShotPhysics.Terrain?, cup: ShotPhysics.Cup?): ShotPhysics.ShotResult
		return SwingMath.resolveShot({
			Slot = ClubDatabase.getSlot("PT") :: ClubDatabase.BagSlot, Stats = baseStats, Power = power, AccuracyOffset = offset, Lie = "Green",
		}, terrain or ShotPhysics.flatTerrain("Green"), cup).Result
	end
	local p100, p50 = putt(100, 0, nil, nil), putt(50, 0, nil, nil)
	expect("100% putt rolls ~PuttFullPowerYards (40 +/- 1)", math.abs(p100.TotalYds - 40) < 1)
	expect("Putt distance is linear in power (50% -> 20 +/- 1)", math.abs(p50.TotalYds - 20) < 1)
	expect("Putts have no carry or apex", p100.CarryYds == 0 and p100.ApexFeet == 0)
	expect("Early putt pushes right, late pulls left", putt(50, -0.6, nil, nil).LateralYds > 0.3 and putt(50, 0.6, nil, nil).LateralYds < -0.3)
	-- Slope: a 3% cross-slope (green falls toward +Z) must drag a straight putt right.
	local sloped = ShotPhysics.flatTerrain("Green")
	local breaking: ShotPhysics.Terrain = {
		heightAt = sloped.heightAt,
		lieAt = sloped.lieAt,
		slopeAt = function(_x: number, _z: number): (number, number)
			return 0, -0.03 -- height decreases toward +Z -> ball rolls right
		end,
	}
	local brk = putt(50, 0, breaking, nil)
	expect("Green slope makes a straight putt break downhill (lateral > 0.5 yd)", brk.LateralYds > 0.5)
	local uphill: ShotPhysics.Terrain = {
		heightAt = sloped.heightAt,
		lieAt = sloped.lieAt,
		slopeAt = function(_x: number, _z: number): (number, number)
			return 0.03, 0 -- rises downrange
		end,
	}
	expect("Uphill putt rolls shorter than flat", putt(50, 0, uphill, nil).TotalYds < p50.TotalYds - 2)
	-- A ball on a slope steeper than rolling friction never stays at rest.
	local steep: ShotPhysics.Terrain = {
		heightAt = sloped.heightAt,
		lieAt = sloped.lieAt,
		slopeAt = function(_x: number, _z: number): (number, number)
			return 0, -0.10
		end,
	}
	local rolledOff = putt(1, 0, steep, nil)
	expect("Ball on a 10% green slope (> friction 5.6%) rolls away from rest", rolledOff.TotalSeconds > 5 and rolledOff.LateralYds > 5)
	-- Cup capture: put the cup where a 20%-power putt naturally dies (just short of
	-- its rest point) so the ball arrives slowly; a 100% putt on the same line
	-- arrives far too fast and lips over.
	local dying = putt(20, 0, nil, nil)
	local cup: ShotPhysics.Cup = { X = dying.FinalX * 0.98, Z = 0 }
	local drop = putt(20, 0, nil, cup)
	expect("Slow putt through the cup is holed (ball snaps to the cup)", drop.Outcome == "Holed" and math.abs(drop.FinalX - cup.X) < 1e-9)
	local fast = putt(100, 0, nil, cup)
	expect("Same line at 100% power rolls past the cup (lip-out)", fast.Outcome == "Rest" and fast.FinalX > cup.X + 5)
	local offLine = putt(20, 0.6, nil, cup)
	expect("Missing the line (late click) doesn't hole it", offLine.Outcome == "Rest")

	-- Determinism.
	local a = shot("D", baseStats, 83, -0.37, "Rough", SwingMath.windToLocal(12, 140, 20)).Result
	local b = shot("D", baseStats, 83, -0.37, "Rough", SwingMath.windToLocal(12, 140, 20)).Result
	expect("Identical inputs give bit-identical results (no RNG)", a.TotalYds == b.TotalYds and a.LateralYds == b.LateralYds and #a.Samples == #b.Samples)

	-- Apex heights for the telemetry overlay.
	print(`  apex heights (ft): D {math.floor(straight.ApexFeet)} | 7i {math.floor(shot("7i", baseStats, 100, 0).Result.ApexFeet)} | LW {math.floor(shot("LW", baseStats, 100, 0).Result.ApexFeet)}`)
end

for _, caseId in CaseDatabase.Order do
	print(`case {caseId}: expected sell value {CaseDatabase.expectedSellValue(caseId)} vs price {CaseDatabase.Cases[caseId].Price.Amount}`)
end

if failures > 0 then
	error(`{failures} check(s) failed`)
end
print("ALL CHECKS PASSED")
