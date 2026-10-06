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
local TableUtil = require("./TableUtil")
local ProfileTemplate = require("./ProfileTemplate")
local ProfileOps = require("./ProfileOps")
local ProfileStore = require("./ProfileStore")
local MemoryBackend = require("./MemoryBackend")

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


-- Profile template / repair ---------------------------------------------------
print("-- profile template")
do
	local fresh = ProfileTemplate.new(1000)
	expect("New profile: starting coins/gems from Config", fresh.Coins == Config.Economy.StartingCoins and fresh.Gems == Config.Economy.StartingGems)
	local everySlotEquipped = true
	for _, category in ItemDatabase.Categories do
		for _, slot in ItemDatabase.CategorySlots[category] do
			local equipped = fresh.EquippedItems[slot]
			local item = ItemDatabase.get(equipped)
			if not (item and item.Slot == slot and fresh.OwnedItems[item.Id] == 1) then
				everySlotEquipped = false
			end
		end
	end
	expect("New profile: every cosmetic slot has an owned, equipped default", everySlotEquipped)
	local bagFull = true
	for _, slot in ClubDatabase.BagSlots do
		local club = ClubDatabase.get(fresh.EquippedClubs[slot.Label])
		if not (club and club.SlotLabel == slot.Label and fresh.OwnedClubs[club.Id]) then
			bagFull = false
		end
	end
	expect("New profile: all 14 bag slots hold an owned starter club", bagFull)
	local prepared = ProfileTemplate.prepare(TableUtil.deepCopy(fresh), 2000)
	expect("A fresh profile survives prepare() unchanged", prepared ~= nil and prepared.Coins == fresh.Coins and prepared.Meta.CreatedAt == 1000)

	-- Repair: garbage in every field.
	local dirty: any = TableUtil.deepCopy(fresh)
	dirty.Coins = -50
	dirty.Gems = 0 / 0
	dirty.OwnedItems["skin_that_was_removed"] = 3
	dirty.OwnedItems["skin_crimson_driver"] = 2.9
	dirty.OwnedItems["skin_nebula_driver"] = -1
	dirty.EquippedItems["Driver"] = "skin_gold_rush_driver" -- not owned
	dirty.EquippedItems["Iron"] = "skin_crimson_driver" -- wrong slot
	dirty.EquippedClubs["D"] = "ghost_club"
	dirty.OwnedClubs["ghost_club"] = true
	dirty.ClubUpgrades["tatermade_swift_d"] = { Distance = 99, Accuracy = -4, Forgiveness = "x" }
	dirty.ClubUpgrades["pong_gale_d"] = { Distance = 3, Accuracy = 3, Forgiveness = 3 } -- not owned
	dirty.Stats = nil
	local repaired = ProfileTemplate.prepare(dirty, 3000)
	expect("prepare() repairs a badly damaged profile instead of rejecting it", repaired ~= nil)
	if repaired then
		expect("Repair: negative/NaN balances become 0", repaired.Coins == 0 and repaired.Gems == 0)
		expect("Repair: removed items dropped, fractional counts floored, negatives dropped", repaired.OwnedItems["skin_that_was_removed"] == nil and repaired.OwnedItems["skin_crimson_driver"] == 2 and repaired.OwnedItems["skin_nebula_driver"] == nil)
		expect("Repair: unowned / wrong-slot equips reset to defaults", repaired.EquippedItems["Driver"] == "skin_midnight_driver" and repaired.EquippedItems["Iron"] == "skin_midnight_iron")
		expect("Repair: unknown clubs removed, bag refilled with starters", repaired.OwnedClubs["ghost_club"] == nil and repaired.EquippedClubs["D"] == "tatermade_swift_d")
		local lv = repaired.ClubUpgrades["tatermade_swift_d"]
		expect("Repair: upgrade levels clamped to 0..Max, unowned club upgrades dropped", lv ~= nil and lv.Distance == Config.Clubs.MaxUpgradeLevel and lv.Accuracy == 0 and lv.Forgiveness == 0 and repaired.ClubUpgrades["pong_gale_d"] == nil)
		expect("Repair: missing Stats section rebuilt", repaired.Stats.Wins == 0 and repaired.Stats.CasesOpened == 0)
	end

	local _, reasonText = ProfileTemplate.prepare("not a table", 0)
	local _, reasonNoVersion = ProfileTemplate.prepare({ Coins = 5 }, 0)
	local _, reasonNew = ProfileTemplate.prepare({ SchemaVersion = ProfileTemplate.CURRENT_VERSION + 1 }, 0)
	expect("Non-table / versionless data is 'corrupt'; newer schema is 'too_new'", reasonText == "corrupt" and reasonNoVersion == "corrupt" and reasonNew == "too_new")

	-- Migrations run in order, in place, and fill fields the new version added.
	local old: any = TableUtil.deepCopy(fresh)
	old.SchemaVersion = 1
	local ran: { number } = {}
	local migrated = ProfileTemplate.prepare(old, 0, {
		CurrentVersion = 3,
		Migrations = {
			[1] = function(d: any)
				table.insert(ran, 1)
				d.Coins += 100
			end,
			[2] = function(d: any)
				table.insert(ran, 2)
				d.Gems += 7
			end,
		},
	})
	expect("Migrations 1->2->3 run in order and set the new version", migrated ~= nil and #ran == 2 and ran[1] == 1 and ran[2] == 2 and migrated.SchemaVersion == 3 and migrated.Coins == fresh.Coins + 100 and migrated.Gems == fresh.Gems + 7)
	local noPath = ProfileTemplate.prepare(TableUtil.deepCopy(fresh), 0, { CurrentVersion = 3, Migrations = {} })
	expect("A missing migration step is refused, not guessed", noPath == nil)

	local view = ProfileTemplate.clientView(fresh)
	expect("clientView is a detached copy without Meta", view.Meta == nil and view.Coins == fresh.Coins and view ~= (fresh :: any) and fresh.Meta.CreatedAt == 1000)
end

-- Profile operations ----------------------------------------------------------
print("-- profile ops")
do
	local d = ProfileTemplate.new(0)
	local coins0 = d.Coins

	-- Currency
	expect("add coins", ProfileOps.add(d, "Coins", 500) and d.Coins == coins0 + 500 and d.Stats.TotalCoinsEarned == 500)
	local okSpend = ProfileOps.spend(d, { Currency = "Coins", Amount = 200 })
	expect("spend coins", okSpend and d.Coins == coins0 + 300)
	local _, whyBroke = ProfileOps.spend(d, { Currency = "Gems", Amount = 1 })
	expect("spend with insufficient funds is refused and changes nothing", whyBroke == "insufficient_funds" and d.Gems == 0)
	local before = d.Coins
	local badAmounts = { -5, 0, 1.5, 0 / 0, math.huge }
	local allBad = true
	for _, amount in badAmounts do
		local addOk = ProfileOps.add(d, "Coins", amount)
		local spendOk = ProfileOps.spend(d, { Currency = "Coins", Amount = amount })
		if addOk or spendOk then
			allBad = false
		end
	end
	expect("Negative / zero / fractional / NaN / infinite amounts are all rejected", allBad and d.Coins == before)
	ProfileOps.add(d, "Coins", Config.Economy.MaxCoins * 2)
	expect("Balances clamp at MaxCoins", d.Coins == Config.Economy.MaxCoins)
	d.Coins = coins0

	-- Items: stacks, reserved copies, equip
	expect("grantItem stacks duplicates", ProfileOps.grantItem(d, "skin_crimson_driver", 3) and ProfileOps.ownedCount(d, "skin_crimson_driver") == 3)
	local _, whyUnknown = ProfileOps.grantItem(d, "nope", 1)
	local _, whyCount = ProfileOps.grantItem(d, "skin_crimson_driver", 0)
	expect("grantItem rejects unknown ids and bad counts", whyUnknown == "unknown_item" and whyCount == "bad_count")
	expect("Starter item: 1 copy is reserved, so nothing is spare", ProfileOps.reservedCount(d, "skin_midnight_driver") == 1 and ProfileOps.spareCount(d, "skin_midnight_driver") == 0)
	local _, whyStarter = ProfileOps.removeItem(d, "skin_midnight_driver", 1)
	expect("Can't sell the only copy of a starter item", whyStarter == "insufficient_spare" and ProfileOps.ownedCount(d, "skin_midnight_driver") == 1)
	expect("Unequipped duplicates are all spare", ProfileOps.spareCount(d, "skin_crimson_driver") == 3)
	expect("equipItem requires ownership", select(2, ProfileOps.equipItem(d, "skin_gold_rush_driver")) == "not_owned")
	expect("equipItem puts the item in its slot", ProfileOps.equipItem(d, "skin_crimson_driver") and d.EquippedItems["Driver"] == "skin_crimson_driver")
	expect("Equipped item keeps one reserved copy (3 owned -> 2 spare)", ProfileOps.spareCount(d, "skin_crimson_driver") == 2)
	local _, whyTooMany = ProfileOps.removeItem(d, "skin_crimson_driver", 3)
	expect("Can't remove the equipped copy", whyTooMany == "insufficient_spare" and ProfileOps.ownedCount(d, "skin_crimson_driver") == 3)
	expect("removeItem of spare copies works and deletes empty stacks", ProfileOps.removeItem(d, "skin_crimson_driver", 2) and ProfileOps.ownedCount(d, "skin_crimson_driver") == 1)
	local _, whyNotOwned = ProfileOps.removeItem(d, "skin_gold_rush_driver", 1)
	expect("removeItem of an unowned item is refused", whyNotOwned == "not_owned")
	ProfileOps.equipItem(d, "skin_midnight_driver")
	expect("After switching away, the old skin's last copy becomes spare", ProfileOps.removeItem(d, "skin_crimson_driver", 1) and d.OwnedItems["skin_crimson_driver"] == nil)

	-- Clubs
	local gale = "pong_gale_d"
	expect("Can't equip an unowned club", select(2, ProfileOps.equipClub(d, gale)) == "not_owned")
	local _, whyBrokeClub = ProfileOps.buyClub(d, gale)
	expect("Can't buy a club you can't afford (nothing taken)", whyBrokeClub == "insufficient_funds" and d.Coins == coins0 and not d.OwnedClubs[gale])
	d.Coins = 20000
	expect("buyClub charges the price and grants the club", ProfileOps.buyClub(d, gale) and d.Coins == 20000 - 12000 and d.OwnedClubs[gale] == true)
	expect("Can't buy a club twice", select(2, ProfileOps.buyClub(d, gale)) == "already_owned")
	expect("Starter clubs aren't for sale", select(2, ProfileOps.buyClub(d, "tatermade_swift_3w")) == "already_owned")
	expect("equipClub fills the club's bag slot", ProfileOps.equipClub(d, gale) and d.EquippedClubs["D"] == gale)

	-- Upgrades
	d.Coins = 100000
	local stats0 = ProfileOps.clubStats(d, gale) :: ClubDatabase.Stats
	expect("Unupgraded stats equal base stats", stats0.Distance == 78 and stats0.Accuracy == 72 and stats0.Forgiveness == 75)
	local ok1, _, lvl1 = ProfileOps.upgradeClub(d, gale, "Distance")
	local afterFirst = d.Coins
	expect("First upgrade costs 500 and gives +2 stat points", ok1 and lvl1 == 1 and afterFirst == 100000 - 500 and (ProfileOps.clubStats(d, gale) :: ClubDatabase.Stats).Distance == 80)
	local ok2, _, lvl2 = ProfileOps.upgradeClub(d, gale, "Distance")
	expect("Second upgrade costs 700", ok2 and lvl2 == 2 and d.Coins == afterFirst - 700)
	expect("Other stats are untouched", (ProfileOps.clubStats(d, gale) :: ClubDatabase.Stats).Accuracy == 72)
	expect("Unknown stat / unknown club / unowned club rejected", select(2, ProfileOps.upgradeClub(d, gale, "Power")) == "bad_stat" and select(2, ProfileOps.upgradeClub(d, "ghost", "Distance")) == "unknown_club" and select(2, ProfileOps.upgradeClub(d, "pong_gale_3w", "Distance")) == "not_owned")
	local broke = ProfileTemplate.new(0)
	broke.Coins = 100
	local okBroke, whyBrokeUp = ProfileOps.upgradeClub(broke, "tatermade_swift_d", "Distance")
	expect("Upgrade without enough coins is refused and free", not okBroke and whyBrokeUp == "insufficient_funds" and broke.Coins == 100 and broke.ClubUpgrades["tatermade_swift_d"] == nil)
	-- Spend every coin and max a stat: cost sequence and the cap.
	local rich = ProfileTemplate.new(0)
	rich.Coins = 1e9
	local paid, lastReason = 0, ""
	for _ = 1, Config.Clubs.MaxUpgradeLevel + 2 do
		local start = rich.Coins
		local ok, why = ProfileOps.upgradeClub(rich, "tatermade_swift_d", "Distance")
		if ok then
			paid += start - rich.Coins
		else
			lastReason = why :: string
			break
		end
	end
	expect("Maxing one stat costs the full table (sum 27,350) then reports max_level", paid == 27350 and lastReason == "max_level")
	expect("Upgrade levels are stored in the profile", rich.ClubUpgrades["tatermade_swift_d"].Distance == Config.Clubs.MaxUpgradeLevel)
	-- StatCap: a 98-Distance club caps at 100 after one upgrade and then refuses.
	local capped = ProfileTemplate.new(0)
	capped.Coins = 1e6
	ProfileOps.grantClub(capped, "callaway_phoenix_d")
	local c1 = ProfileOps.upgradeClub(capped, "callaway_phoenix_d", "Distance")
	local c2, whyCap = ProfileOps.upgradeClub(capped, "callaway_phoenix_d", "Distance")
	expect("Stat caps at 100 and further upgrades are refused (stat_capped)", c1 and not c2 and whyCap == "stat_capped" and (ProfileOps.clubStats(capped, "callaway_phoenix_d") :: ClubDatabase.Stats).Distance == 100)

	-- OVR
	local starterOvr = ProfileOps.playerOvr(ProfileTemplate.new(0))
	expect("Starter bag OVR is the starter line's OVR (60)", starterOvr == ClubDatabase.overall({ Distance = 55, Accuracy = 60, Forgiveness = 65 }))
	local withDriver = ProfileTemplate.new(0)
	withDriver.Coins = 1e6
	ProfileOps.buyClub(withDriver, "tatermade_shadow_d")
	ProfileOps.equipClub(withDriver, "tatermade_shadow_d")
	expect("A better driver raises player OVR", ProfileOps.playerOvr(withDriver) > starterOvr)
end

-- Session-locked persistence ----------------------------------------------------
print("-- profile store")
do
	local storeNow = 1000
	local function clock(): number
		return storeNow
	end
	local waits: { number } = {}
	local function wait(seconds: number)
		table.insert(waits, seconds)
		storeNow += seconds -- time passes while "waiting"
	end
	local function storeFor(backend: MemoryBackend.MemoryBackend, jobId: string): ProfileStore.Store
		return ProfileStore.new(backend, {
			JobId = jobId, Clock = clock, Wait = wait,
			LockTimeoutSeconds = 600, LoadAttempts = 3, RetrySeconds = 2, ReleaseAttempts = 3,
		})
	end

	-- First load creates a profile and takes the lock.
	local backend = MemoryBackend.new()
	local serverA = storeFor(backend, "job-A")
	local first = serverA.loadOnce("Player_1")
	expect("First load creates a new profile", first.Status == "Loaded" and first.Profile ~= nil)
	local profileA = first.Profile :: ProfileStore.Profile
	local rec = backend.peek("Player_1") :: ProfileStore.StoredRecord
	expect("First load writes the record with our lock", rec.Lock ~= nil and (rec.Lock :: ProfileStore.Lock).JobId == "job-A" and rec.Revision == 0)
	expect("Session counter incremented on load", profileA.Data.Meta.Sessions == 1)

	-- Edits only reach the store on save, as a detached snapshot.
	ProfileOps.add(profileA.Data, "Coins", 777)
	expect("Unsaved edits are not in the store yet", (backend.peek("Player_1") :: ProfileStore.StoredRecord).Data.Coins == Config.Economy.StartingCoins)
	storeNow = 1100
	expect("save() succeeds", profileA.save() == "Saved")
	local saved = backend.peek("Player_1") :: ProfileStore.StoredRecord
	expect("save() persists data, bumps revision, refreshes lock time", saved.Data.Coins == Config.Economy.StartingCoins + 777 and saved.Revision == 1 and (saved.Lock :: ProfileStore.Lock).Time == 1100)
	ProfileOps.add(profileA.Data, "Coins", 1)
	expect("Edits after save don't leak into the stored snapshot", (backend.peek("Player_1") :: ProfileStore.StoredRecord).Data.Coins == Config.Economy.StartingCoins + 777)

	-- A second live server is locked out.
	local serverB = storeFor(backend, "job-B")
	storeNow = 1200
	expect("Second server is refused while the lock is fresh", serverB.loadOnce("Player_1").Status == "Locked")
	expect("Refused load wrote nothing and left our lock intact", (backend.peek("Player_1") :: ProfileStore.StoredRecord).Revision == 1 and ((backend.peek("Player_1") :: ProfileStore.StoredRecord).Lock :: ProfileStore.Lock).JobId == "job-A")
	-- ...and after we release, it gets the final data.
	expect("release() saves and unlocks", profileA.release() == "Saved" and not profileA.isActive())
	expect("Released record has no lock", (backend.peek("Player_1") :: ProfileStore.StoredRecord).Lock == nil)
	expect("save() after release is inert", profileA.save() == "Inactive")
	local handoff = serverB.loadOnce("Player_1")
	expect("Second server loads after release with all coins (starting + 777 + 1)", handoff.Status == "Loaded" and (handoff.Profile :: ProfileStore.Profile).Data.Coins == Config.Economy.StartingCoins + 778)

	-- Same server reloading its own lock is fine (e.g. quick re-join to same server).
	expect("Same server can re-acquire its own lock", serverB.loadOnce("Player_1").Status == "Loaded")

	-- Lock takeover after timeout (crashed server), and the stale server can't clobber.
	local crashedBackend = MemoryBackend.new()
	local crashed = storeFor(crashedBackend, "job-X")
	local crashedProfile = (crashed.loadOnce("Player_2")).Profile :: ProfileStore.Profile
	ProfileOps.add(crashedProfile.Data, "Coins", 5000)
	crashedProfile.save()
	local rescuer = storeFor(crashedBackend, "job-Y")
	storeNow += 599
	expect("Lock younger than the timeout still blocks", rescuer.loadOnce("Player_2").Status == "Locked")
	storeNow += 2
	local taken = rescuer.loadOnce("Player_2")
	expect("Lock older than the timeout is taken over", taken.Status == "Loaded")
	ProfileOps.add((taken.Profile :: ProfileStore.Profile).Data, "Coins", 1)
	expect("New owner saves fine", (taken.Profile :: ProfileStore.Profile).save() == "Saved")
	local revBefore = (crashedBackend.peek("Player_2") :: ProfileStore.StoredRecord).Revision
	ProfileOps.add(crashedProfile.Data, "Coins", 999999) -- the "crashed" server wakes up and tries to save
	expect("Stale server's save is rejected as LostLock", crashedProfile.save() == "LostLock" and not crashedProfile.isActive())
	local after = crashedBackend.peek("Player_2") :: ProfileStore.StoredRecord
	expect("Stale server did NOT overwrite the new owner's data", after.Revision == revBefore and after.Data.Coins == Config.Economy.StartingCoins + 5001)
	expect("A LostLock profile never writes again (even release)", crashedProfile.release() == "Inactive" and (crashedBackend.peek("Player_2") :: ProfileStore.StoredRecord).Revision == revBefore)

	-- Backend failures & retries.
	local flaky = MemoryBackend.new()
	local flakyStore = storeFor(flaky, "job-F")
	flaky.failNext(2)
	waits = {}
	local retried = flakyStore.load("Player_3")
	expect("load() retries through 2 backend errors then succeeds", retried.Status == "Loaded" and flaky.calls() == 3 and #waits == 2 and waits[1] == 2)
	flaky.failNext(10)
	local gaveUp = flakyStore.load("Player_4")
	expect("load() gives up with Error after LoadAttempts", gaveUp.Status == "Error" and gaveUp.Profile == nil)
	flaky.failNext(0)
	local p3 = retried.Profile :: ProfileStore.Profile
	flaky.failNext(1)
	expect("save() reports Error on backend failure but stays active", p3.save() == "Error" and p3.isActive())
	expect("...and succeeds on the next attempt (autosave retry)", p3.save() == "Saved")
	flaky.failNext(2)
	expect("release() retries through errors and still unlocks", p3.release() == "Saved" and (flaky.peek("Player_3") :: ProfileStore.StoredRecord).Lock == nil)

	-- load() waits out a lock that is released mid-retry.
	local race = MemoryBackend.new()
	local holder = storeFor(race, "job-H")
	local heldProfile = (holder.loadOnce("Player_5")).Profile :: ProfileStore.Profile
	local waiter = ProfileStore.new(race, {
		JobId = "job-W", Clock = clock,
		Wait = function(seconds: number)
			storeNow += seconds
			heldProfile.release() -- the old server finishes saving while the new one waits
		end,
		LockTimeoutSeconds = 600, LoadAttempts = 3, RetrySeconds = 2,
	})
	expect("load() succeeds once the previous server releases during the retry wait", waiter.load("Player_5").Status == "Loaded")
	local stuck = storeFor(race, "job-Z").load("Player_5")
	expect("load() reports Locked when the lock never clears", stuck.Status == "Locked")

	-- Newer / corrupt data is never loaded or overwritten.
	local futureBackend = MemoryBackend.new()
	futureBackend.update("Player_6", function(_old: ProfileStore.StoredRecord?): ProfileStore.StoredRecord?
		return { Data = { SchemaVersion = 99, Coins = 5, FutureField = "keep me" }, Lock = nil, Revision = 7 }
	end)
	local futureStore = storeFor(futureBackend, "job-N")
	expect("Newer-schema data -> TooNew", futureStore.loadOnce("Player_6").Status == "TooNew")
	local futureRec = futureBackend.peek("Player_6") :: ProfileStore.StoredRecord
	expect("TooNew leaves the record untouched and unlocked", futureRec.Data.FutureField == "keep me" and futureRec.Lock == nil and futureRec.Revision == 7)
	expect("TooNew is final, load() does not retry it", (function()
		waits = {}
		local result = futureStore.load("Player_6")
		return result.Status == "TooNew" and #waits == 0
	end)())
	local junkBackend = MemoryBackend.new()
	junkBackend.update("Player_7", function(_old: ProfileStore.StoredRecord?): ProfileStore.StoredRecord?
		return { Data = "garbage", Lock = nil, Revision = 3 }
	end)
	local junkStore = storeFor(junkBackend, "job-J")
	expect("Corrupt data -> Corrupt, record preserved and lock released", junkStore.loadOnce("Player_7").Status == "Corrupt" and (junkBackend.peek("Player_7") :: ProfileStore.StoredRecord).Data == "garbage" and (junkBackend.peek("Player_7") :: ProfileStore.StoredRecord).Lock == nil)

	-- A damaged-but-recoverable stored profile is repaired on load and saved back repaired.
	local damagedBackend = MemoryBackend.new()
	damagedBackend.update("Player_8", function(_old: ProfileStore.StoredRecord?): ProfileStore.StoredRecord?
		local d: any = ProfileTemplate.new(5)
		d.Coins = -999
		d.OwnedItems["removed_item"] = 4
		return { Data = d, Lock = nil, Revision = 1 }
	end)
	local healed = storeFor(damagedBackend, "job-R").loadOnce("Player_8")
	local healedProfile = healed.Profile :: ProfileStore.Profile
	expect("Load repairs damaged data before handing it out", healed.Status == "Loaded" and healedProfile.Data.Coins == 0 and healedProfile.Data.OwnedItems["removed_item"] == nil)
	healedProfile.release()
	local healedRec = damagedBackend.peek("Player_8") :: ProfileStore.StoredRecord
	expect("The repaired version is what gets saved back", healedRec.Data.Coins == 0 and healedRec.Data.OwnedItems["removed_item"] == nil)

	-- End to end: a purchase survives release -> reload.
	local e2e = MemoryBackend.new()
	local s1 = storeFor(e2e, "job-1")
	local pr = (s1.load("Player_9")).Profile :: ProfileStore.Profile
	pr.Data.Coins = 50000
	local bought = ProfileOps.buyClub(pr.Data, "titleless_tour_7i") and ProfileOps.equipClub(pr.Data, "titleless_tour_7i")
	local upgraded = ProfileOps.upgradeClub(pr.Data, "titleless_tour_7i", "Accuracy")
	pr.release()
	local again = (storeFor(e2e, "job-2").load("Player_9")).Profile :: ProfileStore.Profile
	expect("Purchase + equip + upgrade survive release and reload", bought and upgraded and again.Data.Coins == 50000 - 20000 - 500 and again.Data.EquippedClubs["7i"] == "titleless_tour_7i" and again.Data.ClubUpgrades["titleless_tour_7i"].Accuracy == 1 and again.Data.Meta.Sessions == 2)
end

for _, caseId in CaseDatabase.Order do
	print(`case {caseId}: expected sell value {CaseDatabase.expectedSellValue(caseId)} vs price {CaseDatabase.Cases[caseId].Price.Amount}`)
end

if failures > 0 then
	error(`{failures} check(s) failed`)
end
print("ALL CHECKS PASSED")
