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
local Prng = require("./Prng")
local ShopRotation = require("./ShopRotation")
local CaseRoller = require("./CaseRoller")
local Economy = require("./Economy")
local CourseDatabase = require("./CourseDatabase")
local CourseTerrain = require("./CourseTerrain")
local MatchEngine = require("./MatchEngine")
local BotBrain = require("./BotBrain")
local Matchmaker = require("./Matchmaker")
local MatchSettlement = require("./MatchSettlement")

local Types = require("./Types")
local P_YD = Config.Physics.YardsToMeters -- metres per yard

local failures = 0
local function expect(label: string, condition: any)
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


-- PRNG -----------------------------------------------------------------------
print("-- prng")
do
	-- Known-answer vectors from an independent Python implementation of mulberry32.
	local vectors: { { any } } = {
		{ 0, { 0.26642920868471265, 0.0003297457005828619, 0.2232720274478197, 0.1462021479383111 } },
		{ 12345, { 0.9797282677609473, 0.3067522644996643, 0.484205421525985, 0.817934412509203 } },
		{ 4294967295, { 0.8964226141106337, 0.189478256739676, 0.7156526781618595, 0.9440599093213677 } },
	}
	local allMatch = true
	for _, vector in vectors do
		local prng = Prng.new(vector[1])
		for _, expected in vector[2] do
			if math.abs(prng.next() - expected) > 1e-15 then
				allMatch = false
			end
		end
	end
	expect("Prng matches independent reference output (3 seeds x 4 values)", allMatch)
	local a, b = Prng.new(99), Prng.new(99)
	local same = true
	for _ = 1, 100 do
		if a.next() ~= b.next() then
			same = false
		end
	end
	expect("Same seed -> same sequence", same)
	local g = Prng.new(7)
	local lo, hi, sum, n = 1, 0, 0, 100000
	local inRange = true
	for _ = 1, n do
		local v = g.next()
		lo, hi, sum = math.min(lo, v), math.max(hi, v), sum + v
		local k = g.nextInt(6)
		if k < 1 or k > 6 or math.floor(k) ~= k then
			inRange = false
		end
	end
	expect("Prng stays in [0,1), mean ~0.5, nextInt in [1,n]", lo >= 0 and hi < 1 and math.abs(sum / n - 0.5) < 0.01 and inRange)
	local nonNeg = Prng.new(-5)
	expect("Negative / fractional seeds are handled", nonNeg.next() >= 0 and Prng.new(1.7).next() == Prng.new(1).next())
end

-- Daily shop ------------------------------------------------------------------
print("-- shop rotation")
do
	local DAY = Config.Shop.RotationSeconds
	local expectedSlots = 0
	for _, rarityId in Rarity.Order do
		expectedSlots += Config.Shop.SlotsPerRarity[rarityId]
	end
	local day = ShopRotation.indexAt(1_750_000_000)
	local offers = ShopRotation.offersFor(day)
	expect("Shop offers exactly the configured number of slots", #offers == expectedSlots)
	local seen: { [string]: boolean } = {}
	local distinct, noStarters, pricesOk = true, true, true
	local perTier: { [string]: number } = {}
	for _, offer in offers do
		if seen[offer.ItemId] then
			distinct = false
		end
		seen[offer.ItemId] = true
		local item = ItemDatabase.get(offer.ItemId) :: ItemDatabase.Item
		if item.Default then
			noStarters = false
		end
		perTier[offer.Rarity] = (perTier[offer.Rarity] or 0) + 1
		local info = Rarity.Info[offer.Rarity]
		-- Spec: Common..Legendary strictly coins; Mythical strictly gems.
		local wantCurrency = if offer.Rarity == "Mythical" then "Gems" else "Coins"
		if item.Rarity ~= offer.Rarity or offer.Price.Currency ~= wantCurrency or offer.Price.Amount ~= info.ShopPrice.Amount then
			pricesOk = false
		end
	end
	expect("Offers are distinct items and never starter items", distinct and noStarters)
	expect("Per-tier counts match config; prices follow rarity (Mythical = gems only)", pricesOk and perTier.Common == 3 and perTier.Rare == 2 and perTier.Mythical == 1)
	local again = ShopRotation.offersFor(day)
	local sameOffers = #again == #offers
	for i, offer in offers do
		if again[i].ItemId ~= offer.ItemId then
			sameOffers = false
		end
	end
	expect("Same day -> identical offers (every server agrees)", sameOffers)
	expect("Index flips exactly at the rotation boundary", ShopRotation.indexAt(day * DAY + DAY - 1) == day and ShopRotation.indexAt((day + 1) * DAY) == day + 1 and ShopRotation.endsAt(day) == (day + 1) * DAY)
	local differs = false
	for d = day + 1, day + 5 do
		local other = ShopRotation.offersFor(d)
		for i, offer in offers do
			if other[i].ItemId ~= offer.ItemId then
				differs = true
			end
		end
	end
	expect("Different days show different shops", differs)
	local mythicSeen: { [string]: boolean } = {}
	local covered = 0
	for d = day, day + 364 do
		for _, offer in ShopRotation.offersFor(d) do
			if offer.Rarity == "Mythical" and not mythicSeen[offer.ItemId] then
				mythicSeen[offer.ItemId] = true
				covered += 1
			end
		end
	end
	expect("Over a year most Mythical shop items rotate through (>=15 of the pool)", covered >= 15)
	expect("findOffer finds offered items only", ShopRotation.findOffer(day, offers[1].ItemId) ~= nil and ShopRotation.findOffer(day, "skin_midnight_driver") == nil)
end

-- Case roller -------------------------------------------------------------------
print("-- case roller")
do
	local weights = CaseDatabase.DefaultDropWeights
	local prng = Prng.new(2024)
	local N = 200000
	local counts: { [string]: number } = {}
	for _ = 1, N do
		local r = CaseRoller.rollRarity(weights, prng.next)
		counts[r] = (counts[r] or 0) + 1
	end
	local within = true
	for _, rarityId in Rarity.Order do
		local pct = (counts[rarityId] or 0) / N * 100
		local want = weights[rarityId] / 100
		if math.abs(pct - want) > 0.5 then
			within = false
			print(`  rarity {rarityId}: {pct}% vs {want}%`)
		end
	end
	expect("200k rolls match 45/30/15/7/2/1% (within 0.5 pt)", within)
	local function constant(v: number): () -> number
		return function(): number
			return v
		end
	end
	expect("rng=0 -> Common; rng just below 1 -> Mythical; rng=1.0 is clamped, not out of range", CaseRoller.rollRarity(weights, constant(0)) == "Common" and CaseRoller.rollRarity(weights, constant(0.99999999)) == "Mythical" and CaseRoller.rollRarity(weights, constant(1)) == "Mythical")
	expect("Tier boundaries are exact (0.4499 -> Common, 0.45 -> Uncommon, 0.9899 -> Legendary, 0.99 -> Mythical)", CaseRoller.rollRarity(weights, constant(0.4499)) == "Common" and CaseRoller.rollRarity(weights, constant(0.45)) == "Uncommon" and CaseRoller.rollRarity(weights, constant(0.9899)) == "Legendary" and CaseRoller.rollRarity(weights, constant(0.99)) == "Mythical")
	-- Every case only ever drops its own category, and every item is reachable.
	local allGood = true
	for _, caseId in CaseDatabase.Order do
		local case = CaseDatabase.Cases[caseId]
		local reached: { [string]: boolean } = {}
		local reachedCount = 0
		local p2 = Prng.new(77)
		for _ = 1, 150000 do
			local item = CaseRoller.rollItem(case, p2.next)
			if item.Category ~= case.Category then
				allGood = false
			end
			if not reached[item.Id] then
				reached[item.Id] = true
				reachedCount += 1
			end
		end
		local total = 0
		for _, rarityId in Rarity.Order do
			total += #CaseDatabase.getPool(caseId, rarityId)
		end
		if reachedCount ~= total then
			allGood = false
			print(`  case {caseId}: reached {reachedCount} of {total} items`)
		end
	end
	expect("Each case drops only its category and every item is reachable", allGood)
end

-- Economy -----------------------------------------------------------------------
print("-- economy")
do
	local NOW = 1_750_000_000
	local prng = Prng.new(555)
	local function ctx(now: number?): Economy.Context
		return { Now = now or NOW, Rng = prng.next }
	end
	local function fresh(coins: number?, gems: number?): ProfileTemplate.ProfileData
		local d = ProfileTemplate.new(0)
		d.Coins = coins or 100000
		d.Gems = gems or 0
		return d
	end
	local function deepEqual(a: any, b: any): boolean
		if type(a) ~= type(b) then
			return false
		end
		if type(a) ~= "table" then
			return a == b
		end
		for k, v in a do
			if not deepEqual(v, b[k]) then
				return false
			end
		end
		for k in b do
			if a[k] == nil then
				return false
			end
		end
		return true
	end

	-- Transactions
	do
		local d = fresh()
		local keep = d
		local before = TableUtil.deepCopy(d)
		local ok, why = Economy.atomic(d, function(): (boolean, string?)
			d.Coins = 1
			d.OwnedItems["skin_nebula_driver"] = 99
			d.Shop.Purchased["x"] = true
			return false, "nope"
		end)
		expect("atomic: a failing step is rolled back completely and reports its reason", not ok and why == "nope" and deepEqual(before, d))
		local ok2, why2 = Economy.atomic(d, function(): (boolean, string?)
			d.Coins = 5
			error("boom")
		end)
		expect("atomic: a throwing step is rolled back and reported as internal_error", not ok2 and why2 == "internal_error" and deepEqual(before, d))
		expect("atomic: the profile table keeps its identity", d == keep)
		local ok3 = Economy.atomic(d, function(): (boolean, string?)
			d.Coins = 7
			return true, nil
		end)
		expect("atomic: a successful step is kept", ok3 and d.Coins == 7)
	end

	-- Opening cases
	do
		local d = fresh(100000)
		local r = Economy.openCases(d, "club_skins_case", 3, ctx())
		local drops = r.Drops :: { Economy.Drop }
		expect("openCases: charges price x count exactly", r.ok and d.Coins == 100000 - 3 * 5000 and (r.Spent :: Types.Price).Amount == 15000)
		local granted = 0
		for _, drop in drops do
			local item = ItemDatabase.get(drop.ItemId) :: ItemDatabase.Item
			if item.Category == "ClubSkin" and item.Rarity == drop.Rarity then
				granted += 1
			end
		end
		expect("openCases: 3 drops of the right category, all granted to the profile", #drops == 3 and granted == 3 and d.Stats.CasesOpened == 3)
		local owned = 0
		for id in d.OwnedItems do
			if (ItemDatabase.get(id) :: ItemDatabase.Item).Category == "ClubSkin" then
				owned += d.OwnedItems[id]
			end
		end
		expect("openCases: inventory gained exactly 3 club skins on top of the starters", owned == 3 + 5)
		expect("openCases: IsNew is true for first copies", (function()
			local d2 = fresh()
			local r2 = Economy.openCases(d2, "animations_case", 1, { Now = NOW, Rng = function(): number
				return 0 -- Common, first pool item
			end })
			local drop = (r2.Drops :: { Economy.Drop })[1]
			-- First Common animation (sorted by Id) is emote_fistpump, a starter already owned.
			return r2.ok and drop.IsNew == false
		end)())
		local rich = fresh(1e9)
		for _, badCount in { 0, 11, 1.5, -1, 0 / 0, math.huge, "3", false } do
			local before = TableUtil.deepCopy(rich)
			local rr = Economy.openCases(rich, "club_skins_case", badCount, ctx())
			if rr.ok or rr.reason ~= "bad_count" or not deepEqual(before, rich) then
				expect("openCases rejects bad count " .. tostring(badCount), false)
			end
		end
		local nilCount = Economy.openCases(rich, "club_skins_case", nil, ctx())
		local noCase = Economy.openCases(rich, "gold_case", 1, ctx())
		local numCase = Economy.openCases(rich, 5, 1, ctx())
		expect("openCases rejects bad counts, nil count, unknown and non-string case ids", nilCount.reason == "bad_count" and noCase.reason == "unknown_case" and numCase.reason == "unknown_case")
		local poor = fresh(4999)
		local before = TableUtil.deepCopy(poor)
		local rp = Economy.openCases(poor, "club_skins_case", 1, ctx())
		expect("openCases: 1 coin short -> refused, profile untouched", not rp.ok and rp.reason == "insufficient_funds" and deepEqual(before, poor))
		local exact = fresh(5000)
		expect("openCases: exactly enough coins works and leaves 0", Economy.openCases(exact, "club_skins_case", 1, ctx()).ok and exact.Coins == 0)
		local capLimit = fresh(5000 * 10)
		expect("openCases: max batch (10) works", Economy.openCases(capLimit, "club_skins_case", Config.Economy.MaxCasesPerOpen, ctx()).ok and capLimit.Coins == 0)
	end

	-- Economy sink: open + sell everything must lose coins on average, for every case.
	do
		local sinkOk = true
		for _, caseId in CaseDatabase.Order do
			local case = CaseDatabase.Cases[caseId]
			local d = fresh(1e9)
			local startCoins = d.Coins
			local opened = 0
			local localPrng = Prng.new(31337)
			for _ = 1, 3000 do
				local r = Economy.openCases(d, caseId, 10, { Now = NOW, Rng = localPrng.next })
				opened += 10
				-- sell every spare copy
				local ids: { string } = {}
				for id in d.OwnedItems do
					for _ = 1, ProfileOps.spareCount(d, id) do
						table.insert(ids, id)
					end
				end
				while #ids > 0 do
					local batch: { string } = {}
					for _ = 1, math.min(#ids, Config.Economy.SellBatchMax) do
						table.insert(batch, table.remove(ids) :: string)
					end
					Economy.sellItems(d, batch, ctx())
				end
				if not r.ok then
					break
				end
			end
			local netPerOpen = (d.Coins - startCoins) / opened
			print(`  {caseId}: net coins per opening when selling everything = {math.floor(netPerOpen)} (price {case.Price.Amount})`)
			if netPerOpen >= 0 or netPerOpen < -case.Price.Amount then
				sinkOk = false
			end
		end
		expect("Open-and-sell loop loses coins on every case (cases are a sink, 30k openings each)", sinkOk)
	end

	-- Daily shop
	do
		local d = fresh(1e6, 1e4)
		local shop = Economy.getShop(d, ctx())
		local entries = shop.Offers :: { Economy.ShopEntry }
		local index = ShopRotation.indexAt(NOW)
		expect("getShop lists today's offers, none purchased, with an end time", shop.ok and #entries == #ShopRotation.offersFor(index) and shop.EndsAt == ShopRotation.endsAt(index) and not entries[1].Purchased)
		local coinOffer: Economy.ShopEntry, gemOffer: Economy.ShopEntry
		for _, e in entries do
			if e.Price.Currency == "Coins" and coinOffer == nil then
				coinOffer = e
			elseif e.Price.Currency == "Gems" and gemOffer == nil then
				gemOffer = e
			end
		end
		local coins0, gems0 = d.Coins, d.Gems
		local buy = Economy.buyShopItem(d, coinOffer.ItemId, ctx())
		expect("buyShopItem: charges the rarity's coin price and grants the item", buy.ok and d.Coins == coins0 - coinOffer.Price.Amount and d.Gems == gems0 and ProfileOps.ownedCount(d, coinOffer.ItemId) == 1)
		expect("buyShopItem: second purchase same day refused", Economy.buyShopItem(d, coinOffer.ItemId, ctx()).reason == "already_purchased" and ProfileOps.ownedCount(d, coinOffer.ItemId) == 1)
		local afterBuy = Economy.getShop(d, ctx()).Offers :: { Economy.ShopEntry }
		local flagged = false
		for _, e in afterBuy do
			if e.ItemId == coinOffer.ItemId and e.Purchased then
				flagged = true
			end
		end
		expect("getShop marks the bought item as Purchased", flagged)
		local buyGem = Economy.buyShopItem(d, gemOffer.ItemId, ctx())
		expect("Mythical offer is paid in gems (750) and never coins", buyGem.ok and d.Gems == gems0 - 750 and d.Coins == coins0 - coinOffer.Price.Amount)
		-- Coins can't buy Mythical.
		local coinsOnly = fresh(1e12, 0)
		local before = TableUtil.deepCopy(coinsOnly)
		local tryCoins = Economy.buyShopItem(coinsOnly, gemOffer.ItemId, ctx())
		expect("Rich in coins, zero gems: Mythical purchase refused and nothing changes", tryCoins.reason == "insufficient_funds" and deepEqual(before, coinsOnly))
		expect("Items not in today's shop can't be bought (starter / out-of-rotation / garbage)", Economy.buyShopItem(d, "skin_midnight_driver", ctx()).reason == "not_in_shop" and Economy.buyShopItem(d, "nope", ctx()).reason == "unknown_item" and Economy.buyShopItem(d, 5, ctx()).reason == "unknown_item" and Economy.buyShopItem(d, nil, ctx()).reason == "unknown_item")
		local poor = fresh(0, 0)
		local pb = TableUtil.deepCopy(poor)
		expect("Can't afford -> refused, untouched", Economy.buyShopItem(poor, coinOffer.ItemId, ctx()).reason == "insufficient_funds" and deepEqual(pb, poor))
		-- Next rotation: purchase record resets, and yesterday's offer may be gone.
		local tomorrow = NOW + Config.Shop.RotationSeconds
		local nextIndex = ShopRotation.indexAt(tomorrow)
		local tomorrowOffers = Economy.getShop(d, ctx(tomorrow)).Offers :: { Economy.ShopEntry }
		local anyPurchased = false
		for _, e in tomorrowOffers do
			if e.Purchased then
				anyPurchased = true
			end
		end
		expect("New rotation: old purchases no longer shown as purchased", not anyPurchased)
		-- Pick a coin offer that differs from today's purchase (the same item CAN
		-- legitimately be offered again tomorrow; that's tested right after).
		local tomorrowPick: Economy.ShopEntry? = nil
		for _, e in tomorrowOffers do
			if e.ItemId ~= coinOffer.ItemId and e.Price.Currency == "Coins" and tomorrowPick == nil then
				tomorrowPick = e
			end
		end
		local pick = tomorrowPick :: Economy.ShopEntry
		local newBuy = Economy.buyShopItem(d, pick.ItemId, ctx(tomorrow))
		expect("New rotation: purchase works and the record moves to the new index", newBuy.ok and d.Shop.Rotation == nextIndex and d.Shop.Purchased[pick.ItemId] == true and d.Shop.Purchased[coinOffer.ItemId] == nil)
		-- Same item re-offered on a later day is purchasable again (fresh day, fresh stock).
		local againDay = nextIndex
		local repeatDay: number? = nil
		for dayOffset = 1, 400 do
			for _, offer in ShopRotation.offersFor(againDay + dayOffset) do
				if offer.ItemId == pick.ItemId and repeatDay == nil then
					repeatDay = againDay + dayOffset
				end
			end
		end
		if repeatDay then
			local later = repeatDay * Config.Shop.RotationSeconds + 100
			expect("The same item re-offered on a later day can be bought again", Economy.buyShopItem(d, pick.ItemId, ctx(later)).ok and ProfileOps.ownedCount(d, pick.ItemId) == 2)
		end
	end

	-- Selling
	do
		local d = fresh(0)
		ProfileOps.grantItem(d, "skin_crimson_driver", 3) -- Rare, sells 600
		ProfileOps.grantItem(d, "skin_slate_iron", 2) -- Common, sells 100
		ProfileOps.equipItem(d, "skin_crimson_driver") -- 1 copy reserved
		local r = Economy.sellItems(d, { "skin_crimson_driver", "skin_crimson_driver", "skin_slate_iron" }, ctx())
		expect("sellItems: pays each rarity's SellValue (2x600 + 100 = 1300) and removes the copies", r.ok and r.CoinsGained == 1300 and d.Coins == 1300 and ProfileOps.ownedCount(d, "skin_crimson_driver") == 1 and ProfileOps.ownedCount(d, "skin_slate_iron") == 1)
		local before = TableUtil.deepCopy(d)
		expect("sellItems: can't sell the equipped copy (nothing sold, even the valid part)", Economy.sellItems(d, { "skin_slate_iron", "skin_crimson_driver" }, ctx()).reason == "insufficient_spare" and deepEqual(before, d))
		expect("sellItems: can't sell a starter item", Economy.sellItems(d, { "skin_midnight_driver" }, ctx()).reason == "insufficient_spare" and deepEqual(before, d))
		expect("sellItems: unowned item refused", Economy.sellItems(d, { "skin_gold_rush_driver" }, ctx()).reason == "not_owned" and deepEqual(before, d))
		expect("sellItems: unknown id refused", Economy.sellItems(d, { "ghost" }, ctx()).reason == "unknown_item" and deepEqual(before, d))
		local tooMany: { string } = {}
		for _ = 1, Config.Economy.SellBatchMax + 1 do
			table.insert(tooMany, "skin_slate_iron")
		end
		local bad = { {}, { "a", 5 }, { x = "skin_slate_iron" }, "skin_slate_iron", 5, tooMany }
		local allRefused = Economy.sellItems(d, nil, ctx()).reason == "bad_items"
		for _, input in bad do
			if Economy.sellItems(d, input, ctx()).reason ~= "bad_items" then
				allRefused = false
			end
		end
		expect("sellItems: nil / empty / dictionary / mixed / oversize lists are refused", allRefused and deepEqual(before, d))
		local anti = fresh(0)
		ProfileOps.grantItem(anti, "skin_crimson_driver", 2)
		expect("sellItems: can't sell more copies than owned by repeating the id", Economy.sellItems(anti, { "skin_crimson_driver", "skin_crimson_driver", "skin_crimson_driver" }, ctx()).reason == "insufficient_spare" and ProfileOps.ownedCount(anti, "skin_crimson_driver") == 2)
	end

	-- Trade-up
	do
		local function stackOf(itemId: string, n: number): ProfileTemplate.ProfileData
			local d = fresh(0)
			ProfileOps.grantItem(d, itemId, n)
			return d
		end
		local five = { "skin_crimson_driver", "skin_crimson_driver", "skin_crimson_driver", "skin_crimson_driver", "skin_crimson_driver" }
		local d = stackOf("skin_crimson_driver", 5)
		local r = Economy.tradeUp(d, five, ctx())
		local reward = r.Reward :: Economy.Drop
		local item = ItemDatabase.get(reward.ItemId) :: ItemDatabase.Item
		expect("tradeUp: 5 Rare club skins -> 1 Unique club skin (same category, next tier)", r.ok and item.Rarity == "Unique" and item.Category == "ClubSkin" and reward.Rarity == "Unique")
		expect("tradeUp: inputs consumed, reward granted, stat counted", d.OwnedItems["skin_crimson_driver"] == nil and ProfileOps.ownedCount(d, reward.ItemId) == 1 and d.Stats.TradeUps == 1)
		-- Every input tier works and lands exactly one tier up in the same category.
		local tiersOk = true
		local starters: { [string]: string } = { Common = "skin_slate_driver", Uncommon = "skin_fairway_driver", Rare = "skin_crimson_driver", Unique = "skin_volt_driver", Legendary = "skin_gold_rush_driver" }
		for tier, id in starters do
			local td = stackOf(id, 5)
			local list: { string } = {}
			for _ = 1, 5 do
				table.insert(list, id)
			end
			local tr = Economy.tradeUp(td, list, ctx())
			local want = Rarity.nextTier(tier :: Types.RarityId)
			if not (tr.ok and (tr.Reward :: Economy.Drop).Rarity == want) then
				tiersOk = false
			end
		end
		expect("tradeUp: every tier below Mythical moves exactly one tier up", tiersOk)
		-- Anti-exploit: trading up never beats selling the inputs.
		local noProfit = true
		for tier, id in starters do
			local td = stackOf(id, 5)
			local list: { string } = {}
			for _ = 1, 5 do
				table.insert(list, id)
			end
			local sellInputs = 5 * Rarity.Info[tier :: Types.RarityId].SellValue
			local tr = Economy.tradeUp(td, list, ctx())
			local rewardSell = Rarity.Info[(tr.Reward :: Economy.Drop).Rarity].SellValue
			if rewardSell >= sellInputs then
				noProfit = false
			end
		end
		expect("tradeUp: selling the reward is always worth less than selling the 5 inputs", noProfit)

		local mythic = stackOf("skin_nebula_driver", 5)
		local mythicList = { "skin_nebula_driver", "skin_nebula_driver", "skin_nebula_driver", "skin_nebula_driver", "skin_nebula_driver" }
		local beforeMythic = TableUtil.deepCopy(mythic)
		expect("tradeUp: Mythical has no higher tier -> refused", Economy.tradeUp(mythic, mythicList, ctx()).reason == "max_rarity" and deepEqual(beforeMythic, mythic))
		local d4 = stackOf("skin_crimson_driver", 5)
		local before4 = TableUtil.deepCopy(d4)
		expect("tradeUp: 4 inputs refused", Economy.tradeUp(d4, { "skin_crimson_driver", "skin_crimson_driver", "skin_crimson_driver", "skin_crimson_driver" }, ctx()).reason == "bad_inputs")
		expect("tradeUp: 6 inputs refused", Economy.tradeUp(d4, { "skin_crimson_driver", "skin_crimson_driver", "skin_crimson_driver", "skin_crimson_driver", "skin_crimson_driver", "skin_crimson_driver" }, ctx()).reason == "bad_inputs")
		expect("tradeUp: garbage argument refused", Economy.tradeUp(d4, nil, ctx()).reason == "bad_inputs" and Economy.tradeUp(d4, "five", ctx()).reason == "bad_inputs" and Economy.tradeUp(d4, { 1, 2, 3, 4, 5 }, ctx()).reason == "bad_inputs")
		local mixedRarity = fresh(0)
		ProfileOps.grantItem(mixedRarity, "skin_crimson_driver", 4)
		ProfileOps.grantItem(mixedRarity, "skin_slate_iron", 1)
		expect("tradeUp: mixed rarities refused", Economy.tradeUp(mixedRarity, { "skin_crimson_driver", "skin_crimson_driver", "skin_crimson_driver", "skin_crimson_driver", "skin_slate_iron" }, ctx()).reason == "mixed_rarity")
		local mixedCategory = fresh(0)
		ProfileOps.grantItem(mixedCategory, "skin_crimson_driver", 4)
		ProfileOps.grantItem(mixedCategory, "swing_windup", 1)
		expect("tradeUp: same rarity but mixed categories refused (RequireSameCategory)", Economy.tradeUp(mixedCategory, { "skin_crimson_driver", "skin_crimson_driver", "skin_crimson_driver", "skin_crimson_driver", "swing_windup" }, ctx()).reason == "mixed_category")
		local fourCopies = stackOf("skin_crimson_driver", 4)
		expect("tradeUp: repeating an id more times than you own is refused", Economy.tradeUp(fourCopies, five, ctx()).reason == "insufficient_spare" and ProfileOps.ownedCount(fourCopies, "skin_crimson_driver") == 4)
		local equippedCase = stackOf("skin_crimson_driver", 5)
		ProfileOps.equipItem(equippedCase, "skin_crimson_driver")
		expect("tradeUp: the equipped copy can't be consumed (5 owned, 1 equipped -> only 4 spare)", Economy.tradeUp(equippedCase, five, ctx()).reason == "insufficient_spare")
		expect("tradeUp: unowned / unknown items refused", Economy.tradeUp(fresh(0), five, ctx()).reason == "not_owned" and Economy.tradeUp(fresh(0), { "a", "b", "c", "d", "e" }, ctx()).reason == "unknown_item")
		expect("tradeUp: failed attempts changed nothing", deepEqual(before4, d4))
		-- Mixed 5 distinct items of the same tier+category.
		local distinct = fresh(0)
		local ids = { "skin_crimson_driver", "skin_crimson_wood", "skin_crimson_iron", "skin_crimson_wedge", "skin_ocean_putter" }
		for _, id in ids do
			ProfileOps.grantItem(distinct, id, 1)
		end
		expect("tradeUp: five different items of one rarity and category work", Economy.tradeUp(distinct, ids, ctx()).ok)
	end

	-- Clubs
	do
		local d = fresh(30000)
		local up = Economy.upgradeClub(d, "tatermade_swift_d", "Distance")
		expect("upgradeClub: result reports level and cost", up.ok and up.NewLevel == 1 and up.Cost == 500 and d.Coins == 29500)
		local buy = Economy.buyClub(d, "pong_gale_d")
		expect("buyClub: result reports the coins spent", buy.ok and (buy.Spent :: Types.Price).Amount == 12000 and d.Coins == 17500)
		expect("buyClub / upgradeClub failures carry the reason", Economy.buyClub(d, "pong_gale_d").reason == "already_owned" and Economy.upgradeClub(d, "pong_gale_d", "Power").reason == "bad_stat")
	end

	-- FUZZ: thousands of random valid and invalid operations; invariants after each.
	do
		local fz = Prng.new(20260101)
		local d = fresh(20000, 100)
		local nowT = NOW
		local zctx: Economy.Context = { Now = nowT, Rng = Prng.new(8675309).next }
		local function randomItemId(): any
			local pick = fz.nextInt(14)
			if pick == 1 then
				return nil
			elseif pick == 2 then
				return fz.nextInt(100)
			elseif pick == 3 then
				return ""
			elseif pick == 4 then
				return {}
			elseif pick == 5 then
				return "no_such_item"
			end
			return ItemDatabase.Ordered[fz.nextInt(#ItemDatabase.Ordered)].Id
		end
		local function ownedSpareList(maxCount: number): { string }
			local list: { string } = {}
			for id in d.OwnedItems do
				for _ = 1, ProfileOps.spareCount(d, id) do
					table.insert(list, id)
				end
			end
			table.sort(list)
			local out: { string } = {}
			for i = 1, math.min(maxCount, #list) do
				table.insert(out, list[fz.nextInt(#list)])
			end
			return out
		end
		-- A trade-up candidate: 5 spare copies from one (rarity, category) group.
		local function tradeCandidate(): { string }?
			local groups: { [string]: { string } } = {}
			for id in d.OwnedItems do
				local item = ItemDatabase.get(id) :: ItemDatabase.Item
				local key = item.Rarity .. "/" .. item.Category
				groups[key] = groups[key] or {}
				for _ = 1, ProfileOps.spareCount(d, id) do
					table.insert(groups[key], id)
				end
			end
			local keys = TableUtil.sortedKeys(groups)
			for _, key in keys do
				if #groups[key] >= Config.TradeUp.InputCount then
					local out: { string } = {}
					for i = 1, Config.TradeUp.InputCount do
						table.insert(out, groups[key][i])
					end
					return out
				end
			end
			return nil
		end

		local function invariantError(data: ProfileTemplate.ProfileData): string?
			local function isInt(v: any, lo: number, hi: number): boolean
				return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi
			end
			if not isInt(data.Coins, 0, Config.Economy.MaxCoins) or not isInt(data.Gems, 0, Config.Economy.MaxGems) then
				return "bad balance"
			end
			for id, count in data.OwnedItems do
				if ItemDatabase.get(id) == nil or not isInt(count, 1, 1e6) then
					return "bad owned item " .. tostring(id)
				end
			end
			for _, category in ItemDatabase.Categories do
				for _, slot in ItemDatabase.CategorySlots[category] do
					local item = ItemDatabase.get(data.EquippedItems[slot])
					if not (item and item.Slot == slot and (data.OwnedItems[item.Id] or 0) >= 1) then
						return "bad equipped item in slot " .. slot
					end
				end
			end
			for _, item in ItemDatabase.DefaultItems do
				if (data.OwnedItems[item.Id] or 0) < 1 then
					return "lost starter item " .. item.Id
				end
			end
			for id in data.OwnedClubs do
				if ClubDatabase.get(id) == nil then
					return "bad owned club"
				end
			end
			for _, slot in ClubDatabase.BagSlots do
				local club = ClubDatabase.get(data.EquippedClubs[slot.Label])
				if not (club and club.SlotLabel == slot.Label and data.OwnedClubs[club.Id]) then
					return "bad equipped club " .. slot.Label
				end
			end
			for id, levels in data.ClubUpgrades do
				if not data.OwnedClubs[id] then
					return "upgrades for unowned club"
				end
				for _, stat in { levels.Distance, levels.Accuracy, levels.Forgiveness } do
					if not isInt(stat, 0, Config.Clubs.MaxUpgradeLevel) then
						return "bad upgrade level"
					end
				end
			end
			for _, v in data.Stats :: any do
				if not isInt(v, 0, 1e15) then
					return "bad stat counter"
				end
			end
			-- Nothing the ops produce should ever need load-time repair.
			local repaired = ProfileTemplate.prepare(TableUtil.deepCopy(data), 0)
			if repaired == nil or not deepEqual(repaired, data) then
				return "sanitize would change this profile"
			end
			return nil
		end

		local successes: { [string]: number } = {}
		local steps = 4000
		local problem: string? = nil
		for step = 1, steps do
			if fz.next() < 0.3 then
				ProfileOps.add(d, "Coins", fz.nextInt(150000))
			end
			if fz.next() < 0.08 then
				ProfileOps.add(d, "Gems", fz.nextInt(2000))
			end
			nowT += fz.nextInt(3 * 3600)
			zctx.Now = nowT

			local before = TableUtil.deepCopy(d)
			local opName: string
			local result: { ok: boolean }
			local roll = fz.next()
			if roll < 0.25 then
				opName = "openCases"
				local count: any = if fz.next() < 0.8 then fz.nextInt(10) else fz.nextInt(14) - 2
				local caseId: any = if fz.next() < 0.9 then CaseDatabase.Order[fz.nextInt(3)] else randomItemId()
				result = Economy.openCases(d, caseId, count, zctx)
			elseif roll < 0.40 then
				opName = "buyShopItem"
				local offers = ShopRotation.offersFor(ShopRotation.indexAt(nowT))
				local id: any = if fz.next() < 0.75 then offers[fz.nextInt(#offers)].ItemId else randomItemId()
				result = Economy.buyShopItem(d, id, zctx)
			elseif roll < 0.55 then
				opName = "sellItems"
				local list: any = if fz.next() < 0.8 then ownedSpareList(fz.nextInt(8)) else { randomItemId(), randomItemId() }
				result = Economy.sellItems(d, list, zctx)
			elseif roll < 0.70 then
				opName = "tradeUp"
				local candidate = tradeCandidate()
				local list: any = if candidate and fz.next() < 0.85 then candidate else { randomItemId(), randomItemId(), randomItemId(), randomItemId(), randomItemId() }
				result = Economy.tradeUp(d, list, zctx)
			elseif roll < 0.80 then
				opName = "upgradeClub"
				local clubIds = TableUtil.sortedKeys(d.OwnedClubs :: any)
				local clubId: any = if fz.next() < 0.85 then clubIds[fz.nextInt(#clubIds)] else randomItemId()
				local stat: any = if fz.next() < 0.9 then ({ "Distance", "Accuracy", "Forgiveness" })[fz.nextInt(3)] else randomItemId()
				result = Economy.upgradeClub(d, clubId, stat)
			elseif roll < 0.87 then
				opName = "buyClub"
				local club = ClubDatabase.Ordered[fz.nextInt(#ClubDatabase.Ordered)]
				result = Economy.buyClub(d, if fz.next() < 0.9 then club.Id else randomItemId())
			elseif roll < 0.94 then
				opName = "equipItem"
				local owned = TableUtil.sortedKeys(d.OwnedItems :: any)
				local ok = ProfileOps.equipItem(d, if fz.next() < 0.8 then owned[fz.nextInt(#owned)] else randomItemId())
				result = { ok = ok }
			else
				opName = "equipClub"
				local owned = TableUtil.sortedKeys(d.OwnedClubs :: any)
				local ok = ProfileOps.equipClub(d, if fz.next() < 0.8 then owned[fz.nextInt(#owned)] else randomItemId())
				result = { ok = ok }
			end

			if result.ok then
				successes[opName] = (successes[opName] or 0) + 1
			elseif not deepEqual(before, d) then
				problem = `step {step}: failed {opName} modified the profile`
				break
			end
			local err = invariantError(d)
			if err then
				problem = `step {step} after {opName}: {err}`
				break
			end
		end
		if problem then
			print("  FUZZ PROBLEM: " .. problem)
		end
		local summary: { string } = {}
		for _, name in { "openCases", "buyShopItem", "sellItems", "tradeUp", "upgradeClub", "buyClub", "equipItem", "equipClub" } do
			table.insert(summary, `{name}={successes[name] or 0}`)
		end
		print("  fuzz successes: " .. table.concat(summary, " "))
		expect(`Fuzz: {steps} random operations kept every invariant (failed ops change nothing)`, problem == nil)
		expect("Fuzz exercised the successful paths of every operation", (successes.openCases or 0) > 100 and (successes.buyShopItem or 0) > 50 and (successes.sellItems or 0) > 100 and (successes.tradeUp or 0) > 20 and (successes.upgradeClub or 0) > 50 and (successes.buyClub or 0) > 5 and (successes.equipItem or 0) > 50)
	end
end


-- Course & terrain --------------------------------------------------------------
print("-- course")
do
	local YDS = Config.Physics.YardsToMeters
	local allValid = true
	for _, hole in CourseDatabase.Holes do
		local yards = CourseDatabase.yards(hole)
		local parOk = (hole.Par == 3 and yards < 250) or (hole.Par == 4 and yards >= 250 and yards <= 470) or (hole.Par == 5 and yards > 470)
		local teeOk = CourseTerrain.lieAt(hole, hole.Tee.X, hole.Tee.Z) == "Tee" and CourseTerrain.inBounds(hole, hole.Tee.X, hole.Tee.Z)
		local pinOk = CourseTerrain.lieAt(hole, hole.Pin.X, hole.Pin.Z) == "Green" and CourseTerrain.inBounds(hole, hole.Pin.X, hole.Pin.Z)
		if not (parOk and teeOk and pinOk) then
			allValid = false
			print(`  hole {hole.Id} invalid: yards {yards} par {hole.Par} tee {teeOk} pin {pinOk}`)
		end
	end
	expect("All 6 holes: sensible par for length, tee in bounds, pin on the green", allValid and #CourseDatabase.Holes == 6)
	local h1, h2 = CourseDatabase.hole(1), CourseDatabase.hole(2)
	expect("Hole lookups wrap around (hole 7 = hole 1)", CourseDatabase.hole(7).Id == 1 and CourseDatabase.hole(0).Id == 6)
	expect("Hole 1: 380 yards, fairway / bunker / rough lies", math.abs(CourseDatabase.yards(h1) - 380) < 0.01 and CourseTerrain.lieAt(h1, 150 * YDS, 0) == "Fairway" and CourseTerrain.lieAt(h1, 255 * YDS, -24 * YDS) == "Sand" and CourseTerrain.lieAt(h1, 150 * YDS, 40 * YDS) == "Rough")
	expect("Hole 2: the pond is water, beyond it rough, the pin is on the green", CourseTerrain.lieAt(h2, 95 * YDS, 0) == "Water" and CourseTerrain.lieAt(h2, 145 * YDS, 0) == "Rough" and CourseTerrain.lieAt(h2, 165 * YDS, 4 * YDS) == "Green")
	local dogleg = CourseDatabase.hole(3)
	expect("Dogleg fairway follows both segments", CourseTerrain.lieAt(dogleg, 200 * YDS, 0) == "Fairway" and CourseTerrain.lieAt(dogleg, 370 * YDS, 85 * YDS) == "Fairway" and CourseTerrain.lieAt(dogleg, 370 * YDS, -60 * YDS) == "Rough")
	local priority = {
		Id = 99, Name = "p", Par = 3, Tee = { X = 0, Z = 0 }, Pin = { X = 100, Z = 0 },
		Fairway = { { AX = 0, AZ = 0, BX = 100, BZ = 0, HalfWidth = 10 } },
		Greens = { { X = 50, Z = 0, R = 5 } }, Bunkers = { { X = 50, Z = 0, R = 8 } }, Water = { { X = 50, Z = 0, R = 2 } },
		GreenSlope = { X = 0.1, Z = 0 }, Bounds = { MinX = -10, MaxX = 200, MinZ = -50, MaxZ = 50 },
	} :: CourseDatabase.HoleDef
	expect("Lie priority: water > green > sand > fairway", CourseTerrain.lieAt(priority, 50, 0) == "Water" and CourseTerrain.lieAt(priority, 53, 0) == "Green" and CourseTerrain.lieAt(priority, 56, 0) == "Sand" and CourseTerrain.lieAt(priority, 62, 0) == "Fairway")
	expect("Out of bounds is detected", CourseTerrain.inBounds(h1, 100 * YDS, 0) and not CourseTerrain.inBounds(h1, 100 * YDS, 100 * YDS) and not CourseTerrain.inBounds(h1, -100 * YDS, 0))

	local terrain = CourseTerrain.forHole(h1)
	local rounds = true
	for _, deg in { 0, 33, 90, 180, -75 } do
		local h = math.rad(deg)
		local wx, wz = CourseTerrain.toHole(10, -4, h, 25, 7)
		local bx, bz = CourseTerrain.toShot(10, -4, h, wx, wz)
		if math.abs(bx - 25) > 1e-9 or math.abs(bz - 7) > 1e-9 then
			rounds = false
		end
	end
	expect("toHole / toShot are exact inverses at any heading", rounds)
	local wx90, wz90 = CourseTerrain.toHole(0, 0, math.rad(90), 10, 0)
	local rx90, rz90 = CourseTerrain.toHole(0, 0, math.rad(90), 0, 10)
	expect("Heading 90deg: shot forward = hole +Z, shot right = hole -X", math.abs(wx90) < 1e-9 and math.abs(wz90 - 10) < 1e-9 and math.abs(rx90 + 10) < 1e-9 and math.abs(rz90) < 1e-9)
	local frame = CourseTerrain.shotFrame(terrain, 150 * YDS, 0, 0)
	local lieMatches = true
	for _, probe in { { 0, 0 }, { 105 * YDS, -24 * YDS }, { 200 * YDS, 0 }, { 0, 90 * YDS } } do
		if frame.lieAt(probe[1], probe[2]) ~= terrain.lieAt(150 * YDS + probe[1], probe[2]) then
			lieMatches = false
		end
	end
	expect("shotFrame terrain agrees with the hole-frame terrain", lieMatches)
	-- Stand on the pin, aim 90deg: shot forward = hole +Z, shot right = hole -X, so the
	-- slope (gx, gz) must read (gz, -gx) in the shot frame.
	local slopeFrame = CourseTerrain.shotFrame(terrain, h1.Pin.X, h1.Pin.Z, math.rad(90))
	local sx, sz = slopeFrame.slopeAt(0, 0)
	local gx, gz = terrain.slopeAt(h1.Pin.X, h1.Pin.Z)
	expect("Slope rotates with the frame: (gx, gz) reads (gz, -gx) at heading 90deg, magnitude preserved", math.abs(sx - gz) < 1e-12 and math.abs(sz + gx) < 1e-12 and math.abs(math.sqrt(sx * sx + sz * sz) - math.sqrt(gx * gx + gz * gz)) < 1e-12)
	local pondFrame = CourseTerrain.shotFrame(CourseTerrain.forHole(h2), 0, 0, 0)
	local lwLaunch = SwingMath.computeLaunch({ Slot = ClubDatabase.getSlot("LW") :: ClubDatabase.BagSlot, Stats = { Distance = 50, Accuracy = 60, Forgiveness = 60 }, Power = 100, AccuracyOffset = 0, Lie = "Tee" })
	expect("Physics + terrain: a lob wedge from the tee at the par 3 finds the pond", ShotPhysics.simulate(lwLaunch, pondFrame, nil, nil).Outcome == "Water")
end

-- Matchmaker ----------------------------------------------------------------------
print("-- matchmaker")
do
	local mm = Matchmaker.new()
	expect("Window starts at BaseOvrWindow and grows 2/s, capped", Matchmaker.window(0) == 10 and Matchmaker.window(10) == 30 and Matchmaker.window(10000) == Config.Matchmaking.MaxOvrWindow)
	expect("enqueue works once per player (not twice, not in another league)", mm.enqueue("a", "Pro", 70, 0) and not mm.enqueue("a", "Pro", 70, 1) and not mm.enqueue("a", "Rookie", 70, 1) and mm.isQueued("a"))
	expect("A lone player is not matched", #mm.findMatches(1) == 0 and mm.size("Pro") == 1)
	mm.enqueue("b", "Pro", 75, 2)
	local pairsNow = mm.findMatches(3)
	expect("Two close players pair, oldest first, and leave the queue", #pairsNow == 1 and pairsNow[1].A.PlayerId == "a" and pairsNow[1].B.PlayerId == "b" and mm.size("Pro") == 0 and not mm.isQueued("a"))
	local far = Matchmaker.new()
	far.enqueue("x", "Pro", 40, 0)
	far.enqueue("y", "Pro", 90, 0)
	expect("A 50-point gap is refused at first (window 10)", #far.findMatches(0) == 0 and far.size("Pro") == 2)
	expect("...still refused just before the window reaches 50 (19.9 s)", #far.findMatches(19.9) == 0)
	expect("...and accepted once the oldest player's window covers the gap (20 s -> 50)", #far.findMatches(20) == 1)
	local leagues = Matchmaker.new()
	leagues.enqueue("r1", "Rookie", 60, 0)
	leagues.enqueue("p1", "Pro", 60, 0)
	expect("Leagues never mix, even with identical OVR", #leagues.findMatches(100) == 0)
	local best = Matchmaker.new()
	best.enqueue("old", "Pro", 70, 0)
	best.enqueue("far", "Pro", 79, 1)
	best.enqueue("near", "Pro", 71, 2)
	local pb = best.findMatches(3)
	expect("The oldest player is paired with the CLOSEST OVR, not the next arrival", #pb == 1 and pb[1].B.PlayerId == "near" and best.isQueued("far"))
	local four = Matchmaker.new()
	for i, ovr in { 50, 90, 52, 88 } do
		four.enqueue("p" .. i, "Pro", ovr, i)
	end
	local fp = four.findMatches(5)
	local sums: { string } = {}
	for _, pair in fp do
		table.insert(sums, math.min(pair.A.Ovr, pair.B.Ovr) .. "-" .. math.max(pair.A.Ovr, pair.B.Ovr))
	end
	table.sort(sums)
	expect("Four players pair into the two closest couples (50+52, 88+90)", #fp == 2 and sums[1] == "50-52" and sums[2] == "88-90")
	local gone = Matchmaker.new()
	gone.enqueue("q", "Pro", 60, 0)
	local removed = gone.dequeue("q")
	expect("dequeue removes and returns the entry; unknown ids return nil", removed ~= nil and (removed :: Matchmaker.Entry).PlayerId == "q" and not gone.isQueued("q") and gone.dequeue("q") == nil)
	local uniq = true
	local crowd = Matchmaker.new()
	for i = 1, 40 do
		crowd.enqueue("c" .. i, if i % 2 == 0 then "Pro" else "Amateur", 50 + i % 7, i * 0.1)
	end
	local seenIds: { [string]: boolean } = {}
	for _, pair in crowd.findMatches(60) do
		for _, e in { pair.A, pair.B } do
			if seenIds[e.PlayerId] then
				uniq = false
			end
			seenIds[e.PlayerId] = true
		end
		if pair.A.PlayerId == pair.B.PlayerId or pair.A.League ~= pair.B.League then
			uniq = false
		end
	end
	expect("Crowd: no player in two pairs, nobody paired with self or across leagues", uniq)
end

-- Settlement ----------------------------------------------------------------------
print("-- settlement")
do
	local function resultFor(winner: string?, draw: boolean): MatchEngine.MatchResult
		return { Finished = true, WinnerId = winner, Draw = draw, Reason = "complete", Totals = {}, HoleScores = {}, ForfeitedIds = {} }
	end
	local noPlay: MatchSettlement.PlayStats = { HolesPlayed = 3, HolesInOne = 0, LongestDriveYds = 0 }
	local zeroSum = true
	for _, league in Config.Leagues do
		local outcomes = MatchSettlement.settle(resultFor("A", false), "Ranked", league, { "A", "B" })
		local a, b = outcomes.A, outcomes.B
		expect(`{league.Id}: winner paid WinPayout, loser nothing`, a.Won and a.Winnings == league.WinPayout and not b.Won and b.Lost and b.Winnings == 0 and b.Refund == 0)
		local netMint = (a.Winnings + b.Winnings) - 2 * league.EntryFee
		if league.Id ~= "Champion" and netMint ~= 0 then
			zeroSum = false
		end
		if league.Id == "Champion" then
			expect("Champion league mints exactly 5,000 coins per decisive match", netMint == 5000)
		end
	end
	expect("Rookie / Amateur / Pro matches are exactly zero-sum", zeroSum)
	local pro = Config.Leagues[3]
	local draw = MatchSettlement.settle(resultFor(nil, true), "Ranked", pro, { "A", "B" })
	expect("Draw: both players refunded their entry fee, nobody wins or loses", draw.A.Refund == pro.EntryFee and draw.B.Refund == pro.EntryFee and draw.A.Winnings == 0 and not draw.A.Won and not draw.A.Lost and draw.A.Drew)
	local abandoned = MatchSettlement.settle(resultFor(nil, false), "Ranked", pro, { "A" })
	expect("Abandoned match pays and refunds nothing", abandoned.A.Winnings == 0 and abandoned.A.Refund == 0 and not abandoned.A.Won)
	local bot = MatchSettlement.settle(resultFor("A", false), "Bot", nil, { "A" })
	expect("Bot practice never pays coins, even for a win", bot.A.Won and bot.A.Winnings == 0 and bot.A.Refund == 0 and not bot.A.Ranked)

	local d = ProfileTemplate.new(0)
	d.Coins = 0
	local winOutcome = MatchSettlement.settle(resultFor("A", false), "Ranked", pro, { "A", "B" }).A
	local credited = MatchSettlement.applyToProfile(d, winOutcome, { HolesPlayed = 3, HolesInOne = 1, LongestDriveYds = 301.7 })
	expect("applyToProfile: payout, ranked win, holes, hole-in-one, longest drive", credited == pro.WinPayout and d.Coins == pro.WinPayout and d.Stats.Wins == 1 and d.Stats.MatchesPlayed == 1 and d.Stats.HolesPlayed == 3 and d.Stats.HolesInOne == 1 and d.Stats.LongestDriveYds == 301 and d.Stats.TotalCoinsEarned == pro.WinPayout)
	local d2 = ProfileTemplate.new(0)
	MatchSettlement.applyToProfile(d2, MatchSettlement.settle(resultFor(nil, true), "Ranked", pro, { "A", "B" }).A, noPlay)
	expect("A refund is not counted as earnings (TotalCoinsEarned stays 0)", d2.Coins == Config.Economy.StartingCoins + pro.EntryFee and d2.Stats.TotalCoinsEarned == 0 and d2.Stats.Wins == 0 and d2.Stats.Losses == 0)
	local d3 = ProfileTemplate.new(0)
	MatchSettlement.applyToProfile(d3, MatchSettlement.settle(resultFor("B", false), "Ranked", pro, { "A", "B" }).A, noPlay)
	expect("Ranked loss recorded, no coins", d3.Stats.Losses == 1 and d3.Coins == Config.Economy.StartingCoins)
	local d4 = ProfileTemplate.new(0)
	d4.Stats.LongestDriveYds = 320
	MatchSettlement.applyToProfile(d4, MatchSettlement.settle(resultFor("A", false), "Bot", nil, { "A" }).A, { HolesPlayed = 3, HolesInOne = 0, LongestDriveYds = 250 })
	expect("Bot match counts as played but not as a ranked win; longest drive keeps the max", d4.Stats.MatchesPlayed == 1 and d4.Stats.Wins == 0 and d4.Stats.LongestDriveYds == 320)
	local refundable = ProfileTemplate.new(0)
	refundable.Coins = 50
	expect("ProfileOps.refund adds without earnings and rejects bad amounts", ProfileOps.refund(refundable, "Coins", 100) and refundable.Coins == 150 and refundable.Stats.TotalCoinsEarned == 0 and not ProfileOps.refund(refundable, "Coins", -5) and not ProfileOps.refund(refundable, "Coins", 0 / 0))
end

-- Match engine ----------------------------------------------------------------------
print("-- match engine")
do
	local mid: ClubDatabase.Stats = { Distance = 70, Accuracy = 70, Forgiveness = 70 }
	local function statsFor(_label: string): ClubDatabase.Stats
		return mid
	end
	local function twoHumans(): { MatchEngine.PlayerSpec }
		return {
			{ Id = "H1", Name = "One", IsBot = false, StatsFor = statsFor },
			{ Id = "H2", Name = "Two", IsBot = false, StatsFor = statsFor },
		}
	end
	local function twoBots(): { MatchEngine.PlayerSpec }
		return {
			{ Id = "B1", Name = "Bot1", IsBot = true, StatsFor = statsFor },
			{ Id = "B2", Name = "Bot2", IsBot = true, StatsFor = statsFor },
		}
	end
	local function eventsOfType(list: { MatchEngine.Event }, eventType: string): { MatchEngine.Event }
		local out: { MatchEngine.Event } = {}
		for _, e in list do
			if e.Type == eventType then
				table.insert(out, e)
			end
		end
		return out
	end
	local function playerView(snapshot: any, id: string): any
		for _, v in snapshot.Players do
			if v.Id == id then
				return v
			end
		end
		return nil
	end

	-- Structure, validation, turn order -------------------------------------------
	local engine = MatchEngine.new({ Players = twoHumans(), Holes = CourseDatabase.sequence(1, 3), Seed = 42, Now = 0 })
	local snap = engine.snapshot(0)
	expect("New match: Swing phase on hole 1 of 3 with an active player", snap.Phase == "Swing" and snap.HoleIndex == 1 and snap.HoleCount == 3 and engine.activeId() ~= nil and #snap.Players == 2)
	expect("Snapshot: hole info, wind within the cap, full turn timer", snap.Hole.Par == 4 and math.abs(snap.Hole.Yards - 380) < 0.01 and snap.Wind.Mph >= 0 and snap.Wind.Mph <= Config.Match.MaxWindMph and snap.TurnSecondsLeft == Config.Match.TurnSeconds)
	expect("The turn timer counts down in snapshots", engine.snapshot(15).TurnSecondsLeft == Config.Match.TurnSeconds - 15)
	local first = engine.activeId() :: string
	local second = if first == "H1" then "H2" else "H1"
	local _, whyNotTurn = engine.submitSwing(second, 80, 0, 20)
	expect("Swinging out of turn is refused", whyNotTurn == "not_your_turn")
	local _, whyFast = engine.submitSwing(first, 100, 0, 0.3)
	expect("A full-power perfect swing 0.3 s after the turn opened is rejected as too_fast", whyFast == "too_fast")
	local _, whyBad = engine.submitSwing(first, 0 / 0, 0, 20)
	local _, whyUnknown = engine.submitSwing("nobody", 50, 0, 20)
	expect("NaN power and unknown players are rejected", whyBad == "bad_power" and whyUnknown == "unknown_player")
	expect("Rejected swings change nothing (same active player, no Shot event)", engine.activeId() == first and #eventsOfType(engine.drainEvents(), "Shot") == 0)

	local okShot = engine.submitSwing(first, 100, 0, 20)
	local shotEvents = eventsOfType(engine.drainEvents(), "Shot")
	expect("A valid swing resolves into one Shot event and starts the flight pause", okShot and #shotEvents == 1 and engine.phase() == "Flight" and shotEvents[1].Data.PlayerId == first and shotEvents[1].Data.Stroke == 1)
	local shot = shotEvents[1].Data
	expect("Shot event: telemetry plus a time-ordered trajectory in the hole frame", shot.Telemetry.CarryYds > 200 and shot.Telemetry.ApexFeet > 50 and #shot.Samples > 10 and shot.Samples[1][1] == 0 and shot.Samples[#shot.Samples][1] >= shot.Samples[1][1])
	local _, whyFlight = engine.submitSwing(second, 80, 0, 25)
	expect("Nobody can swing during the flight pause", whyFlight == "not_your_turn")
	engine.tick(5)
	expect("A tick before the pause ends keeps the Flight phase", engine.phase() == "Flight")
	engine.tick(40)
	expect("After the pause the other player (still on the tee, farthest away) plays next", engine.phase() == "Swing" and engine.activeId() == second)
	engine.submitSwing(second, 70, 0, 80)
	engine.tick(120)
	expect("Away-plays-first: the ball farther from the pin shoots next", (function()
		local view = engine.snapshot(120)
		local a, b = view.Players[1], view.Players[2]
		local farther = if a.YardsToPin > b.YardsToPin then a.Id else b.Id
		return engine.activeId() == farther
	end)())

	-- Water / out-of-bounds penalties ----------------------------------------------
	local pondEngine = MatchEngine.new({ Players = twoHumans(), Holes = { CourseDatabase.hole(2) }, Seed = 7, Now = 0 })
	local shooter = pondEngine.activeId() :: string
	pondEngine.setClub(shooter, "LW")
	local beforeSwing = playerView(pondEngine.snapshot(0), shooter)
	pondEngine.submitSwing(shooter, 100, 0, 30)
	local pondShot = eventsOfType(pondEngine.drainEvents(), "Shot")[1].Data
	expect("Par 3 pond: a short club ends in the water, penalty applied (2 strokes), not holed", pondShot.Outcome == "Water" and pondShot.Penalty and pondShot.Stroke == 2 and not pondShot.Holed)
	local afterSwing = playerView(pondEngine.snapshot(30), shooter)
	expect("Water: the ball is replayed from the same spot with the same lie", beforeSwing.Position.X == afterSwing.Position.X and beforeSwing.Position.Z == afterSwing.Position.Z and afterSwing.Lie == "Tee")

	local obEngine = MatchEngine.new({ Players = twoHumans(), Holes = { CourseDatabase.hole(1) }, Seed = 8, Now = 0 })
	local obShooter = obEngine.activeId() :: string
	obEngine.setClub(obShooter, "D")
	local aimOk = obEngine.setAim(obShooter, -Config.Match.MaxAimDegrees)
	local aimBad = obEngine.setAim(obShooter, 200)
	obEngine.submitSwing(obShooter, 100, 0, 30)
	local obShot = eventsOfType(obEngine.drainEvents(), "Shot")[1].Data
	expect("Aim: the extreme allowed value is accepted, out-of-range refused", aimOk and not aimBad)
	expect("Out of bounds (driver aimed 30deg left): penalty stroke, replay", obShot.Penalty and obShot.Stroke == 2 and obShot.Outcome == "Rest")
	local _, whyClub = obEngine.setClub(obShooter, "12i")
	expect("Unknown club slots are refused", whyClub == "unknown_club_slot")

	-- Precise scenarios on custom putting greens -------------------------------------
	local function puttingHole(par: number, yards: number): CourseDatabase.HoleDef
		local m = yards * Config.Physics.YardsToMeters
		return {
			Id = 90, Name = "Putting green", Par = par, Tee = { X = 0, Z = 0 }, Pin = { X = m, Z = 0 },
			Fairway = {}, Greens = { { X = m, Z = 0, R = 60 } }, Bunkers = {}, Water = {},
			GreenSlope = { X = 0, Z = 0 }, Bounds = { MinX = -50, MaxX = 500, MinZ = -200, MaxZ = 200 },
		}
	end
	local function botDuel(hole: CourseDatabase.HoleDef, seed: number): MatchEngine.Engine
		return MatchEngine.new({ Players = twoBots(), Holes = { hole }, Seed = seed, Now = 0 })
	end
	local function scanPower(e: MatchEngine.Engine, id: string, wanted: (ShotPhysics.ShotResult) -> boolean): number?
		for tenth = 10, 1000 do
			local power = tenth / 10
			local preview = e.preview(id, "PT", 0, power, 0, 1)
			if preview and wanted(preview.Result) then
				return power
			end
		end
		return nil
	end
	local pinM = 6 * Config.Physics.YardsToMeters

	local aceEngine = botDuel(puttingHole(3, 6), 11)
	local aceId = aceEngine.activeId() :: string
	local acePower = scanPower(aceEngine, aceId, function(r: ShotPhysics.ShotResult): boolean
		return r.Outcome == "Holed"
	end)
	expect("Scan finds a putting power that holes out from 6 yards", acePower ~= nil)
	if acePower then
		aceEngine.submitBotSwing(aceId, "PT", 0, acePower, 0, 1)
		local ace = eventsOfType(aceEngine.drainEvents(), "Shot")[1].Data
		expect("Holing out in one flags a hole-in-one with 1 stroke", ace.Holed and ace.HoleInOne and ace.Stroke == 1 and ace.Outcome == "Holed" and not ace.PickedUp)
	end

	local gimmeEngine = botDuel(puttingHole(3, 6), 12)
	local gimmeId = gimmeEngine.activeId() :: string
	local gimmePower = scanPower(gimmeEngine, gimmeId, function(r: ShotPhysics.ShotResult): boolean
		local short = pinM - r.FinalX
		return r.Outcome == "Rest" and short > 0.1 and short < Config.Match.GimmeMeters - 0.05
	end)
	expect("Scan finds a putt that stops within gimme range without dropping", gimmePower ~= nil)
	if gimmePower then
		gimmeEngine.submitBotSwing(gimmeId, "PT", 0, gimmePower, 0, 1)
		local g = eventsOfType(gimmeEngine.drainEvents(), "Shot")[1].Data
		expect("A ball resting inside the gimme radius is holed; the tap-in costs a stroke (2 total)", g.Holed and g.Stroke == 2 and not g.HoleInOne and g.Outcome == "Rest")
	end
	local missEngine = botDuel(puttingHole(3, 6), 13)
	local missId = missEngine.activeId() :: string
	local missPower = scanPower(missEngine, missId, function(r: ShotPhysics.ShotResult): boolean
		local short = pinM - r.FinalX
		return r.Outcome == "Rest" and short > 3 and short < 4
	end)
	expect("Scan finds a putt that stops 3-4 m short", missPower ~= nil)
	if missPower then
		missEngine.submitBotSwing(missId, "PT", 0, missPower, 0, 1)
		local m = eventsOfType(missEngine.drainEvents(), "Shot")[1].Data
		expect("A putt stopping 3+ metres away is not a gimme (play continues)", not m.Holed and m.Stroke == 1)
	end

	-- Pick-up at par + MaxStrokesOverPar; a tie is a draw.
	local pickup = botDuel(puttingHole(3, 30), 14)
	local safety, pickedUps, simNow = 0, 0, 0.0
	while not pickup.isFinished() and safety < 200 do
		safety += 1
		simNow += 30
		pickup.tick(simNow)
		local id = pickup.activeId()
		if id and pickup.phase() == "Swing" then
			pickup.submitBotSwing(id, "PT", 0, 1, 0, simNow) -- the smallest possible putt, forever
		end
		for _, e in pickup.drainEvents() do
			if e.Type == "Shot" and e.Data.PickedUp then
				pickedUps += 1
			end
		end
	end
	local pickResult = pickup.result()
	expect("Pick-up: endless 1% putts end each player's hole at par + 4 = 7", pickup.isFinished() and pickedUps == 2 and pickResult.Totals.B1 == 7 and pickResult.Totals.B2 == 7)
	expect("Equal totals draw (no winner)", pickResult.Draw and pickResult.WinnerId == nil and pickResult.Reason == "complete")

	-- Timeouts ---------------------------------------------------------------------
	local toEngine = MatchEngine.new({ Players = twoHumans(), Holes = CourseDatabase.sequence(1, 3), Seed = 5, Now = 0 })
	local victim = toEngine.activeId() :: string
	toEngine.tick(Config.Match.TurnSeconds - 0.1)
	expect("No timeout before the deadline", #eventsOfType(toEngine.drainEvents(), "Timeout") == 0 and toEngine.activeId() == victim)
	toEngine.tick(Config.Match.TurnSeconds + 0.1)
	local toEvents = toEngine.drainEvents()
	local timeoutEv = eventsOfType(toEvents, "Timeout")
	local autoShot = eventsOfType(toEvents, "Shot")
	expect("Timeout: counted, and an automatic poor shot is played for that player", #timeoutEv == 1 and timeoutEv[1].Data.Count == 1 and #autoShot == 1 and autoShot[1].Data.Auto and autoShot[1].Data.PlayerId == victim)
	expect("The automatic shot is a visible slice, not a straight ball", math.abs(autoShot[1].Data.Telemetry.LateralYds) > 3)
	-- Let only the victim's turns expire (the other player keeps swinging) until they forfeit.
	local clock = Config.Match.TurnSeconds + 0.1
	local timeoutsOfVictim = 1
	for _ = 1, 400 do
		if toEngine.isFinished() then
			break
		end
		clock += 5
		toEngine.tick(clock)
		local active = toEngine.activeId()
		if active and active ~= victim and toEngine.phase() == "Swing" then
			toEngine.submitSwing(active, 60, 0, clock + 30) -- promptly swings (validated against its own timeline)
		end
		for _, e in toEngine.drainEvents() do
			if e.Type == "Timeout" and e.Data.PlayerId == victim then
				timeoutsOfVictim += 1
			end
		end
	end
	local toResult = toEngine.result()
	expect("MaxTimeouts (3) timeouts forfeit the match; the opponent wins", toEngine.isFinished() and toResult.ForfeitedIds[1] == victim and toResult.Reason == "forfeit" and toResult.WinnerId ~= victim and timeoutsOfVictim >= Config.Match.MaxTimeouts - 1)

	-- Forfeit ----------------------------------------------------------------------------
	local ff = MatchEngine.new({ Players = twoHumans(), Holes = CourseDatabase.sequence(1, 3), Seed = 6, Now = 0 })
	ff.forfeit("H1", 10)
	local ffResult = ff.result()
	expect("Forfeit ends the match at once; the other player wins", ff.isFinished() and ffResult.WinnerId == "H2" and ffResult.Reason == "forfeit" and ffResult.ForfeitedIds[1] == "H1" and ff.phase() == "Finished" and ff.activeId() == nil)
	local ffEvents = ff.drainEvents()
	expect("Forfeit emits Forfeit and MatchComplete events", #eventsOfType(ffEvents, "Forfeit") == 1 and #eventsOfType(ffEvents, "MatchComplete") == 1)
	local _, whyAfter = ff.submitSwing("H2", 50, 0, 100)
	expect("No swings after the match is over", whyAfter == "not_your_turn")
	ff.forfeit("H2", 11)
	expect("Forfeiting again after the end is ignored", #ff.result().ForfeitedIds == 1 and ff.result().WinnerId == "H2")

	local humanEngine = MatchEngine.new({ Players = twoHumans(), Holes = CourseDatabase.sequence(1, 1), Seed = 9, Now = 0 })
	local _, whyHuman = humanEngine.submitBotSwing(humanEngine.activeId() :: string, "D", 0, 50, 0, 1)
	expect("submitBotSwing refuses human players (no way to bypass the timing check)", whyHuman == "not_a_bot")

	-- Honour: the lower score tees off first on the next hole ----------------------------------
	local honourOk, honourChecked = true, 0
	for seed = 1, 12 do
		local e = MatchEngine.new({ Players = twoBots(), Holes = CourseDatabase.sequence(1, 2), Seed = seed, Now = 0 })
		local rngH = Prng.new(seed + 100)
		local tH = 0.0
		for _ = 1, 600 do
			tH += 5
			e.tick(tH)
			local id = e.activeId()
			if id and e.phase() == "Swing" then
				BotBrain.play(e, id, if id == "B1" then "Hard" else "Easy", rngH.next, tH)
			end
			local events = e.drainEvents()
			local completeAt = 0
			for i, ev in events do
				if ev.Type == "HoleComplete" and ev.Data.HoleIndex == 1 then
					completeAt = i
				end
			end
			if completeAt > 0 then
				local view = e.snapshot(tH)
				local s1, s2 = playerView(view, "B1").HoleScores[1], playerView(view, "B2").HoleScores[1]
				local nextTurn: string? = nil
				for i = completeAt, #events do
					if events[i].Type == "TurnStart" and nextTurn == nil then
						nextTurn = events[i].Data.PlayerId
					end
				end
				if s1 ~= s2 then
					honourChecked += 1
					local expected = if s1 < s2 then "B1" else "B2"
					if nextTurn ~= expected then
						honourOk = false
					end
				end
				break
			end
		end
	end
	expect(`Honour: the player with the lower score on a hole tees off first on the next ({honourChecked} matches checked)`, honourOk and honourChecked >= 6)

	-- Bot matches ---------------------------------------------------------------------------------
	local function playBotMatch(seed: number, levelA: string, levelB: string, holes: { CourseDatabase.HoleDef }): (MatchEngine.MatchResult, number, number)
		local rngB = Prng.new(seed + 999)
		local specs: { MatchEngine.PlayerSpec } = {
			{ Id = "A", Name = "A", IsBot = true, StatsFor = BotBrain.statsFor(levelA) },
			{ Id = "B", Name = "B", IsBot = true, StatsFor = BotBrain.statsFor(levelB) },
		}
		local match = MatchEngine.new({ Players = specs, Holes = holes, Seed = seed, Now = 0 })
		local levels: { [string]: string } = { A = levelA, B = levelB }
		local now2, steps, penalties, refused = 0.0, 0, 0, 0
		while not match.isFinished() and steps < 3000 do
			steps += 1
			now2 += 0.5
			match.tick(now2)
			local id = match.activeId()
			if id and match.phase() == "Swing" then
				if BotBrain.play(match, id, levels[id], rngB.next, now2) == nil then
					refused += 1
				end
			end
			for _, e in match.drainEvents() do
				if e.Type == "Shot" and e.Data.Penalty then
					penalties += 1
				end
			end
		end
		return match.result(), penalties, refused
	end

	local function ladder(levelA: string, levelB: string, n: number): (number, number, number, boolean)
		local winsA, winsB, draws, clean = 0, 0, 0, true
		for i = 1, n do
			local r, _, refused = playBotMatch(i * 13, levelA, levelB, CourseDatabase.sequence(i, 3))
			if not r.Finished or refused > 0 then
				clean = false
			end
			if r.Draw then
				draws += 1
			elseif r.WinnerId == "A" then
				winsA += 1
			else
				winsB += 1
			end
		end
		return winsA, winsB, draws, clean
	end
	local hardEasyA, hardEasyB, _, clean1 = ladder("Hard", "Easy", 24)
	local hardMedA, hardMedB, _, clean2 = ladder("Hard", "Medium", 24)
	local medEasyA, medEasyB, _, clean3 = ladder("Medium", "Easy", 24)
	print(`  skill ladder (24 matches each): Hard-Easy {hardEasyA}-{hardEasyB}, Hard-Medium {hardMedA}-{hardMedB}, Medium-Easy {medEasyA}-{medEasyB}`)
	expect("Every bot match finishes and no bot action is ever refused by the engine", clean1 and clean2 and clean3)
	expect("Skill ladder: Hard beats Easy (>= 20 of 24)", hardEasyA >= 20 and hardEasyB <= 2)
	expect("Skill ladder: Hard beats Medium (>= 14 wins, <= 3 losses)", hardMedA >= 14 and hardMedB <= 3)
	expect("Skill ladder: Medium beats Easy (>= 15 wins, <= 4 losses)", medEasyA >= 15 and medEasyB <= 4)

	-- Hazards: Hard bots read the pond hole and rarely go in the water.
	local waterBalls, pondHoles = 0, 0
	for i = 1, 40 do
		local _, penalties = playBotMatch(i * 5, "Hard", "Hard", { CourseDatabase.hole(2) })
		waterBalls += penalties
		pondHoles += 2
	end
	expect(`Hard bots avoid the pond ({waterBalls} penalties in {pondHoles} player-holes, limit 4)`, waterBalls <= 4)

	-- Determinism: same seeds -> same match.
	local r1 = playBotMatch(77, "Medium", "Hard", CourseDatabase.sequence(2, 3))
	local r2 = playBotMatch(77, "Medium", "Hard", CourseDatabase.sequence(2, 3))
	expect("A bot match replays identically from the same seeds", r1.Totals.A == r2.Totals.A and r1.Totals.B == r2.Totals.B and r1.WinnerId == r2.WinnerId)

	-- Bot planning must not change the match.
	local probe = MatchEngine.new({ Players = twoBots(), Holes = CourseDatabase.sequence(1, 3), Seed = 21, Now = 0 })
	local probeId = probe.activeId() :: string
	local beforeProbe = probe.snapshot(0)
	for _ = 1, 3 do
		BotBrain.decide({
			situation = function(): MatchEngine.Situation
				return probe.situation(probeId) :: MatchEngine.Situation
			end,
			preview = function(label: string, aim: number, power: number, offset: number, windScale: number): SwingMath.ResolvedShot?
				return probe.preview(probeId, label, aim, power, offset, windScale)
			end,
			landing = function(aim: number, result: ShotPhysics.ShotResult): (Types.LieId, boolean)
				return probe.landing(probeId, aim, result)
			end,
			statsFor = BotBrain.statsFor("Hard"),
		}, "Hard", Prng.new(1).next)
	end
	local afterProbe = probe.snapshot(0)
	local function same(a: any, b: any): boolean
		if type(a) ~= type(b) then
			return false
		end
		if type(a) ~= "table" then
			return a == b
		end
		for k, v in a do
			if not same(v, b[k]) then
				return false
			end
		end
		for k in b do
			if a[k] == nil then
				return false
			end
		end
		return true
	end
	expect("Bot planning (dozens of previews) leaves the match state untouched", same(beforeProbe, afterProbe) and #probe.drainEvents() > 0 and probe.activeId() == probeId)
end

for _, caseId in CaseDatabase.Order do
	print(`case {caseId}: expected sell value {CaseDatabase.expectedSellValue(caseId)} vs price {CaseDatabase.Cases[caseId].Price.Amount}`)
end

if failures > 0 then
	error(`{failures} check(s) failed`)
end
print("ALL CHECKS PASSED")
