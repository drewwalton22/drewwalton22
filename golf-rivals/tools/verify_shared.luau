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
local Format = require("./Format")
local Signal = require("./Signal")
local ClubAdvisor = require("./ClubAdvisor")
local TelemetryView = require("./TelemetryView")
local CameraMath = require("./CameraMath")
local CourseLayout = require("./CourseLayout")
local GaugeView = require("./GaugeView")
local MiniMap = require("./MiniMap")
local MatchView = require("./MatchView")
local QuestDatabase = require("./QuestDatabase")
local QuestEngine = require("./QuestEngine")
local ShopView = require("./ShopView")
local LoadoutView = require("./LoadoutView")
local CasesView = require("./CasesView")
local TradeUpView = require("./TradeUpView")
local ModeView = require("./ModeView")
local LobbyLayout = require("./LobbyLayout")
local ClubStats = require("./ClubStats")
local Assets = require("./Assets")
local AimGuide = require("./AimGuide")
local RangeRules = require("./RangeRules")
local ZoneRewards = require("./ZoneRewards")
local SwingPose = require("./SwingPose")
local PodiumView = require("./PodiumView")
local SurfaceMaterials = require("./SurfaceMaterials")
local TerrainPlan = require("./TerrainPlan")
local DecorPlanner = require("./DecorPlanner")
local AimMath = require("./AimMath")
local WheelRules = require("./WheelRules")
local CosmeticsData = require("./CosmeticsData")
local CourseData = require("./CourseData")
local CourseRelief = require("./CourseRelief")
local ClubSeat = require("./ClubSeat")

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
expect("OVR 92/78/85 -> 86 (driver card)", ClubDatabase.overall({ Power = 92, Accuracy = 78, Spin = 85 }) == 86)
local shadow = ClubDatabase.get("tatermade_shadow_dr")
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


-- Swing state machine (2-stage timing bar) ---------------------------------
print("-- swing state machine")
local PS, AS = Config.Swing.PowerSweepSeconds, Config.Swing.AccuracySweepSeconds
local function swing(c1: number, c2: number?, mode: SwingStateMachine.Mode?): SwingStateMachine.SwingResult?
	local sm = SwingStateMachine.new()
	sm.start(0, mode)
	sm.click(c1)
	if c2 then
		sm.click(c2)
	end
	return sm.result()
end
do
	expect("Timing is slower than the old 3-click gauge (power sweep >= 1.5 s, accuracy >= 1.2 s)", PS >= 1.5 and AS >= 1.2)
	expect("Putting bar is slower still", Config.Swing.PuttPowerSweepSeconds > PS and Config.Swing.PuttAccuracySweepSeconds > AS)
	-- Click 1 at half the power sweep = 50%; click 2 half-way across the track = sweet spot.
	local r = swing(PS * 0.5, PS * 0.5 + AS * 0.5)
	expect("Perfect 50% swing: power 50, offset 0 (sweet spot)", r ~= nil and math.abs(r.Power - 50) < 1e-9 and math.abs(r.AccuracyOffset) < 1e-9)
	local early = swing(PS * 0.5, PS * 0.5 + AS * 0.25)
	expect("Early click 2 -> negative offset (-0.5, slice)", early ~= nil and math.abs(early.AccuracyOffset + 0.5) < 1e-9)
	local late = swing(PS * 0.5, PS * 0.5 + AS * 0.75)
	expect("Late click 2 -> positive offset (+0.5, hook)", late ~= nil and math.abs(late.AccuracyOffset - 0.5) < 1e-9)
	local instant = swing(PS * 0.5, PS * 0.5)
	expect("Clicking straight after click 1 clamps at -1", instant ~= nil and instant.AccuracyOffset == -1)

	local sm = SwingStateMachine.new()
	expect("Starts Idle, no result", sm.phase() == "Idle" and sm.result() == nil)
	sm.start(10)
	expect("start() arms the power stage", sm.phase() == "Power")
	expect("Power rises linearly to 100% ...", math.abs(sm.gauge(10 + PS * 0.25).Power - 0.25) < 1e-9 and math.abs(sm.gauge(10 + PS).Power - 1) < 1e-9)
	expect("... then sweeps back down (no auto-lock in stage 1)", math.abs(sm.gauge(10 + PS * 1.5).Power - 0.5) < 1e-9 and sm.phase() == "Power" and math.abs(sm.gauge(10 + PS * 2).Power) < 1e-9)
	sm.click(10 + PS * 1.25) -- on the way down: 75%
	expect("Click 1 locks the power where the marker is (75% on the way down)", sm.phase() == "Accuracy" and math.abs((sm.gauge(10 + PS * 1.25).LockedPower :: number) - 0.75) < 1e-9)
	local t1 = 10 + PS * 1.25
	expect("The needle starts at the left edge and crosses at 2/AccuracySweep per second", math.abs(sm.gauge(t1).Needle + 1) < 1e-9 and math.abs(sm.gauge(t1 + AS * 0.5).Needle) < 1e-9)
	sm.click(t1 + AS * 0.5)
	expect("Click 2 -> Done; extra clicks ignored", sm.phase() == "Done" and (function()
		sm.click(t1 + 5)
		local res = sm.result()
		return res ~= nil and math.abs(res.Power - 75) < 1e-9 and math.abs(res.AccuracyOffset) < 1e-9
	end)())
	sm.reset()
	expect("reset() returns to Idle", sm.phase() == "Idle")

	-- Stage 2 swings back and forth (ping-pong) until click 2.
	local pong = SwingStateMachine.new()
	pong.start(0)
	pong.click(PS)
	expect("The accuracy needle ping-pongs: right edge after one sweep, back through the sweet spot after 1.5",
		math.abs(pong.gauge(PS + AS).Needle - 1) < 1e-9 and math.abs(pong.gauge(PS + AS * 1.25).Needle - 0.5) < 1e-9
			and math.abs(pong.gauge(PS + AS * 1.5).Needle) < 1e-9 and math.abs(pong.gauge(PS + AS * 2).Needle + 1) < 1e-9)
	pong.click(PS + AS * 1.5)
	local pongResult = pong.result()
	expect("Clicking the sweet spot on the way back is a perfect strike", pongResult ~= nil and math.abs(pongResult.AccuracyOffset) < 1e-9 and not pongResult.TimedOut)

	-- 5-second timeout with a random penalty.
	local TO = Config.Swing.AccuracyTimeoutSeconds
	expect("Stage 2 times out after 5 seconds", TO == 5)
	local stall = SwingStateMachine.new(Prng.new(3).next)
	stall.start(0)
	stall.click(PS)
	stall.update(PS + TO - 0.01)
	local countdown = stall.gauge(PS + 1).TimeLeft
	expect("No timeout before 5 s; the gauge counts down the time left", stall.phase() == "Accuracy" and countdown ~= nil and math.abs((countdown :: number) - (TO - 1)) < 1e-9)
	stall.update(PS + TO)
	local sr = stall.result()
	expect("No click 2 within 5 s: the shot fires with a random accuracy penalty",
		sr ~= nil and sr.TimedOut and sr.Power == 100 and math.abs(sr.AccuracyOffset) >= Config.Swing.TimeoutPenaltyMin - 1e-9 and math.abs(sr.AccuracyOffset) <= Config.Swing.TimeoutPenaltyMax + 1e-9)
	local polled = SwingStateMachine.new(Prng.new(3).next)
	polled.start(0)
	polled.click(PS)
	for step = 1, 80 do
		polled.update(PS + step * 0.1)
	end
	local pr = polled.result()
	expect("The timeout is independent of polling frequency", pr ~= nil and sr ~= nil and pr.AccuracyOffset == sr.AccuracyOffset)
	local hooks, slices = 0, 0
	local penaltyRng = Prng.new(99).next
	for _ = 1, 200 do
		local off = SwingStateMachine.timeoutOffset(penaltyRng)
		if off > 0 then
			hooks += 1
		else
			slices += 1
		end
	end
	expect("Timeout penalties are randomly hooks or slices", hooks > 60 and slices > 60)
	local fast = SwingStateMachine.new()
	fast.start(0, "Full", 2)
	expect("start() takes a speed scale (2 = twice as fast)", math.abs(fast.gauge(PS * 0.25).Power - 0.5) < 1e-9)

	local putt = SwingStateMachine.new()
	putt.start(0, "Putt")
	expect("Putt mode uses the slower putting sweep", math.abs(putt.gauge(Config.Swing.PuttPowerSweepSeconds * 0.5).Power - 0.5) < 1e-9 and putt.gauge(0).Mode == "Putt")
end

-- Submission plausibility (anti-cheat) --------------------------------------
print("-- submission validation")
do
	local ok1 = SwingMath.validateSubmission(100, 0, 10)
	expect("Normal swing accepted", ok1)
	local ok2, why2 = SwingMath.validateSubmission(100, 0, 0.5)
	expect("Full-power perfect swing in 0.5s rejected as too_fast", not ok2 and why2 == "too_fast")
	local okEarly = SwingMath.validateSubmission(100, -1, PS)
	expect("A clamped -1 needs no accuracy time", okEarly)
	local fastPutt = SwingMath.validateSubmission(100, 0, PS + AS * 0.5, true)
	expect("Putts are timed against the slower putting bar", not fastPutt and SwingMath.validateSubmission(100, 0, PS + AS * 0.5, false))
	local _, whyNaN = SwingMath.validateSubmission(0 / 0, 0, 10)
	local _, whyRange = SwingMath.validateSubmission(150, 0, 10)
	local _, whyOffset = SwingMath.validateSubmission(50, 2, 10)
	local _, whyLow = SwingMath.validateSubmission(0, 0, 10)
	local _, whyType = SwingMath.validateSubmission("100", 0, 10)
	expect("Rejects NaN / out-of-range / wrong type / whiff", whyNaN == "bad_power" and whyRange == "bad_power" and whyOffset == "bad_offset" and whyLow == "power_too_low" and whyType == "bad_power")
	-- Every result a human can really produce (from the moment the bar arms) validates.
	local allValid = true
	for _, mode in { "Full", "Putt" } :: { SwingStateMachine.Mode } do
		local ps, as = SwingStateMachine.speeds(mode)
		for _, c1 in { 0.05, ps * 0.3, ps, ps * 1.7, ps * 3.2 } do
			for _, gap in { 0, as * 0.1, as * 0.5, as * 0.9, as * 2 } do
				local sm = SwingStateMachine.new()
				sm.start(0, mode)
				sm.click(c1)
				sm.click(c1 + gap)
				sm.update(c1 + gap)
				local r = sm.result()
				if r and r.Power >= Config.Swing.MinPower then
					if not SwingMath.validateSubmission(r.Power, r.AccuracyOffset, c1 + gap, mode == "Putt") then
						allValid = false
					end
				end
			end
		end
	end
	expect("Genuine swings from the state machine always pass validation", allValid)
end

-- Shot physics ----------------------------------------------------------------
print("-- shot physics")
do
	local baseStats = { Power = 50, Accuracy = 60, Spin = 60 }
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
	local mock = shot("DR", { Power = 92, Accuracy = 78, Spin = 85 }, 100, 0).Result
	print(`  mockup driver: carry {mock.CarryYds} total {mock.TotalYds} roll {mock.RollYds} apex {mock.ApexFeet}ft spin {mock.SpinRpm}`)
	expect("Mockup driver carry within 270-285 yds (mockup: 278)", mock.CarryYds > 270 and mock.CarryYds < 285)
	expect("Mockup driver total within 300-325 (mockup: 312) and roll positive", mock.TotalYds > 300 and mock.TotalYds < 325 and mock.RollYds > 0)
	expect("Mockup driver apex within 95-125 ft (mockup: 112)", mock.ApexFeet > 95 and mock.ApexFeet < 125)
	expect("Telemetry: spin 2450 rpm, carry + roll = total", math.abs(mock.SpinRpm - 2450) < 1 and math.abs(mock.CarryYds + mock.RollYds - mock.TotalYds) < 1e-6)

	-- Power is ~linear in distance.
	local linear = true
	for _, label in { "DR", "FW", "LI", "SI", "WG" } do
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
	local lowP = shot("DR", baseStats, 25, 0).Result.CarryYds
	local highP = shot("DR", baseStats, 75, 0).Result.CarryYds
	expect("More power -> strictly more carry", lowP < highP and highP < shot("DR", baseStats, 100, 0).Result.CarryYds)

	-- Distance stat.
	local weak = shot("DR", { Power = 50, Accuracy = 60, Spin = 60 }, 100, 0).Result.CarryYds
	local strong = shot("DR", { Power = 90, Accuracy = 60, Spin = 60 }, 100, 0).Result.CarryYds
	expect("Higher Distance stat -> more carry", strong > weak + 15)

	-- Curve direction & monotonic severity.
	local straight = shot("DR", baseStats, 100, 0).Result
	local slice = shot("DR", baseStats, 100, -0.6).Result
	local hook = shot("DR", baseStats, 100, 0.6).Result
	expect("Perfect timing flies dead straight (|lateral| < 0.01 yd)", math.abs(straight.LateralYds) < 0.01)
	expect("Early click (offset<0) slices RIGHT (lateral > 0)", slice.LateralYds > 10)
	expect("Late click (offset>0) hooks LEFT (lateral < 0)", hook.LateralYds < -10)
	expect("Slice and hook are mirror images", math.abs(slice.LateralYds + hook.LateralYds) < 0.01)
	local m1, m2, m3 = shot("DR", baseStats, 100, -0.3).Result.LateralYds, slice.LateralYds, shot("DR", baseStats, 100, -1).Result.LateralYds
	expect("Bigger timing miss -> bigger curve", m1 < m2 and m2 < m3)
	local insideGreen = shot("DR", baseStats, 100, 0.05)
	expect("Inside the green zone: Perfect quality, no curve", insideGreen.Quality == "Perfect" and math.abs(insideGreen.Result.LateralYds) < 0.01)
	expect("Quality bands: Good at 0.2, Poor at 0.8", shot("DR", baseStats, 100, 0.2).Quality == "Good" and shot("DR", baseStats, 100, 0.8).Quality == "Poor")
	local lowAcc = shot("DR", { Power = 50, Accuracy = 20, Spin = 60 }, 100, -0.6).Result.LateralYds
	local highAcc = shot("DR", { Power = 50, Accuracy = 95, Spin = 60 }, 100, -0.6).Result.LateralYds
	expect("Higher Accuracy stat -> smaller curve for the same miss", highAcc < lowAcc * 0.8)

	-- Wind.
	local head = shot("DR", baseStats, 100, 0, nil, SwingMath.windToLocal(15, 180, 0)).Result
	local tail = shot("DR", baseStats, 100, 0, nil, SwingMath.windToLocal(15, 0, 0)).Result
	local cross = shot("DR", baseStats, 100, 0, nil, SwingMath.windToLocal(15, 90, 0)).Result
	expect("Headwind shortens, tailwind lengthens carry", head.CarryYds < straight.CarryYds - 10 and tail.CarryYds > straight.CarryYds + 10)
	expect("Wind from the left (blowing right) pushes the ball right", cross.LateralYds > 10)
	local windLocal = SwingMath.windToLocal(10, 90, 90)
	expect("windToLocal: wind along the aim is a pure tailwind", math.abs(windLocal.Z) < 1e-9 and windLocal.X > 4.4 and windLocal.X < 4.5)

	-- Lies.
	local lieCarry = {}
	for _, lie in { "Fairway", "Rough", "Sand" } do
		lieCarry[lie] = shot("SI", baseStats, 100, 0, lie :: Types.LieId).Result.CarryYds
	end
	expect("Lie penalty: Fairway > Rough > Sand carry", lieCarry.Fairway > lieCarry.Rough and lieCarry.Rough > lieCarry.Sand)
	local sandLowF = shot("SI", { Power = 50, Accuracy = 60, Spin = 10 }, 100, -0.5, "Sand").Result.LateralYds
	local sandHighF = shot("SI", { Power = 50, Accuracy = 60, Spin = 95 }, 100, -0.5, "Sand").Result.LateralYds
	expect("Spin softens the lie's accuracy penalty", sandHighF < sandLowF)

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
	local driverGreen, lwGreen = toGreen("DR"), toGreen("WG")
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
		Slot = ClubDatabase.getSlot("DR") :: ClubDatabase.BagSlot, Stats = baseStats, Power = 100, AccuracyOffset = 0, Lie = "Fairway",
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
	expect("Slow putt through the cup is holed (its final spot is the cup)", drop.Outcome == "Holed" and math.abs(drop.FinalX - cup.X) < 1e-9)
	local fast = putt(100, 0, nil, cup)
	expect("Same line at 100% power rolls past the cup (lip-out)", fast.Outcome == "Rest" and fast.FinalX > cup.X + 5)
	local offLine = putt(20, 0, nil, { X = cup.X, Z = 0.6 })
	expect("A putt passing 60 cm wide of the cup doesn't hole it", offLine.Outcome == "Rest")

	-- Determinism.
	local a = shot("DR", baseStats, 83, -0.37, "Rough", SwingMath.windToLocal(12, 140, 20)).Result
	local b = shot("DR", baseStats, 83, -0.37, "Rough", SwingMath.windToLocal(12, 140, 20)).Result
	expect("Identical inputs give bit-identical results (no RNG)", a.TotalYds == b.TotalYds and a.LateralYds == b.LateralYds and #a.Samples == #b.Samples)

	-- Apex heights for the telemetry overlay.
	print(`  apex heights (ft): DR {math.floor(straight.ApexFeet)} | SI {math.floor(shot("SI", baseStats, 100, 0).Result.ApexFeet)} | WG {math.floor(shot("WG", baseStats, 100, 0).Result.ApexFeet)}`)
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
	expect("New profile: all 6 bag slots hold an owned starter club", bagFull)
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
	dirty.EquippedItems["LongIron"] = "skin_crimson_driver" -- wrong slot
	dirty.EquippedClubs["DR"] = "ghost_club"
	dirty.OwnedClubs["ghost_club"] = true
	dirty.ClubUpgrades["tatermade_swift_dr"] = { Power = 99, Accuracy = -4, Spin = "x" }
	dirty.ClubUpgrades["pong_gale_dr"] = { Power = 3, Accuracy = 3, Spin = 3 } -- not owned
	dirty.Stats = nil
	local repaired = ProfileTemplate.prepare(dirty, 3000)
	expect("prepare() repairs a badly damaged profile instead of rejecting it", repaired ~= nil)
	if repaired then
		expect("Repair: negative/NaN balances become 0", repaired.Coins == 0 and repaired.Gems == 0)
		expect("Repair: removed items dropped, fractional counts floored, negatives dropped", repaired.OwnedItems["skin_that_was_removed"] == nil and repaired.OwnedItems["skin_crimson_driver"] == 2 and repaired.OwnedItems["skin_nebula_driver"] == nil)
		expect("Repair: unowned / wrong-slot equips reset to defaults", repaired.EquippedItems["Driver"] == "skin_midnight_driver" and repaired.EquippedItems["LongIron"] == "skin_midnight_longiron")
		expect("Repair: unknown clubs removed, bag refilled with starters", repaired.OwnedClubs["ghost_club"] == nil and repaired.EquippedClubs["DR"] == "tatermade_swift_dr")
		local lv = repaired.ClubUpgrades["tatermade_swift_dr"]
		expect("Repair: upgrade levels clamped to 0..Max, unowned club upgrades dropped", lv ~= nil and lv.Power == Config.Clubs.MaxUpgradeLevel and lv.Accuracy == 0 and lv.Spin == 0 and repaired.ClubUpgrades["pong_gale_dr"] == nil)
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
	local gale = "pong_gale_dr"
	expect("Can't equip an unowned club", select(2, ProfileOps.equipClub(d, gale)) == "not_owned")
	local _, whyBrokeClub = ProfileOps.buyClub(d, gale)
	expect("Can't buy a club you can't afford (nothing taken)", whyBrokeClub == "insufficient_funds" and d.Coins == coins0 and not d.OwnedClubs[gale])
	d.Coins = 20000
	expect("buyClub charges the price and grants the club", ProfileOps.buyClub(d, gale) and d.Coins == 20000 - 12000 and d.OwnedClubs[gale] == true)
	expect("Can't buy a club twice", select(2, ProfileOps.buyClub(d, gale)) == "already_owned")
	expect("Starter clubs aren't for sale", select(2, ProfileOps.buyClub(d, "tatermade_swift_fw")) == "already_owned")
	expect("equipClub fills the club's bag slot", ProfileOps.equipClub(d, gale) and d.EquippedClubs["DR"] == gale)

	-- Upgrades
	d.Coins = 100000
	local stats0 = ProfileOps.clubStats(d, gale) :: ClubDatabase.Stats
	expect("Unupgraded stats equal base stats", stats0.Power == 78 and stats0.Accuracy == 72 and stats0.Spin == 75)
	local ok1, _, lvl1 = ProfileOps.upgradeClub(d, gale, "Power")
	local afterFirst = d.Coins
	expect("First upgrade costs 500 and gives +2 stat points", ok1 and lvl1 == 1 and afterFirst == 100000 - 500 and (ProfileOps.clubStats(d, gale) :: ClubDatabase.Stats).Power == 80)
	local ok2, _, lvl2 = ProfileOps.upgradeClub(d, gale, "Power")
	expect("Second upgrade costs 700", ok2 and lvl2 == 2 and d.Coins == afterFirst - 700)
	expect("Other stats are untouched", (ProfileOps.clubStats(d, gale) :: ClubDatabase.Stats).Accuracy == 72)
	expect("Unknown stat / unknown club / unowned club rejected", select(2, ProfileOps.upgradeClub(d, gale, "Distance")) == "bad_stat" and select(2, ProfileOps.upgradeClub(d, "ghost", "Power")) == "unknown_club" and select(2, ProfileOps.upgradeClub(d, "pong_gale_fw", "Power")) == "not_owned")
	local broke = ProfileTemplate.new(0)
	broke.Coins = 100
	local okBroke, whyBrokeUp = ProfileOps.upgradeClub(broke, "tatermade_swift_dr", "Power")
	expect("Upgrade without enough coins is refused and free", not okBroke and whyBrokeUp == "insufficient_funds" and broke.Coins == 100 and broke.ClubUpgrades["tatermade_swift_dr"] == nil)
	-- Spend every coin and max a stat: cost sequence and the cap.
	local rich = ProfileTemplate.new(0)
	rich.Coins = 1e9
	local paid, lastReason = 0, ""
	for _ = 1, Config.Clubs.MaxUpgradeLevel + 2 do
		local start = rich.Coins
		local ok, why = ProfileOps.upgradeClub(rich, "tatermade_swift_dr", "Power")
		if ok then
			paid += start - rich.Coins
		else
			lastReason = why :: string
			break
		end
	end
	expect("Maxing one stat costs the full table (sum 27,350) then reports max_level", paid == 27350 and lastReason == "max_level")
	expect("Upgrade levels are stored in the profile", rich.ClubUpgrades["tatermade_swift_dr"].Power == Config.Clubs.MaxUpgradeLevel)
	-- StatCap: a 98-Distance club caps at 100 after one upgrade and then refuses.
	local capped = ProfileTemplate.new(0)
	capped.Coins = 1e6
	ProfileOps.grantClub(capped, "callaway_phoenix_dr")
	local c1 = ProfileOps.upgradeClub(capped, "callaway_phoenix_dr", "Power")
	local c2, whyCap = ProfileOps.upgradeClub(capped, "callaway_phoenix_dr", "Power")
	expect("Stat caps at 100 and further upgrades are refused (stat_capped)", c1 and not c2 and whyCap == "stat_capped" and (ProfileOps.clubStats(capped, "callaway_phoenix_dr") :: ClubDatabase.Stats).Power == 100)

	-- OVR
	local starterOvr = ProfileOps.playerOvr(ProfileTemplate.new(0))
	expect("Starter bag OVR is the starter line's OVR (60)", starterOvr == ClubDatabase.overall({ Power = 55, Accuracy = 60, Spin = 65 }))
	local withDriver = ProfileTemplate.new(0)
	withDriver.Coins = 1e6
	ProfileOps.buyClub(withDriver, "tatermade_shadow_dr")
	ProfileOps.equipClub(withDriver, "tatermade_shadow_dr")
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
	local bought = ProfileOps.buyClub(pr.Data, "titleless_tour_si") and ProfileOps.equipClub(pr.Data, "titleless_tour_si")
	local upgraded = ProfileOps.upgradeClub(pr.Data, "titleless_tour_si", "Accuracy")
	pr.release()
	local again = (storeFor(e2e, "job-2").load("Player_9")).Profile :: ProfileStore.Profile
	expect("Purchase + equip + upgrade survive release and reload", bought and upgraded and again.Data.Coins == 50000 - 20000 - 500 and again.Data.EquippedClubs["SI"] == "titleless_tour_si" and again.Data.ClubUpgrades["titleless_tour_si"].Accuracy == 1 and again.Data.Meta.Sessions == 2)
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
		expect("openCases: inventory gained exactly 3 club skins on top of the starters", owned == 3 + #ItemDatabase.ClubClasses)
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
		ProfileOps.grantItem(d, "skin_slate_longiron", 2) -- Common, sells 100
		ProfileOps.equipItem(d, "skin_crimson_driver") -- 1 copy reserved
		local r = Economy.sellItems(d, { "skin_crimson_driver", "skin_crimson_driver", "skin_slate_longiron" }, ctx())
		expect("sellItems: pays each rarity's SellValue (2x600 + 100 = 1300) and removes the copies", r.ok and r.CoinsGained == 1300 and d.Coins == 1300 and ProfileOps.ownedCount(d, "skin_crimson_driver") == 1 and ProfileOps.ownedCount(d, "skin_slate_longiron") == 1)
		local before = TableUtil.deepCopy(d)
		expect("sellItems: can't sell the equipped copy (nothing sold, even the valid part)", Economy.sellItems(d, { "skin_slate_longiron", "skin_crimson_driver" }, ctx()).reason == "insufficient_spare" and deepEqual(before, d))
		expect("sellItems: can't sell a starter item", Economy.sellItems(d, { "skin_midnight_driver" }, ctx()).reason == "insufficient_spare" and deepEqual(before, d))
		expect("sellItems: unowned item refused", Economy.sellItems(d, { "skin_gold_rush_driver" }, ctx()).reason == "not_owned" and deepEqual(before, d))
		expect("sellItems: unknown id refused", Economy.sellItems(d, { "ghost" }, ctx()).reason == "unknown_item" and deepEqual(before, d))
		local tooMany: { string } = {}
		for _ = 1, Config.Economy.SellBatchMax + 1 do
			table.insert(tooMany, "skin_slate_longiron")
		end
		local bad = { {}, { "a", 5 }, { x = "skin_slate_longiron" }, "skin_slate_longiron", 5, tooMany }
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
		ProfileOps.grantItem(mixedRarity, "skin_slate_longiron", 1)
		expect("tradeUp: mixed rarities refused", Economy.tradeUp(mixedRarity, { "skin_crimson_driver", "skin_crimson_driver", "skin_crimson_driver", "skin_crimson_driver", "skin_slate_longiron" }, ctx()).reason == "mixed_rarity")
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
		local ids = { "skin_crimson_driver", "skin_crimson_fairwaywood", "skin_crimson_longiron", "skin_crimson_wedge", "skin_ocean_putter" }
		for _, id in ids do
			ProfileOps.grantItem(distinct, id, 1)
		end
		expect("tradeUp: five different items of one rarity and category work", Economy.tradeUp(distinct, ids, ctx()).ok)
	end

	-- Clubs
	do
		local d = fresh(30000)
		local up = Economy.upgradeClub(d, "tatermade_swift_dr", "Power")
		expect("upgradeClub: result reports level and cost", up.ok and up.NewLevel == 1 and up.Cost == 500 and d.Coins == 29500)
		local buy = Economy.buyClub(d, "pong_gale_dr")
		expect("buyClub: result reports the coins spent", buy.ok and (buy.Spent :: Types.Price).Amount == 12000 and d.Coins == 17500)
		expect("buyClub / upgradeClub failures carry the reason", Economy.buyClub(d, "pong_gale_dr").reason == "already_owned" and Economy.upgradeClub(d, "pong_gale_dr", "Distance").reason == "bad_stat")
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
				for _, stat in { levels.Power, levels.Accuracy, levels.Spin } do
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
				local stat: any = if fz.next() < 0.9 then ({ "Power", "Accuracy", "Spin" })[fz.nextInt(3)] else randomItemId()
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
	expect("All 9 holes: sensible par for length, tee in bounds, pin on the green", allValid and #CourseDatabase.Holes == 9)
	local h1, h2 = CourseDatabase.hole(1), CourseDatabase.hole(2)
	expect("Hole lookups wrap around (hole 10 = hole 1)", CourseDatabase.hole(10).Id == 1 and CourseDatabase.hole(0).Id == 9)
	local beginner, expert = CourseDatabase.course("Beginner"), CourseDatabase.course("Expert")
	expect("Par-36 nine split into three 3-hole courses (Beginner 1-3, Intermediate 4-6, Expert 7-9)",
		CourseData.totalPar() == 36 and beginner ~= nil and #beginner == 3 and beginner[1].Id == 1 and expert ~= nil and expert[3].Id == 9
			and CourseDatabase.course("Intermediate") ~= nil and CourseDatabase.course("Nope") == nil)
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
	expect("Lie priority: green > water > sand > fairway (an island green plays as green)", CourseTerrain.lieAt(priority, 50, 0) == "Green" and CourseTerrain.lieAt(priority, 53, 0) == "Green" and CourseTerrain.lieAt(priority, 56, 0) == "Sand" and CourseTerrain.lieAt(priority, 62, 0) == "Fairway")
	local finale = CourseDatabase.hole(9)
	expect("Out-of-bounds zones inside the bounds (hole 9's road) are out of bounds", not CourseTerrain.inBounds(finale, 150 * YDS, 60 * YDS) and CourseTerrain.inBounds(finale, 150 * YDS, 30 * YDS))
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
	local lwLaunch = SwingMath.computeLaunch({ Slot = ClubDatabase.getSlot("WG") :: ClubDatabase.BagSlot, Stats = { Power = 50, Accuracy = 60, Spin = 60 }, Power = 100, AccuracyOffset = 0, Lie = "Tee" })
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
	local noPlay: MatchSettlement.PlayStats = { HolesPlayed = 3, HolesInOne = 0, LongestDriveYds = 0, FairwaysHit = 0 }
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
	local credited = MatchSettlement.applyToProfile(d, winOutcome, { HolesPlayed = 3, HolesInOne = 1, LongestDriveYds = 301.7, FairwaysHit = 2 })
	expect("applyToProfile: payout, ranked win, holes, hole-in-one, longest drive", credited == pro.WinPayout and d.Coins == pro.WinPayout and d.Stats.Wins == 1 and d.Stats.MatchesPlayed == 1 and d.Stats.HolesPlayed == 3 and d.Stats.HolesInOne == 1 and d.Stats.LongestDriveYds == 301 and d.Stats.TotalCoinsEarned == pro.WinPayout)
	local d2 = ProfileTemplate.new(0)
	MatchSettlement.applyToProfile(d2, MatchSettlement.settle(resultFor(nil, true), "Ranked", pro, { "A", "B" }).A, noPlay)
	expect("A refund is not counted as earnings (TotalCoinsEarned stays 0)", d2.Coins == Config.Economy.StartingCoins + pro.EntryFee and d2.Stats.TotalCoinsEarned == 0 and d2.Stats.Wins == 0 and d2.Stats.Losses == 0)
	local d3 = ProfileTemplate.new(0)
	MatchSettlement.applyToProfile(d3, MatchSettlement.settle(resultFor("B", false), "Ranked", pro, { "A", "B" }).A, noPlay)
	expect("Ranked loss recorded, no coins", d3.Stats.Losses == 1 and d3.Coins == Config.Economy.StartingCoins)
	local d4 = ProfileTemplate.new(0)
	d4.Stats.LongestDriveYds = 320
	MatchSettlement.applyToProfile(d4, MatchSettlement.settle(resultFor("A", false), "Bot", nil, { "A" }).A, { HolesPlayed = 3, HolesInOne = 0, LongestDriveYds = 250, FairwaysHit = 0 })
	expect("Bot match counts as played but not as a ranked win; longest drive keeps the max", d4.Stats.MatchesPlayed == 1 and d4.Stats.Wins == 0 and d4.Stats.LongestDriveYds == 320)
	local refundable = ProfileTemplate.new(0)
	refundable.Coins = 50
	expect("ProfileOps.refund adds without earnings and rejects bad amounts", ProfileOps.refund(refundable, "Coins", 100) and refundable.Coins == 150 and refundable.Stats.TotalCoinsEarned == 0 and not ProfileOps.refund(refundable, "Coins", -5) and not ProfileOps.refund(refundable, "Coins", 0 / 0))
end

-- Match engine ----------------------------------------------------------------------
print("-- match engine")
do
	local mid: ClubDatabase.Stats = { Power = 70, Accuracy = 70, Spin = 70 }
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
	local engine = MatchEngine.new({ IntroSeconds = 0, Players = twoHumans(), Holes = CourseDatabase.sequence(1, 3), Seed = 42, Now = 0 })
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
	local pondEngine = MatchEngine.new({ IntroSeconds = 0, Players = twoHumans(), Holes = { CourseDatabase.hole(2) }, Seed = 7, Now = 0 })
	local shooter = pondEngine.activeId() :: string
	pondEngine.setClub(shooter, "WG")
	local beforeSwing = playerView(pondEngine.snapshot(0), shooter)
	pondEngine.submitSwing(shooter, 100, 0, 30)
	local pondShot = eventsOfType(pondEngine.drainEvents(), "Shot")[1].Data
	expect("Par 3 pond: a short club ends in the water, penalty applied (2 strokes), not holed", pondShot.Outcome == "Water" and pondShot.Penalty and pondShot.Stroke == 2 and not pondShot.Holed)
	local afterSwing = playerView(pondEngine.snapshot(30), shooter)
	expect("Water: the ball is replayed from the same spot with the same lie", beforeSwing.Position.X == afterSwing.Position.X and beforeSwing.Position.Z == afterSwing.Position.Z and afterSwing.Lie == "Tee")

	local obEngine = MatchEngine.new({ IntroSeconds = 0, Players = twoHumans(), Holes = { CourseDatabase.hole(1) }, Seed = 8, Now = 0 })
	local obShooter = obEngine.activeId() :: string
	obEngine.setClub(obShooter, "DR")
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
		return MatchEngine.new({ IntroSeconds = 0, Players = twoBots(), Holes = { hole }, Seed = seed, Now = 0 })
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
	local toEngine = MatchEngine.new({ IntroSeconds = 0, Players = twoHumans(), Holes = CourseDatabase.sequence(1, 3), Seed = 5, Now = 0 })
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
	local ff = MatchEngine.new({ IntroSeconds = 0, Players = twoHumans(), Holes = CourseDatabase.sequence(1, 3), Seed = 6, Now = 0 })
	ff.forfeit("H1", 10)
	local ffResult = ff.result()
	expect("Forfeit ends the match at once; the other player wins", ff.isFinished() and ffResult.WinnerId == "H2" and ffResult.Reason == "forfeit" and ffResult.ForfeitedIds[1] == "H1" and ff.phase() == "Finished" and ff.activeId() == nil)
	local ffEvents = ff.drainEvents()
	expect("Forfeit emits Forfeit and MatchComplete events", #eventsOfType(ffEvents, "Forfeit") == 1 and #eventsOfType(ffEvents, "MatchComplete") == 1)
	local _, whyAfter = ff.submitSwing("H2", 50, 0, 100)
	expect("No swings after the match is over", whyAfter == "not_your_turn")
	ff.forfeit("H2", 11)
	expect("Forfeiting again after the end is ignored", #ff.result().ForfeitedIds == 1 and ff.result().WinnerId == "H2")

	local humanEngine = MatchEngine.new({ IntroSeconds = 0, Players = twoHumans(), Holes = CourseDatabase.sequence(1, 1), Seed = 9, Now = 0 })
	local _, whyHuman = humanEngine.submitBotSwing(humanEngine.activeId() :: string, "DR", 0, 50, 0, 1)
	expect("submitBotSwing refuses human players (no way to bypass the timing check)", whyHuman == "not_a_bot")

	-- Honour: the lower score tees off first on the next hole ----------------------------------
	local honourOk, honourChecked = true, 0
	for seed = 1, 12 do
		local e = MatchEngine.new({ IntroSeconds = 0, Players = twoBots(), Holes = CourseDatabase.sequence(1, 2), Seed = seed, Now = 0 })
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
		local match = MatchEngine.new({ IntroSeconds = 0, Players = specs, Holes = holes, Seed = seed, Now = 0 })
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

	-- Fringe putting: from short grass just off the green even the Easy bot putts.
	local fringeM = 18 * Config.Physics.YardsToMeters
	local fringeHole: CourseDatabase.HoleDef = {
		Id = 91, Name = "Fringe", Par = 3, Tee = { X = 0, Z = 0 }, Pin = { X = fringeM, Z = 0 },
		Fairway = { { AX = 0, AZ = 0, BX = fringeM, BZ = 0, HalfWidth = 12 } }, Greens = { { X = fringeM, Z = 0, R = 6 * Config.Physics.YardsToMeters } },
		Bunkers = {}, Water = {}, GreenSlope = { X = 0, Z = 0 }, Bounds = { MinX = -20, MaxX = 80, MinZ = -40, MaxZ = 40 },
	}
	local putts = 0
	for seed = 1, 10 do
		local fe = MatchEngine.new({ IntroSeconds = 0, Players = twoBots(), Holes = { fringeHole }, Seed = seed, Now = 0 })
		local fid = fe.activeId() :: string
		local decision = BotBrain.decide({
			situation = function(): MatchEngine.Situation
				return fe.situation(fid) :: MatchEngine.Situation
			end,
			preview = function(label: string, aim: number, power: number, offset: number, windScale: number): SwingMath.ResolvedShot?
				return fe.preview(fid, label, aim, power, offset, windScale)
			end,
			landing = function(aim: number, result: ShotPhysics.ShotResult): (Types.LieId, boolean)
				return fe.landing(fid, aim, result)
			end,
			statsFor = BotBrain.statsFor("Easy"),
		}, "Easy", Prng.new(seed).next)
		if decision.ClubLabel == "PT" then
			putts += 1
		end
	end
	expect("Easy bot putts from short grass 18 yards out instead of forcing a chip", putts == 10)

	-- Bot planning must not change the match.
	local probe = MatchEngine.new({ IntroSeconds = 0, Players = twoBots(), Holes = CourseDatabase.sequence(1, 3), Seed = 21, Now = 0 })
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


-- Client logic: format, signal, advisor ---------------------------------------------
print("-- client basics")
do
	expect("Format.commas", Format.commas(0) == "0" and Format.commas(999) == "999" and Format.commas(1000) == "1,000" and Format.commas(12450) == "12,450" and Format.commas(-1234567) == "-1,234,567" and Format.commas(1234567.9) == "1,234,567")
	expect("Format yards / feet / rpm / mph round and label", Format.yards(277.6) == "278 YDS" and Format.feet(111.5) == "112 FT" and Format.rpm(2450) == "2,450 RPM" and Format.mph(8.2) == "8 MPH")
	expect("Format.clock and countdown", Format.clock(75) == "1:15" and Format.clock(-5) == "0:00" and Format.countdown(8109) == "02:15:09" and Format.countdown(0) == "00:00:00")
	expect("Format.relative: E / -2 / +3", Format.relative(4, 4) == "E" and Format.relative(2, 4) == "-2" and Format.relative(7, 4) == "+3")
	expect("Format.scoreName", Format.scoreName(1, 3) == "Hole in One!" and Format.scoreName(3, 5) == "Eagle" and Format.scoreName(3, 4) == "Birdie" and Format.scoreName(4, 4) == "Par" and Format.scoreName(5, 4) == "Bogey" and Format.scoreName(6, 4) == "Double Bogey" and Format.scoreName(8, 4) == "+4")
	expect("Format.ordinal", Format.ordinal(1) == "1st" and Format.ordinal(2) == "2nd" and Format.ordinal(3) == "3rd" and Format.ordinal(4) == "4th" and Format.ordinal(11) == "11th" and Format.ordinal(12) == "12th" and Format.ordinal(21) == "21st" and Format.ordinal(113) == "113th")

	local signal = Signal.new()
	local calls: { string } = {}
	local c1 = signal.connect(function(v: any)
		table.insert(calls, "a" .. tostring(v))
	end)
	local c2: Signal.Connection
	c2 = signal.connect(function(v: any)
		table.insert(calls, "b" .. tostring(v))
		c2.disconnect() -- disconnecting yourself mid-fire is safe
	end)
	signal.connect(function(_v: any)
		error("a failing listener")
	end)
	signal.connect(function(v: any)
		table.insert(calls, "d" .. tostring(v))
	end)
	signal.fire(1)
	signal.fire(2)
	expect("Signal: listeners run in connect order; a failing one doesn't stop the rest", table.concat(calls, ",") == "a1,b1,d1,a2,d2")
	c1.disconnect()
	signal.fire(3)
	expect("Signal: disconnect stops delivery; count tracks listeners", calls[#calls] == "d3" and calls[#calls - 1] == "d2" and signal.count() == 2)

	local mid: ClubDatabase.Stats = { Power = 60, Accuracy = 60, Spin = 60 }
	local function midStats(_label: string): ClubDatabase.Stats
		return mid
	end
	expect("ClubAdvisor: auto-putter - any distance on the green -> putter; short grass just off it -> putter; rough / sand / farther -> never",
		ClubAdvisor.recommendClub(15, "Green", midStats) == "PT" and ClubAdvisor.recommendClub(60, "Green", midStats) == "PT"
			and ClubAdvisor.recommendClub(5, "Fairway", midStats) == "PT" and ClubAdvisor.recommendClub(5, "Rough", midStats) ~= "PT"
			and ClubAdvisor.recommendClub(5, "Sand", midStats) ~= "PT" and ClubAdvisor.recommendClub(20, "Fairway", midStats) ~= "PT")
	expect("ClubAdvisor: a 320-yard tee shot takes the driver (longest club)", ClubAdvisor.recommendClub(320, "Tee", midStats) == "DR")
	local last, mono = 0, true
	for yardsAway = 20, 300, 10 do
		local label = ClubAdvisor.recommendClub(yardsAway, "Fairway", midStats)
		local reach = ClubAdvisor.estimateCarry(ClubDatabase.getSlot(label) :: ClubDatabase.BagSlot, mid, "Fairway")
		if reach < last - 1e-9 then
			mono = false
		end
		last = reach
	end
	expect("ClubAdvisor: the recommended club's reach never shrinks as the distance grows", mono)
	local roughReach = ClubAdvisor.estimateCarry(ClubDatabase.getSlot("SI") :: ClubDatabase.BagSlot, mid, "Rough")
	local fairReach = ClubAdvisor.estimateCarry(ClubDatabase.getSlot("SI") :: ClubDatabase.BagSlot, mid, "Fairway")
	expect("ClubAdvisor: the rough shortens a club's reach", roughReach < fairReach)
end

-- Shots to drive the telemetry / camera tests ----------------------------------------------
local clientShots: { { [string]: any } } = {}
do
	local rngS = Prng.new(5)
	local specs: { MatchEngine.PlayerSpec } = {
		{ Id = "A", Name = "A", IsBot = true, StatsFor = BotBrain.statsFor("Hard") },
		{ Id = "B", Name = "B", IsBot = true, StatsFor = BotBrain.statsFor("Easy") },
	}
	local e = MatchEngine.new({ IntroSeconds = 0, Players = specs, Holes = CourseDatabase.sequence(1, 3), Seed = 3, Now = 0 })
	local tS = 0.0
	for _ = 1, 2000 do
		if e.isFinished() then
			break
		end
		tS += 0.5
		e.tick(tS)
		local id = e.activeId()
		if id and e.phase() == "Swing" then
			BotBrain.play(e, id, if id == "A" then "Hard" else "Easy", rngS.next, tS)
		end
		for _, ev in e.drainEvents() do
			if ev.Type == "Shot" then
				table.insert(clientShots, ev.Data)
			end
		end
	end
end

-- Telemetry overlay -------------------------------------------------------------------------
print("-- telemetry view")
do
	expect(`Collected {#clientShots} real shots (drives, wedges, putts) from a bot match`, #clientShots >= 15)
	local okStart, okMono, okFreeze, okEnd, okLanded, okRoll = true, true, true, true, true, true
	local kinds = { drive = 0, putt = 0 }
	for _, shot in clientShots do
		local s0 = TelemetryView.at(shot :: any, 0)
		if not (s0.CarryYds == 0 or shot.AirSeconds == 0) or s0.TotalYds > 0.001 or s0.ApexFeet > 0.001 or s0.Done then
			okStart = false
		end
		local duration = TelemetryView.duration(shot :: any)
		local prevTotal, prevApex, prevCarry = 0, 0, 0
		local t = 0.0
		while t <= duration + 0.5 do
			local live = TelemetryView.at(shot :: any, t)
			if t < shot.AirSeconds then
				if live.TotalYds < prevTotal - 0.05 or live.CarryYds < prevCarry - 0.05 or live.Landed then
					okMono = false
				end
				prevTotal, prevCarry = live.TotalYds, live.CarryYds
			end
			if live.ApexFeet < prevApex - 1e-6 then
				okMono = false
			end
			prevApex = live.ApexFeet
			if t >= shot.AirSeconds and math.abs(live.CarryYds - shot.Telemetry.CarryYds) > 1e-6 then
				okFreeze = false
			end
			if live.Landed ~= (t >= shot.AirSeconds) then
				okLanded = false
			end
			if live.RollYds < -1e-9 then
				okRoll = false
			end
			t += 0.05
		end
		local final = TelemetryView.at(shot :: any, duration + 10)
		local tel: any = shot.Telemetry
		if not (final.Done and final.CarryYds == tel.CarryYds and final.TotalYds == tel.TotalYds and final.RollYds == tel.RollYds and final.ApexFeet == tel.ApexFeet and final.SpinRpm == tel.SpinRpm) then
			okEnd = false
		end
		if shot.ClubLabel == "PT" then
			kinds.putt += 1
		elseif shot.ClubLabel == "DR" then
			kinds.drive += 1
		end
	end
	expect("At t=0 every shot reads zero carry/total/apex and is not done", okStart)
	expect("During flight carry, total and apex only grow", okMono)
	expect("Carry freezes at the server's final carry from touchdown on", okFreeze)
	expect("Landed flips exactly at AirSeconds; roll is never negative", okLanded and okRoll)
	expect("When the ball stops, the overlay shows the server's exact final numbers", okEnd)
	expect("The sample covers both drives and putts", kinds.drive >= 2 and kinds.putt >= 3)
	local drive: any = nil
	for _, shot in clientShots do
		if shot.ClubLabel == "DR" and drive == nil then
			drive = shot
		end
	end
	local halfTime = drive.AirSeconds / 2
	local half = TelemetryView.at(drive :: any, halfTime)
	expect("Mid-flight on a drive: airborne, apex already substantial, carry about half-ish", not half.Landed and half.ApexFeet > 0.5 * drive.Telemetry.ApexFeet and half.CarryYds > 20 and half.CarryYds < drive.Telemetry.CarryYds)
	local samples = { { 0, 0, 0, 0 }, { 2, 10, 4, 6 } }
	local mx, my, mz = TelemetryView.positionAt(samples, 1)
	local lx, _, _ = TelemetryView.positionAt(samples, -5)
	local rx, _, _ = TelemetryView.positionAt(samples, 99)
	expect("positionAt interpolates linearly and clamps outside the samples", mx == 5 and my == 2 and mz == 3 and lx == 0 and rx == 10)
	local ex, ey, ez = TelemetryView.positionAt({}, 1)
	expect("positionAt of an empty trajectory is the origin", ex == 0 and ey == 0 and ez == 0)
end

-- Chase camera ---------------------------------------------------------------------------------
print("-- camera")
do
	local SPM = CourseLayout.STUDS_PER_METER
	local T = CameraMath.Tuning
	local allOk = true
	local minSeen: number, maxSeen: number, maxStepSeen: number, finalMax: number = 1e9, 0.0, 0.0, 0.0
	local lookOk, groundOk, finiteOk = true, true, true
	for _, shot in clientShots do
		local samples = shot.Samples :: { { number } }
		local duration = TelemetryView.duration(shot :: any)
		local first = samples[1]
		local ball0: CameraMath.Vec3 = { X = first[2] * SPM, Y = first[3] * SPM, Z = first[4] * SPM }
		local aimX, aimZ = shot.End.X - shot.Start.X, shot.End.Z - shot.Start.Z
		if math.abs(aimX) + math.abs(aimZ) < 1e-6 then
			aimX, aimZ = 1, 0
		end
		local state = CameraMath.startFollow(ball0, aimX, aimZ)
		local prevPos = state.Pos
		local dt = 1 / 60
		local t = 0.0
		local lastDist = 0.0
		while t < duration + 3 do
			t += dt
			local x, y, z = TelemetryView.positionAt(samples, t)
			local ball: CameraMath.Vec3 = { X = x * SPM, Y = y * SPM, Z = z * SPM }
			local pose
			state, pose = CameraMath.follow(state, ball, dt)
			local dist = math.sqrt((pose.Pos.X - ball.X) ^ 2 + (pose.Pos.Y - ball.Y) ^ 2 + (pose.Pos.Z - ball.Z) ^ 2)
			local step = math.sqrt((pose.Pos.X - prevPos.X) ^ 2 + (pose.Pos.Y - prevPos.Y) ^ 2 + (pose.Pos.Z - prevPos.Z) ^ 2)
			minSeen = math.min(minSeen, dist)
			maxSeen = math.max(maxSeen, dist)
			maxStepSeen = math.max(maxStepSeen, step)
			if math.abs(pose.Look.X - ball.X) > 1e-9 or math.abs(pose.Look.Z - ball.Z) > 1e-9 then
				lookOk = false
			end
			if pose.Pos.Y < state.Floor + T.MinGroundClearance - 1e-9 or state.Floor > ball.Y + 1e-9 then
				groundOk = false
			end
			if not (dist == dist and step == step and pose.Pos.X == pose.Pos.X) then
				finiteOk = false
			end
			prevPos = pose.Pos
			lastDist = dist
		end
		finalMax = math.max(finalMax, lastDist)
		if lastDist > 14 then
			allOk = false
		end
	end
	print(`  camera over {#clientShots} shots: distance {math.floor(minSeen * 10) / 10}-{math.floor(maxSeen * 10) / 10} studs, max {math.floor(maxStepSeen * 100) / 100} studs/frame, final {math.floor(finalMax * 10) / 10}`)
	expect("Camera always looks directly at the ball (the ball can never leave the frame)", lookOk)
	expect("Camera never dips below the tracked ground level (+ clearance) and never produces NaN", groundOk and finiteOk)
	expect("Camera stays between 11 and 90 studs from the ball through every shot", minSeen > 11 and maxSeen < 90)
	expect("Camera motion is smooth (<= 5 studs per frame at 60 fps)", maxStepSeen <= 5)
	expect("Camera settles into a close-up (<= 14 studs) once the ball is at rest, for every shot", allOk)

	local ball: CameraMath.Vec3 = { X = 100, Y = 0, Z = 50 }
	local address = CameraMath.addressPose(ball, 3, 4)
	local back = (address.Pos.X - ball.X) * 0.6 + (address.Pos.Z - ball.Z) * 0.8
	local ahead = (address.Look.X - ball.X) * 0.6 + (address.Look.Z - ball.Z) * 0.8
	expect("Address camera sits behind the ball and looks down the aim line", back < -15 and ahead > 20 and address.Pos.Y > 3)
	local tee: CameraMath.Vec3 = { X = 0, Y = 0, Z = 0 }
	local pin: CameraMath.Vec3 = { X = 1000, Y = 0, Z = 300 }
	local overview = CameraMath.overviewPose(tee, pin)
	local intro1 = CameraMath.introPose(tee, pin, 1)
	local intro0 = CameraMath.introPose(tee, pin, 0)
	expect("Intro flyover ends exactly on the overview and starts near the green", math.abs(intro1.Pos.X - overview.Pos.X) < 1e-9 and math.abs(intro1.Look.Z - overview.Look.Z) < 1e-9 and math.abs(intro0.Look.X - pin.X) < 1e-9 and intro0.Pos.Y > 30)
	local smooth, prevI = true, CameraMath.introPose(tee, pin, 0)
	for i = 1, 60 do
		local cur = CameraMath.introPose(tee, pin, i / 60)
		if math.sqrt((cur.Pos.X - prevI.Pos.X) ^ 2 + (cur.Pos.Z - prevI.Pos.Z) ^ 2) > 60 then
			smooth = false
		end
		prevI = cur
	end
	expect("Flyover moves in small, continuous steps", smooth)
end

-- Course layout ---------------------------------------------------------------------------------
print("-- course layout")
do
	local SPM = CourseLayout.STUDS_PER_METER
	local allFinite, allSized, countsOk, treesOk, coverOk = true, true, true, true, true
	for _, hole in CourseDatabase.Holes do
		local layout = CourseLayout.build(hole)
		local parts = layout.Parts
		if #parts < 20 or #parts > 700 then
			countsOk = false
		end
		local minX: number, maxX: number, minZ: number, maxZ: number = 1e18, -1e18, 1e18, -1e18
		for _, part in parts do
			for _, v in { part.X, part.Y, part.Z, part.SX, part.SY, part.SZ, part.YawDeg } do
				if v ~= v or math.abs(v) == math.huge then
					allFinite = false
				end
			end
			if part.SX <= 0 or part.SY <= 0 or part.SZ <= 0 or part.SX > 2048 or part.SY > 2048 or part.SZ > 2048 then
				allSized = false
			end
			if string.sub(part.Name, 1, 5) == "Rough" then
				minX = math.min(minX, part.X - part.SX / 2)
				maxX = math.max(maxX, part.X + part.SX / 2)
				minZ = math.min(minZ, part.Z - part.SZ / 2)
				maxZ = math.max(maxZ, part.Z + part.SZ / 2)
			end
			if string.sub(part.Name, 1, 9) == "TreeTrunk" then
				local lie = CourseTerrain.lieAt(hole, part.X / SPM, part.Z / SPM)
				if lie ~= "Rough" then
					treesOk = false
				end
			end
		end
		local b = hole.Bounds
		if math.abs(minX - b.MinX * SPM) > 1e-6 or math.abs(maxX - b.MaxX * SPM) > 1e-6 or math.abs(minZ - b.MinZ * SPM) > 1e-6 or math.abs(maxZ - b.MaxZ * SPM) > 1e-6 then
			coverOk = false
		end
		if math.abs(layout.Pin.X - hole.Pin.X * SPM) > 1e-9 or math.abs(layout.Pin.Z - hole.Pin.Z * SPM) > 1e-9 or math.abs(layout.Tee.X - hole.Tee.X * SPM) > 1e-9 then
			allFinite = false
		end
	end
	expect("Every hole lays out to a sensible number of parts, all finite", countsOk and allFinite)
	expect("No part exceeds Roblox's 2048-stud limit (big areas are tiled)", allSized)
	expect("The rough tiles cover exactly the playable bounds", coverOk)
	expect("Trees only stand in rough or outside the bounds, never on the playing surfaces", treesOk)

	local h3 = CourseDatabase.hole(3)
	local layout3 = CourseLayout.build(h3)
	local byName: { [string]: CourseLayout.PartSpec } = {}
	for _, part in layout3.Parts do
		byName[part.Name] = part
	end
	local seg = byName["Fairway_2"]
	local fw = h3.Fairway[2]
	local dx, dz = fw.BX - fw.AX, fw.BZ - fw.AZ
	local len = math.sqrt(dx * dx + dz * dz)
	local yaw = math.rad(seg.YawDeg)
	expect("Fairway box runs along its segment (local +X maps to the segment direction)", math.abs(math.cos(yaw) - dx / len) < 1e-9 and math.abs(-math.sin(yaw) - dz / len) < 1e-9 and math.abs(seg.SX - len * SPM) < 1e-6 and math.abs(seg.SZ - fw.HalfWidth * 2 * SPM) < 1e-6)
	-- Top surface of a part: discs are thin along SX, blocks along SY.
	local function topOf(part: CourseLayout.PartSpec): number
		return part.Y + (if part.Shape == "Disc" then part.SX else part.SY) / 2
	end
	local fairTop = topOf(byName["Fairway_1"])
	local sandTop = topOf(byName["Bunker_1"])
	local greenTop = topOf(byName["Green_1"])
	local waterTop = topOf(byName["Water_1"])
	local roughTop = topOf(byName["Rough_0_0"])
	expect("Surface layers stack in lie-priority order: rough < fairway < sand < green < water", roughTop < fairTop and fairTop < sandTop and sandTop < greenTop and greenTop < waterTop)
	expect("The pond is a translucent disc the size of the hole data", byName["Water_1"].Shape == "Disc" and math.abs(byName["Water_1"].SY - h3.Water[1].R * 2 * SPM) < 1e-6 and byName["Water_1"].Transparency > 0)
	expect("Pin pole stands on the green at the pin", math.abs(byName["PinPole"].X - h3.Pin.X * SPM) < 1e-9 and topOf(byName["PinPole"]) > greenTop + 5)
	local again = CourseLayout.build(h3)
	local identical = #again.Parts == #layout3.Parts
	for i, part in layout3.Parts do
		if identical and (again.Parts[i].X ~= part.X or again.Parts[i].Name ~= part.Name) then
			identical = false
		end
	end
	expect("Layout is deterministic (same trees every build, on every client)", identical)
	local tileHole = CourseDatabase.hole(3)
	local widest = 0.0
	for _, part in CourseLayout.build(tileHole).Parts do
		widest = math.max(widest, part.SX, part.SZ)
	end
	expect("The out-of-bounds apron is tiled below the part-size cap", widest <= CourseLayout.MAX_PART_SIZE + 1e-6)
end

-- Swing gauge layout --------------------------------------------------------------------------------
print("-- gauge view")
do
	local green = 0.08
	local sm = SwingStateMachine.new()
	sm.start(0)
	local rising = GaugeView.layout(sm.gauge(PS * 0.4), green, 0.62)
	expect("Stage 1: power fill follows the marker, no needle yet, target tick passed through", math.abs(rising.PowerFill - 0.4) < 1e-9 and rising.NeedleX == nil and not rising.Locked and rising.TargetPower == 0.62)
	expect("Sweet spot is centred on the track and inside the good band", math.abs((rising.SweetLeft + rising.SweetRight) / 2 - 0.5) < 1e-12 and rising.GoodLeft < rising.SweetLeft and rising.GoodRight > rising.SweetRight)
	sm.click(PS * 0.4)
	local accuracy = GaugeView.layout(sm.gauge(PS * 0.4 + AS * 0.5), green, nil)
	expect("Stage 2: power locked, needle at the track centre at the perfect time", accuracy.Locked and math.abs(accuracy.PowerPercent - 40) < 1e-9 and accuracy.NeedleX ~= nil and math.abs((accuracy.NeedleX :: number) - 0.5) < 1e-9)
	local edge = GaugeView.layout(sm.gauge(PS * 0.4 + AS * (1 - green) / 2), green, nil)
	expect("Needle on the sweet spot's left edge exactly at offset -greenHalfWidth", edge.NeedleX ~= nil and math.abs((edge.NeedleX :: number) - edge.SweetLeft) < 1e-9)
end

-- Mini map -------------------------------------------------------------------------------------------
print("-- mini map")
do
	local allIn, orient, scaleOk = true, true, true
	for _, hole in CourseDatabase.Holes do
		local map = MiniMap.layout(hole, 120, 260, 6)
		for _, corner in map.Outline do
			if corner[1] < -0.001 or corner[1] > 120.001 or corner[2] < -0.001 or corner[2] > 260.001 then
				allIn = false
			end
		end
		for _, shape in map.Shapes do
			local cx, cy = if shape.Kind == "Circle" then shape.X else (shape.X1 + shape.X2) / 2, if shape.Kind == "Circle" then shape.Y else (shape.Y1 + shape.Y2) / 2
			if cx < 0 or cx > 120 or cy < 0 or cy > 260 then
				allIn = false
			end
		end
		if not (map.Tee[2] > map.Pin[2] and math.abs(map.Tee[1] - map.Pin[1]) < 1e-6) then
			orient = false
		end
		local px, py = map.project(hole.Pin.X, hole.Pin.Z)
		if math.abs(px - map.Pin[1]) > 1e-9 or math.abs(py - map.Pin[2]) > 1e-9 then
			orient = false
		end
		local pixelsPerMetre = (map.Tee[2] - map.Pin[2]) / math.sqrt((hole.Pin.X - hole.Tee.X) ^ 2 + (hole.Pin.Z - hole.Tee.Z) ^ 2)
		local greenCircle: MiniMap.Circle? = nil
		for _, shape in map.Shapes do
			if shape.Kind == "Circle" and shape.Lie == "Green" then
				greenCircle = shape
			end
		end
		if not (greenCircle and math.abs(greenCircle.R - hole.Greens[1].R * pixelsPerMetre) < 1e-6) then
			scaleOk = false
		end
	end
	expect("Every hole's map fits its box (outline, fairways, hazards all inside)", allIn)
	expect("Tee is at the bottom and the pin straight above it, for dogleg holes too", orient)
	expect("Map scale is uniform (a green's drawn radius matches the tee-to-pin scale)", scaleOk)
	local map = MiniMap.layout(CourseDatabase.hole(2), 100, 200)
	local lakes = 0
	for _, shape in map.Shapes do
		if shape.Kind == "Circle" and shape.Lie == "Water" then
			lakes += 1
		end
	end
	expect("The par 3's pond appears on its map", lakes == 1)
end

-- HUD view model --------------------------------------------------------------------------------------
print("-- match view")
do
	local mid: ClubDatabase.Stats = { Power = 70, Accuracy = 70, Spin = 70 }
	local function statsFor(_label: string): ClubDatabase.Stats
		return mid
	end
	local specs: { MatchEngine.PlayerSpec } = {
		{ Id = "me", Name = "Drew", IsBot = false, StatsFor = statsFor },
		{ Id = "rival", Name = "Rival", IsBot = false, StatsFor = statsFor },
	}
	local engine = MatchEngine.new({ IntroSeconds = 0, Players = specs, Holes = CourseDatabase.sequence(1, 3), Seed = 42, Now = 0 })
	local snap = engine.snapshot(12)
	local hud = MatchView.hud(snap, "me", statsFor)
	local active = engine.activeId()
	expect("HUD: hole / par / yards / progress text", hud.HoleText == "HOLE 1" and hud.ParText == "PAR 4" and hud.YardsText == "380 YDS" and hud.ProgressText == "1 / 3")
	expect("HUD: my-turn flag and banner follow the active player", hud.IsMyTurn == (active == "me") and (hud.Banner == "YOUR SHOT" or hud.Banner == "RIVAL'S SHOT"))
	expect("HUD: timer counts down from the snapshot", hud.TimerSeconds == Config.Match.TurnSeconds - 12 and hud.TimerText == "0:28")
	local selected, recommended = 0, 0
	for _, option in hud.ClubOptions do
		if option.Selected then
			selected += 1
		end
		if option.Recommended then
			recommended += 1
		end
	end
	expect("HUD: 6 club options, exactly one selected and one recommended; putter has no reach", #hud.ClubOptions == 6 and selected == 1 and recommended == 1 and hud.ClubOptions[6].Label == "PT" and hud.ClubOptions[6].ReachYds == 0 and hud.ClubOptions[1].ReachYds > 200)
	expect("HUD: score rows for both players with me flagged", #hud.Rows == 2 and hud.Me ~= nil and (hud.Me :: MatchView.Row).Id == "me" and hud.Rows[1].IsMe ~= hud.Rows[2].IsMe)
	expect("HUD: wind text and a normalised arrow angle", hud.WindText == Format.mph(snap.Wind.Mph) and hud.WindRotationDeg > -180 and hud.WindRotationDeg <= 180)
	expect("windRotation: tailwind 0, from-the-left 90, headwind 180, aim offset shifts it", math.abs(MatchView.windRotation(0, 0, 100, 0, 0, 0)) < 1e-9 and math.abs(MatchView.windRotation(0, 0, 100, 0, 0, 90) - 90) < 1e-9 and math.abs(MatchView.windRotation(0, 0, 100, 0, 0, 180) - 180) < 1e-9 and math.abs(MatchView.windRotation(0, 0, 100, 0, 0, -90) + 90) < 1e-9 and math.abs(MatchView.windRotation(0, 0, 100, 0, 20, 90) - 70) < 1e-9)
	expect("windRotation follows the pin direction (pin straight +Z, wind +Z = tailwind)", math.abs(MatchView.windRotation(0, 0, 0, 100, 0, 90)) < 1e-9)
	expect("windRotation wraps into (-180, 180]", math.abs(MatchView.windRotation(0, 0, 100, 0, 0, 270) + 90) < 1e-9 and math.abs(MatchView.windRotation(0, 0, 100, 0, 0, 359) + 1) < 1e-9)

	local forfeiter = if active == "me" then "rival" else "me"
	engine.forfeit(forfeiter, 20)
	local finalSnap = engine.snapshot(20)
	local hudDone = MatchView.hud(finalSnap, "me", statsFor)
	expect("HUD after the match: banner says complete and it is nobody's turn", hudDone.Banner == "MATCH COMPLETE" and not hudDone.IsMyTurn)
	local summaryMe = MatchView.summary(finalSnap, "me")
	local summaryRival = MatchView.summary(finalSnap, "rival")
	expect("Summary: the player who didn't forfeit sees VICTORY, the other DEFEAT", (forfeiter == "rival") == summaryMe.Won and summaryMe.Won ~= summaryRival.Won and ((summaryMe.Won and summaryMe.Title == "VICTORY") or (not summaryMe.Won and summaryMe.Title == "DEFEAT")))
	expect("Summary lists forfeiters last", summaryMe.Rows[#summaryMe.Rows].Forfeited and summaryMe.Reason == "forfeit")
	local drawEngine = MatchEngine.new({ IntroSeconds = 0, Players = specs, Holes = { CourseDatabase.hole(5) }, Seed = 1, Now = 0 })
	local tD = 0.0
	local guardD = 0
	while not drawEngine.isFinished() and guardD < 400 do
		guardD += 1
		tD += 30
		drawEngine.tick(tD) -- both players only ever time out
	end
	local timeoutSummary = MatchView.summary(drawEngine.snapshot(tD), "me")
	expect("Summary of a finished match always has a title and rows", timeoutSummary.Title ~= "" and #timeoutSummary.Rows == 2)
end


-- Quests ------------------------------------------------------------------------------------
print("-- quests")
do
	local DAY = 86400
	-- Known dates: 2026-01-05 00:00 UTC is a Monday (unix 1767571200).
	local monday = 1767571200
	expect("dayIndex is whole days since the epoch", QuestEngine.dayIndex(DAY * 100) == 100 and QuestEngine.dayIndex(DAY * 100 - 1) == 99)
	expect("Weeks start on Monday: the index changes exactly at Monday 00:00 UTC", QuestEngine.weekIndex(monday) == QuestEngine.weekIndex(monday - 1) + 1 and QuestEngine.weekIndex(monday + 6 * DAY + 86399) == QuestEngine.weekIndex(monday))
	local wed = monday + 2 * DAY + 5000
	local weeklyReset = QuestEngine.resetsAt("Weekly", wed) :: number
	expect("Weekly reset is the next Monday midnight; daily reset is the next UTC midnight", (weeklyReset / DAY + 3) % 7 == 0 and weeklyReset > wed and weeklyReset - wed <= 7 * DAY and QuestEngine.resetsAt("Daily", wed) == (QuestEngine.dayIndex(wed) + 1) * DAY and QuestEngine.resetsAt("Lifetime", wed) == nil)

	local ids: { [string]: boolean } = {}
	local dupFree = true
	for _, def in QuestDatabase.All do
		if ids[def.Id] then
			dupFree = false
		end
		ids[def.Id] = true
	end
	expect("Quest ids are unique; pools are big enough to rotate", dupFree and #QuestDatabase.Pools.Daily >= 10 and #QuestDatabase.Pools.Weekly >= 6 and #QuestDatabase.Pools.Lifetime >= 8)
	expect("QuestDatabase.get rejects bad ids", QuestDatabase.get("d_holes_10") ~= nil and QuestDatabase.get("nope") == nil and QuestDatabase.get(5) == nil)

	local a = ProfileTemplate.new(0)
	local b = ProfileTemplate.new(0)
	local viewsA = QuestEngine.list(a, wed)
	QuestEngine.list(b, wed + 3000) -- later the same day
	local function idList(data: ProfileTemplate.ProfileData, period: string): string
		local state = (data.Quests :: any)[period]
		return table.concat(state.Ids, ",")
	end
	local dailyIds = (a.Quests :: any).Daily.Ids
	local distinct = {}
	for _, id in dailyIds do
		distinct[id] = true
	end
	local distinctCount = 0
	for _ in distinct do
		distinctCount += 1
	end
	expect("A day has 5 distinct daily quests and a week 3 weekly quests", #dailyIds == 5 and distinctCount == 5 and #(a.Quests :: any).Weekly.Ids == 3 and #viewsA == 3 and viewsA[1].Period == "Daily" and viewsA[2].Period == "Weekly" and viewsA[3].Period == "Lifetime")
	expect("Everyone gets the same quests on the same day (and rejoining can't reroll them)", idList(a, "Daily") == idList(b, "Daily") and idList(a, "Weekly") == idList(b, "Weekly"))
	local before = idList(a, "Daily")
	QuestEngine.list(a, wed + 100)
	expect("Quests stay put while the day lasts", idList(a, "Daily") == before)
	local differs = false
	for offset = 1, 10 do
		local other = ProfileTemplate.new(0)
		QuestEngine.list(other, wed + offset * DAY)
		if idList(other, "Daily") ~= before then
			differs = true
		end
	end
	expect("Different days draw different daily sets", differs)
	expect("Lifetime quests are all listed", #viewsA[3].Quests == #QuestDatabase.Pools.Lifetime and #viewsA[1].Quests == 5)

	-- Progress, claiming ---------------------------------------------------------------------------
	local p = ProfileTemplate.new(0)
	p.Coins = 0
	local periods = QuestEngine.list(p, wed)
	local daily = periods[1].Quests[1]
	local def = QuestDatabase.get(daily.Id) :: QuestDatabase.QuestDef
	expect("A fresh quest starts at 0 progress, incomplete, unclaimed", daily.Progress == 0 and not daily.Complete and not daily.Claimed)
	local _, whyEarly = QuestEngine.claim(p, daily.Id, wed)
	expect("Claiming an unfinished quest is refused", whyEarly == "not_complete")
	;(p.Stats :: any)[def.Stat] += def.Target - 1
	local almost = QuestEngine.list(p, wed)[1].Quests[1]
	expect("Progress follows the stat counter, one short is not complete", almost.Progress == def.Target - 1 and not almost.Complete)
	;(p.Stats :: any)[def.Stat] += 5
	local done = QuestEngine.list(p, wed)[1].Quests[1]
	expect("Progress is capped at the target for display; quest is complete", done.Progress == done.Target and done.Complete)
	expect("claimable() counts finished unclaimed quests (>=1)", QuestEngine.claimable(p, wed) >= 1)
	local coinsBefore, gemsBefore, earnedBefore = p.Coins, p.Gems, p.Stats.TotalCoinsEarned
	local okClaim, _, reward = QuestEngine.claim(p, daily.Id, wed)
	expect("Claiming pays exactly the quest's reward", okClaim and reward ~= nil and p.Coins - coinsBefore == (def.Reward.Coins or 0) and p.Gems - gemsBefore == (def.Reward.Gems or 0))
	expect("Quest rewards do not count as 'coins earned' (no quest feedback loop)", p.Stats.TotalCoinsEarned == earnedBefore)
	local _, whyTwice = QuestEngine.claim(p, daily.Id, wed)
	expect("A quest can only be claimed once", whyTwice == "already_claimed" and QuestEngine.list(p, wed)[1].Quests[1].Claimed)
	local _, whyUnknown = QuestEngine.claim(p, "nope", wed)
	local _, whyNil = QuestEngine.claim(p, nil, wed)
	expect("Unknown / nil quest ids are refused", whyUnknown == "unknown_quest" and whyNil == "unknown_quest")
	local inactive: string? = nil
	for _, candidate in QuestDatabase.Pools.Daily do
		if table.find((p.Quests :: any).Daily.Ids, candidate.Id) == nil and inactive == nil then
			inactive = candidate.Id
		end
	end
	local snapshotInactive = TableUtil.deepCopy(p)
	local _, whyInactive = QuestEngine.claim(p, inactive, wed)
	expect("A daily quest that isn't today's can't be claimed, and nothing changes", whyInactive == "not_active" and p.Coins == snapshotInactive.Coins)

	-- Rollover: new day -> new quests, nothing claimed, progress restarts from the new baseline.
	local carry = ProfileTemplate.new(0)
	QuestEngine.list(carry, wed)
	local carryDef = QuestDatabase.get((carry.Quests :: any).Daily.Ids[1]) :: QuestDatabase.QuestDef
	;(carry.Stats :: any)[carryDef.Stat] += carryDef.Target
	QuestEngine.claim(carry, carryDef.Id, wed)
	local statBefore = (carry.Stats :: any)[carryDef.Stat]
	local nextDay = QuestEngine.list(carry, wed + DAY)
	local anyClaimed, anyProgressFromYesterday = false, false
	for _, view in nextDay[1].Quests do
		if view.Claimed then
			anyClaimed = true
		end
		local viewDef = QuestDatabase.get(view.Id) :: QuestDatabase.QuestDef
		if view.Progress > 0 and (carry.Stats :: any)[viewDef.Stat] == statBefore then
			anyProgressFromYesterday = true
		end
	end
	expect("Next day: claims are cleared and yesterday's progress doesn't carry over", not anyClaimed and not anyProgressFromYesterday and (carry.Quests :: any).Daily.Index == QuestEngine.dayIndex(wed + DAY))

	-- Lifetime and Value quests ---------------------------------------------------------------------
	local lt = ProfileTemplate.new(0)
	lt.Coins = 0
	local ace = QuestDatabase.get("l_ace") :: QuestDatabase.QuestDef
	lt.Stats.HolesInOne = 1
	local okAce, _, aceReward = QuestEngine.claim(lt, "l_ace", wed)
	expect("Lifetime quest: uses the lifetime counter and pays gems", okAce and aceReward ~= nil and lt.Gems == (ace.Reward.Gems or 0))
	expect("Lifetime quests stay claimed across days", select(2, QuestEngine.claim(lt, "l_ace", wed + 40 * DAY)) == "already_claimed")
	local drive = ProfileTemplate.new(0)
	drive.Stats.LongestDriveYds = 299
	local notYet = select(2, QuestEngine.claim(drive, "l_drive_300", wed))
	drive.Stats.LongestDriveYds = 310
	local nowOk = QuestEngine.claim(drive, "l_drive_300", wed)
	expect("Value quest (longest drive) compares the absolute stat", notYet == "not_complete" and nowOk)
	local early = ProfileTemplate.new(0)
	early.Stats.Wins = 5 -- wins earned BEFORE the first quest listing today
	local winComplete = false
	for _, view in QuestEngine.list(early, wed)[3].Quests do
		if view.Id == "l_first_win" then
			winComplete = view.Complete
		end
	end
	expect("Lifetime Delta quests count from zero, not from a baseline", winComplete)
	local grants = ProfileTemplate.new(0)
	grants.Coins = Config.Economy.MaxCoins
	grants.Stats.HolesPlayed = 100
	expect("A reward at the coin cap still claims without error", QuestEngine.claim(grants, "l_holes_100", wed))
	expect("Quest rewards clamp at MaxCoins", grants.Coins == Config.Economy.MaxCoins)
end

-- Shop view -------------------------------------------------------------------------------------
print("-- lobby views")
local viewNow = 1_750_000_000
do
	local profile = ProfileTemplate.new(0)
	profile.Coins = 100000
	profile.Gems = 5000
	local offers: { ShopView.Offer } = {}
	for _, offer in ShopRotation.offersFor(ShopRotation.indexAt(viewNow)) do
		table.insert(offers, { ItemId = offer.ItemId, Rarity = offer.Rarity, Price = offer.Price, Purchased = false })
	end
	local counts = ShopView.tabCounts(offers)
	local total = 0
	for _, tab in ShopView.Tabs do
		total += counts[tab.Id] or 0
	end
	expect("Shop tabs partition today's offers exactly (counts add up to the offer count)", total == #offers)
	local tabsOk, sortedOk = true, true
	for _, tab in ShopView.Tabs do
		local cards = ShopView.cards(offers, profile, tab.Id, nil)
		if #cards ~= (counts[tab.Id] or 0) then
			tabsOk = false
		end
		for i, card in cards do
			local item = ItemDatabase.get(card.ItemId) :: ItemDatabase.Item
			if ShopView.tabOf(item) ~= tab.Id then
				tabsOk = false
			end
			if i > 1 and Rarity.Info[cards[i - 1].Rarity].Tier > Rarity.Info[card.Rarity].Tier then
				sortedOk = false
			end
		end
	end
	expect("Each tab shows only its own items, sorted common -> mythical", tabsOk and sortedOk)
	local skinCards = ShopView.cards(offers, profile, "ClubSkin", "All")
	local allSkinCount = #skinCards
	local filteredTotal = 0
	local filterOk = true
	for _, filter in ShopView.ClassFilters do
		if filter.Id ~= "All" then
			local filtered = ShopView.cards(offers, profile, "ClubSkin", filter.Id)
			filteredTotal += #filtered
			for _, card in filtered do
				if (ItemDatabase.get(card.ItemId) :: ItemDatabase.Item).Slot ~= filter.Id then
					filterOk = false
				end
			end
		end
	end
	expect("Club-class filters partition the skin tab", filterOk and filteredTotal == allSkinCount)
	local broke = ProfileTemplate.new(0)
	broke.Coins, broke.Gems = 0, 0
	local anyBuyable = false
	for _, tab in ShopView.Tabs do
		for _, card in ShopView.cards(offers, broke, tab.Id, nil) do
			if card.Buyable then
				anyBuyable = true
			end
		end
	end
	expect("With no coins or gems nothing is buyable", not anyBuyable)
	local coinsOnly = ProfileTemplate.new(0)
	coinsOnly.Coins, coinsOnly.Gems = 1e9, 0
	local mythicBuyable, mythicSeen = false, false
	for _, tab in ShopView.Tabs do
		for _, card in ShopView.cards(offers, coinsOnly, tab.Id, nil) do
			if card.Rarity == "Mythical" then
				mythicSeen = true
				if card.Buyable or card.Currency ~= "Gems" then
					mythicBuyable = true
				end
			end
		end
	end
	expect("Mythical cards are priced in gems and aren't buyable with coins alone", mythicSeen and not mythicBuyable)
	local purchasedOffers = table.clone(offers)
	purchasedOffers[1] = { ItemId = offers[1].ItemId, Rarity = offers[1].Rarity, Price = offers[1].Price, Purchased = true }
	local firstItem = ItemDatabase.get(offers[1].ItemId) :: ItemDatabase.Item
	local boughtCards = ShopView.cards(purchasedOffers, profile, ShopView.tabOf(firstItem), nil)
	local flagged = false
	for _, card in boughtCards do
		if card.ItemId == offers[1].ItemId and card.Purchased and not card.Buyable and card.CanAfford then
			flagged = true
		end
	end
	expect("A purchased offer is flagged and no longer buyable even if affordable", flagged)
	expect("Countdown text", ShopView.countdown(1000 + 8109, 1000) == "REFRESHES IN 02:15:09")
	expect("Slot labels are readable", ShopView.slotLabel(ItemDatabase.get("skin_crimson_driver") :: ItemDatabase.Item) == "Driver Skin" and ShopView.slotLabel(ItemDatabase.get("emote_trophy") :: ItemDatabase.Item) == "Victory Emote")
end

-- Loadout view ------------------------------------------------------------------------------------
do
	local profile = ProfileTemplate.new(0)
	profile.Coins = 2500
	local rows = LoadoutView.slots(profile, "SI")
	local selectedCount, ovrOk = 0, true
	for _, row in rows do
		if row.Selected then
			selectedCount += 1
		end
		if row.Ovr ~= ClubDatabase.overall({ Power = 55, Accuracy = 60, Spin = 65 }) then
			ovrOk = false
		end
	end
	expect("Loadout: 6 bag rows, exactly one selected, starter OVR everywhere", #rows == 6 and selectedCount == 1 and ovrOk and rows[1].Label == "DR" and rows[6].Label == "PT")
	local detail = LoadoutView.detail(profile, "tatermade_swift_dr") :: LoadoutView.Detail
	expect("Detail: three stat rows, first upgrade costs 500 and is allowed", #detail.Stats == 3 and detail.Stats[1].Stat == "Power" and detail.Stats[1].UpgradeCost == 500 and detail.Stats[1].CanUpgrade and detail.Stats[1].Value == 55 and detail.Stats[1].MaxValue == 75)
	profile.Coins = 100
	local poor = (LoadoutView.detail(profile, "tatermade_swift_dr") :: LoadoutView.Detail).Stats[1]
	expect("Detail: when short, the button explains how many coins are missing", not poor.CanUpgrade and poor.Reason == "Need 400 more coins")
	profile.Coins = 1e9
	for _ = 1, Config.Clubs.MaxUpgradeLevel do
		ProfileOps.upgradeClub(profile, "tatermade_swift_dr", "Power")
	end
	local maxed = (LoadoutView.detail(profile, "tatermade_swift_dr") :: LoadoutView.Detail).Stats[1]
	expect("Detail: a maxed stat shows Max level and no cost", maxed.Reason == "Max level" and maxed.UpgradeCost == nil and not maxed.CanUpgrade and maxed.Level == Config.Clubs.MaxUpgradeLevel and maxed.Value == 75)
	expect("Detail agrees with the server's stats (Distance 75 after 10 upgrades)", (ProfileOps.clubStats(profile, "tatermade_swift_dr") :: ClubDatabase.Stats).Power == 75)
	expect("Detail of an unknown club is nil", LoadoutView.detail(profile, "ghost") == nil)

	local fresh = ProfileTemplate.new(0)
	fresh.Coins = 20000
	local ownedDrivers = LoadoutView.ownedFor(fresh, "DR")
	expect("ownedFor: only the starter driver at first, flagged equipped", #ownedDrivers == 1 and ownedDrivers[1].ClubId == "tatermade_swift_dr" and ownedDrivers[1].Equipped)
	local shopDrivers = LoadoutView.shopFor(fresh, "DR")
	local priceSorted, noStarters = true, true
	for i, club in shopDrivers do
		if i > 1 and shopDrivers[i - 1].Price > club.Price then
			priceSorted = false
		end
		if (ClubDatabase.get(club.ClubId) :: ClubDatabase.Club).Starter then
			noStarters = false
		end
	end
	expect("shopFor: unowned non-starter drivers, cheapest first, with affordability", #shopDrivers == 4 and priceSorted and noStarters and shopDrivers[1].CanAfford and not shopDrivers[4].CanAfford)
	ProfileOps.buyClub(fresh, shopDrivers[1].ClubId)
	expect("Buying a club moves it from the shop list to the owned list", #LoadoutView.shopFor(fresh, "DR") == 3 and #LoadoutView.ownedFor(fresh, "DR") == 2)
	local skins = LoadoutView.skinsFor(fresh, "Driver")
	local lockedCount, equippedCount, ownedCount = 0, 0, 0
	for _, skin in skins do
		if not skin.Owned then
			lockedCount += 1
		end
		if skin.Equipped then
			equippedCount += 1
		end
		if skin.Owned then
			ownedCount += 1
		end
	end
	expect("skinsFor: all 13 driver skins listed; only the starter is owned and equipped", #skins == 13 and ownedCount == 1 and equippedCount == 1 and lockedCount == 12)
	ProfileOps.grantItem(fresh, "skin_crimson_driver", 1)
	ProfileOps.equipItem(fresh, "skin_crimson_driver")
	local after = LoadoutView.skinsFor(fresh, "Driver")
	local crimsonOk = false
	for _, skin in after do
		if skin.ItemId == "skin_crimson_driver" and skin.Owned and skin.Equipped then
			crimsonOk = true
		end
	end
	expect("A newly equipped skin shows owned + equipped", crimsonOk)
	expect("Player OVR is shown from the profile", LoadoutView.playerOvr(fresh) == ProfileOps.playerOvr(fresh))
end

-- Cases view ----------------------------------------------------------------------------------------
do
	local profile = ProfileTemplate.new(0)
	profile.Coins = 12000
	local cards = CasesView.cards(profile)
	local oddsOk = true
	for _, card in cards do
		local sum = 0
		for _, odds in card.Odds do
			sum += odds.Percent
		end
		if math.abs(sum - 100) > 1e-9 or #card.Odds ~= 6 then
			oddsOk = false
		end
	end
	expect("Three case cards; each odds table has six rarities summing to 100%", #cards == 3 and oddsOk and cards[1].Odds[1].Percent == 45 and cards[1].Odds[6].Percent == 1)
	expect("maxAffordable = floor(coins / price), capped at 10 per opening", cards[1].MaxAffordable == 2 and cards[3].MaxAffordable == 4)
	profile.Coins = 1e9
	expect("maxAffordable is capped at the per-opening limit", CasesView.maxAffordable(profile, "club_skins_case") == Config.Economy.MaxCasesPerOpen)
	profile.Coins = 9999
	local okTwo = CasesView.canOpen(profile, "club_skins_case", 1)
	local noTwo, whyTwo = CasesView.canOpen(profile, "club_skins_case", 2)
	local zero, whyZero = CasesView.canOpen(profile, "club_skins_case", 0)
	local eleven = CasesView.canOpen(profile, "club_skins_case", 11)
	expect("canOpen: affordability and count limits", okTwo and not noTwo and whyTwo == "Not enough coins" and not zero and whyZero == "Pick 1 to 10 cases" and not eleven)
	expect("total() multiplies the price", CasesView.total("animations_case", 3).Amount == 12000)

	-- Results of a real opening, and what Sell All does.
	local player = ProfileTemplate.new(0)
	player.Coins = 1e8
	local rngC = Prng.new(99)
	local reply = Economy.openCases(player, "club_skins_case", 10, { Now = viewNow, Rng = rngC.next })
	local drops = reply.Drops :: { Economy.Drop }
	local results = CasesView.results(drops, player)
	expect("Results: one card per drop, in drop order", #results.Cards == #drops and results.Cards[1].ItemId == drops[1].ItemId)
	local expectedValue = 0
	local expectedIds = 0
	local perId: { [string]: number } = {}
	for _, drop in drops do
		perId[drop.ItemId] = (perId[drop.ItemId] or 0) + 1
	end
	for id, n in perId do
		local spare = math.min(n, ProfileOps.spareCount(player, id))
		expectedIds += spare
		expectedValue += spare * Rarity.Info[(ItemDatabase.get(id) :: ItemDatabase.Item).Rarity].SellValue
	end
	expect("Sell All covers exactly the spare copies, at the rarity sell values", #results.SellIds == expectedIds and results.SellValue == expectedValue)
	local sold = Economy.sellItems(player, results.SellIds, { Now = viewNow, Rng = rngC.next })
	expect("The server accepts the client's Sell All list and pays the previewed amount", (#results.SellIds == 0 or sold.ok) and (#results.SellIds == 0 or sold.CoinsGained == results.SellValue))
	local starterOnly = CasesView.results({ { ItemId = "skin_midnight_driver", Rarity = "Common", IsNew = false } }, ProfileTemplate.new(0))
	expect("A starter item is never offered for sale", #starterOnly.SellIds == 0 and starterOnly.SellValue == 0)
	local noItem = CasesView.results({ { ItemId = "ghost", Rarity = "Common", IsNew = false } }, ProfileTemplate.new(0))
	expect("Unknown drops are skipped safely", #noItem.Cards == 0)

	-- Roulette strip
	local final = "skin_nebula_driver"
	local strip = CasesView.strip("club_skins_case", final, 40, 33, 1234)
	local stripOk = #strip == 40 and strip[33] == final
	for i, id in strip do
		local item = ItemDatabase.get(id)
		if item == nil or (i ~= 33 and item.Category ~= "ClubSkin") then
			stripOk = false
		end
	end
	local again = CasesView.strip("club_skins_case", final, 40, 33, 1234)
	local sameStrip = true
	for i, id in strip do
		if again[i] ~= id then
			sameStrip = false
		end
	end
	local common = 0
	for i, id in strip do
		if i ~= 33 and (ItemDatabase.get(id) :: ItemDatabase.Item).Rarity == "Common" then
			common += 1
		end
	end
	expect("Roulette strip: right length, real item at the stop index, only the case's items, deterministic", stripOk and sameStrip)
	expect("Roulette filler mostly looks like the real odds (commons are the biggest group)", common >= 8)
end

-- Trade-up view ----------------------------------------------------------------------------------------
do
	local profile = ProfileTemplate.new(0)
	ProfileOps.grantItem(profile, "skin_crimson_driver", 6) -- Rare skins
	ProfileOps.grantItem(profile, "skin_ocean_longiron", 2) -- Rare skins, another slot
	ProfileOps.grantItem(profile, "skin_slate_fairwaywood", 1) -- Common skin
	ProfileOps.grantItem(profile, "skin_nebula_driver", 3) -- Mythical (can't trade up)
	ProfileOps.grantItem(profile, "swing_windup", 5) -- Rare animation
	ProfileOps.equipItem(profile, "skin_crimson_driver") -- one copy is locked in
	local inventory = TradeUpView.inventory(profile, {})
	local byId: { [string]: TradeUpView.Entry } = {}
	local sorted = true
	for i, entry in inventory do
		byId[entry.ItemId] = entry
		if i > 1 and Rarity.Info[inventory[i - 1].Rarity].Tier < Rarity.Info[entry.Rarity].Tier then
			sorted = false
		end
	end
	expect("Inventory: spare copies only (equipped copy held back), no Mythical, no starters, highest rarity first", byId.skin_crimson_driver.Spare == 5 and byId.skin_nebula_driver == nil and byId.skin_midnight_driver == nil and sorted)

	local sel: { string } = {}
	local okAdd = TradeUpView.canAdd(profile, sel, "skin_crimson_driver")
	sel = TradeUpView.add(profile, sel, "skin_crimson_driver")
	local _, whyRarity = TradeUpView.canAdd(profile, sel, "skin_slate_fairwaywood")
	local _, whyCategory = TradeUpView.canAdd(profile, sel, "swing_windup")
	local _, whyMythic = TradeUpView.canAdd(profile, {}, "skin_nebula_driver")
	local _, whyUnknown = TradeUpView.canAdd(profile, sel, "ghost")
	expect("canAdd: first pick ok; other rarity, other category, Mythical and unknown ids are refused with reasons", okAdd and whyRarity == "Add Rare items only" and string.find(whyCategory or "", "one item type") ~= nil and string.find(whyMythic or "", "Mythical") ~= nil and whyUnknown == "Unknown item")
	for _ = 1, 4 do
		sel = TradeUpView.add(profile, sel, "skin_crimson_driver")
	end
	expect("Five spare copies fill the contract", #sel == 5)
	local _, whyFull = TradeUpView.canAdd(profile, sel, "skin_crimson_driver")
	local overfilled = TradeUpView.add(profile, sel, "skin_crimson_driver")
	expect("A full contract refuses more and add() leaves it unchanged", whyFull == "The contract is full" and #overfilled == 5)
	local noSpare = { "skin_ocean_longiron", "skin_ocean_longiron" }
	local _, whySpare = TradeUpView.canAdd(profile, noSpare, "skin_ocean_longiron")
	expect("You can't add more copies than you have spare", whySpare == "The contract is full" or whySpare == "No spare copies left")
	local trimmed = TradeUpView.remove(sel, 5)
	expect("remove() returns a new, shorter selection; bad indexes change nothing", #trimmed == 4 and #sel == 5 and #TradeUpView.remove(sel, 9) == 5 and #TradeUpView.remove(sel, 0) == 5)
	local empty = TradeUpView.state({})
	local partial = TradeUpView.state({ "skin_crimson_driver", "skin_crimson_driver" })
	local ready = TradeUpView.state(sel)
	expect("State: empty prompt, partial progress with remaining count, ready summary naming the next rarity", not empty.Valid and string.find(empty.Message, "Pick 5") ~= nil and not partial.Valid and string.find(partial.Message, "2 / 5") ~= nil and string.find(partial.Message, "add 3 more Rare items") ~= nil and ready.Valid and ready.NextRarity == "Unique" and string.find(ready.Message, "1 Unique") ~= nil)

	-- The UI's notion of "valid" must match the server's: every selection the view calls valid
	-- must be accepted by Economy.tradeUp, for every tradable rarity.
	local agree = true
	local tested = 0
	local starters: { [string]: string } = { Common = "skin_slate_driver", Uncommon = "skin_fairway_driver", Rare = "skin_crimson_driver", Unique = "skin_volt_driver", Legendary = "skin_gold_rush_driver" }
	for _, id in starters do
		local p = ProfileTemplate.new(0)
		ProfileOps.grantItem(p, id, 6)
		ProfileOps.equipItem(p, id)
		local pick: { string } = {}
		for _ = 1, 5 do
			pick = TradeUpView.add(p, pick, id)
		end
		local viewValid = TradeUpView.state(pick).Valid
		local serverReply = Economy.tradeUp(p, pick, { Now = viewNow, Rng = Prng.new(5).next })
		tested += 1
		if viewValid ~= serverReply.ok then
			agree = false
		end
	end
	expect(`UI trade-up validity matches the server for all {tested} tradable rarities`, agree and tested == 5)
	-- ...and the view must refuse exactly what the server refuses (equipped copy).
	local p2 = ProfileTemplate.new(0)
	ProfileOps.grantItem(p2, "skin_crimson_driver", 5)
	ProfileOps.equipItem(p2, "skin_crimson_driver")
	local greedy: { string } = {}
	for _ = 1, 5 do
		greedy = TradeUpView.add(p2, greedy, "skin_crimson_driver")
	end
	expect("With the equipped copy held back, the view only lets you add 4 (the server would refuse 5)", #greedy == 4 and not TradeUpView.state(greedy).Valid and not Economy.tradeUp(p2, { "skin_crimson_driver", "skin_crimson_driver", "skin_crimson_driver", "skin_crimson_driver", "skin_crimson_driver" }, { Now = viewNow, Rng = Prng.new(1).next }).ok)
end

-- Mode view ---------------------------------------------------------------------------------------------
do
	local profile = ProfileTemplate.new(0)
	profile.Coins = 600
	local leagues = ModeView.leagues(profile)
	expect("Four leagues in order with fee / payout text", #leagues == 4 and leagues[1].Id == "Rookie" and leagues[4].Id == "Champion" and leagues[4].FeeText == "10,000" and leagues[4].PayoutText == "25,000")
	expect("Affordability and shortfall follow the balance (600 coins: Rookie + Amateur yes, Pro no)", leagues[1].CanAfford and leagues[2].CanAfford and not leagues[3].CanAfford and leagues[3].Shortfall == 1900 and leagues[1].Shortfall == 0)
	local bots = ModeView.bots()
	expect("Three bot levels with rising OVR", #bots == 3 and bots[1].Difficulty == "Easy" and bots[3].Difficulty == "Hard" and bots[1].Ovr < bots[2].Ovr and bots[2].Ovr < bots[3].Ovr and bots[1].Blurb ~= "")
	expect("Queue text shows the wait", ModeView.queueText(75) == "SEARCHING FOR AN OPPONENT  1:15")
end

-- Lobby layout ----------------------------------------------------------------------------------------------
print("-- lobby layout")
do
	local layout = LobbyLayout.build()
	local finite, uniqueNames, names = true, true, {}
	for _, part in layout.Parts do
		for _, v in { part.X, part.Y, part.Z, part.SX, part.SY, part.SZ, part.YawDeg } do
			if v ~= v or math.abs(v) == math.huge then
				finite = false
			end
		end
		if part.SX <= 0 or part.SY <= 0 or part.SZ <= 0 or part.SX > 2048 or part.SZ > 2048 then
			finite = false
		end
		if names[part.Name] then
			uniqueNames = false
		end
		names[part.Name] = true
	end
	expect("Lobby parts are finite, sized within limits, and uniquely named", finite and uniqueNames and #layout.Parts > 100 and #layout.Parts < 800)
	-- Signs face the plaza centre (0, 40): front = (-sin yaw, -cos yaw).
	local facing = true
	for _, sign in layout.Signs do
		local yaw = math.rad(sign.YawDeg)
		local frontX, frontZ = -math.sin(yaw), -math.cos(yaw)
		if frontX * (0 - sign.X) + frontZ * (40 - sign.Z) <= 0 then
			facing = false
		end
	end
	expect("Every sign's front face looks toward the plaza", facing and #layout.Signs >= 2 and layout.Signs[1].Lines[1] == "PLAY" and layout.Signs[1].Lines[4] == "CUSTOMIZE" and layout.Signs[2].Lines[1] == "THE LINKS")
	-- The spawn must be standing room: above the ground, not inside any solid part.
	local spawn = layout.Spawn
	local blocked = false
	for _, part in layout.Parts do
		if part.CanCollide and part.Shape == "Block" and part.Name ~= "Ground" and math.abs(part.YawDeg) % 90 < 1e-6 then
			local yawQuarter = math.floor(math.abs(part.YawDeg) / 90 + 0.5) % 2 == 1
			local halfX, halfZ = (if yawQuarter then part.SZ else part.SX) / 2, (if yawQuarter then part.SX else part.SZ) / 2
			if math.abs(spawn.X - part.X) <= halfX and math.abs(spawn.Z - part.Z) <= halfZ and spawn.Y >= part.Y - part.SY / 2 and spawn.Y <= part.Y + part.SY / 2 + 6 then
				blocked = true
			end
		end
	end
	expect("The spawn point is standing room above the plaza, clear of solid parts", not blocked and spawn.Y > 0 and math.sqrt(spawn.X ^ 2 + (spawn.Z - 40) ^ 2) < LobbyLayout.PLAZA_RADIUS)
	local lamps = 0
	for _, part in layout.Parts do
		if string.sub(part.Name, 1, 9) == "LampGlobe" then
			lamps += 1
		end
	end
	expect("Each lamp globe has a real light (+ the range deck, the AFK cabana, the wheel stand and the spawn pad)", lamps == 8 and #layout.Lights == lamps + 4)
	local treesClear = true
	for _, part in layout.Parts do
		if string.sub(part.Name, 1, 9) == "TreeTrunk" then
			if (part.Z < -70 and math.abs(part.X) < 110) or math.sqrt((part.X - 150) ^ 2 + (part.Z - 70) ^ 2) < 45 then
				treesClear = false
			end
		end
	end
	expect("Trees keep clear of the clubhouse frontage and the practice green", treesClear)
	local again = LobbyLayout.build()
	local same = #again.Parts == #layout.Parts
	for i, part in layout.Parts do
		if same and (again.Parts[i].X ~= part.X or again.Parts[i].Name ~= part.Name) then
			same = false
		end
	end
	expect("The lobby is built identically every time", same)
	local inBounds = true
	for _, part in layout.Parts do
		local onPlate = math.abs(part.X) <= 460 and math.abs(part.Z) <= 460
		local onRange = part.X >= LobbyLayout.RANGE_FAR_X and part.X < -100 and math.abs(part.Z - RangeRules.ORIGIN.Z) <= 260
		if not onPlate and not onRange then
			inBounds = false
		end
	end
	expect("Everything sits on the ground plate (or the range field to the west)", inBounds)
end

print("-- club categories (ClubStats)")
do
	local labels = {}
	for _, category in ClubStats.Categories do
		table.insert(labels, category.Label)
	end
	expect("Exactly six categories in bag order: DR FW LI SI WG PT", table.concat(labels, " ") == "DR FW LI SI WG PT" and ClubDatabase.BagSlots == ClubStats.Categories)
	local descending = true
	for i = 2, 5 do
		if ClubStats.Categories[i].BaseCarryYds >= ClubStats.Categories[i - 1].BaseCarryYds then
			descending = false
		end
	end
	expect("Carries step down from Driver to Wedge; the putter has no carry", descending and ClubStats.get("PT") ~= nil and (ClubStats.get("PT") :: ClubStats.Category).BaseCarryYds == 0)
	expect("Unknown / legacy / junk labels are not categories", ClubStats.get("D") == nil and ClubStats.get("7i") == nil and ClubStats.get(5) == nil and ClubDatabase.getSlot({}) == nil)
	local everyClubFits = true
	for _, club in ClubDatabase.Ordered do
		if ClubStats.get(club.SlotLabel) == nil or (ClubStats.get(club.SlotLabel) :: ClubStats.Category).Class ~= club.Class then
			everyClubFits = false
		end
	end
	expect("Every club in the catalogue belongs to one of the six categories", everyClubFits and #ItemDatabase.ClubClasses == 6)

	local base = ClubStats.baseline()
	local calibrated = true
	for _, category in ClubStats.Categories do
		if category.Class ~= "Putter" then
			local resolved = SwingMath.resolveShot({ Slot = category, Stats = base, Power = 100, AccuracyOffset = 0, Lie = "Fairway" }, ShotPhysics.flatTerrain("Fairway"), nil)
			if math.abs(resolved.Result.CarryYds - category.BaseCarryYds) > category.BaseCarryYds * 0.02 then
				calibrated = false
				print(`  {category.Label}: carry {resolved.Result.CarryYds} vs {category.BaseCarryYds}`)
			end
		end
	end
	expect("Each category's full-power carry at baseline stats matches its BaseCarryYds (2%)", calibrated)

	local function onGreen(spin: number): ShotPhysics.ShotResult
		local stats = { Power = 50, Accuracy = 50, Spin = spin }
		return SwingMath.resolveShot({ Slot = ClubStats.get("SI") :: ClubStats.Category, Stats = stats, Power = 100, AccuracyOffset = 0, Lie = "Fairway" }, ShotPhysics.flatTerrain("Green"), nil).Result
	end
	local lowSpin, highSpin = onGreen(10), onGreen(95)
	expect("Spin never changes carry...", math.abs(lowSpin.CarryYds - highSpin.CarryYds) < 1e-6)
	expect("...but a high-Spin club stops the ball faster on the green", highSpin.RollYds < lowSpin.RollYds - 1)
	expect("Spin softens a bad lie's accuracy penalty; Power raises ball speed", ClubStats.liePenalty("Sand", 90) < ClubStats.liePenalty("Sand", 10) and ClubStats.speedFactor(90) > ClubStats.speedFactor(50) and ClubStats.gripFactor(50) == 1)
	expect("Stat info covers Power, Accuracy and Spin", #ClubStats.StatInfo == 3 and ClubStats.StatInfo[1].Id == "Power" and ClubStats.StatInfo[3].Id == "Spin")
end

print("-- profile migration v1 -> v2")
do
	expect("Legacy club ids map to their category", ClubDatabase.migrateLegacyId("pong_gale_3w") == "pong_gale_fw" and ClubDatabase.migrateLegacyId("tatermade_swift_d") == "tatermade_swift_dr" and ClubDatabase.migrateLegacyId("titleless_tour_8i") == "titleless_tour_si" and ClubDatabase.migrateLegacyId("pong_zip_lw") == "pong_zip_wg")
	expect("Legacy ids with no v2 club (or junk) map to nil", ClubDatabase.migrateLegacyId("pong_laser_d") == nil and ClubDatabase.migrateLegacyId("nonsense") == nil and ClubDatabase.migrateLegacyId(7) == nil)

	local v1: any = {
		SchemaVersion = 1, Coins = 5000, Gems = 3,
		OwnedItems = { skin_crimson_iron = 2, skin_ocean_wood = 1, skin_midnight_driver = 1 },
		EquippedItems = { Iron = "skin_crimson_iron", Wood = "skin_ocean_wood", Driver = "skin_midnight_driver" },
		OwnedClubs = {
			tatermade_swift_d = true, tatermade_swift_3w = true, tatermade_swift_5w = true, tatermade_swift_7i = true, tatermade_swift_pt = true,
			pong_gale_3w = true, pong_gale_5w = true, titleless_tour_5i = true, titleless_tour_8i = true,
		},
		EquippedClubs = {
			D = "tatermade_swift_d", ["3W"] = "pong_gale_3w", ["5W"] = "tatermade_swift_5w", ["5i"] = "titleless_tour_5i",
			["7i"] = "tatermade_swift_7i", ["8i"] = "titleless_tour_8i", PT = "tatermade_swift_pt",
		},
		ClubUpgrades = {
			pong_gale_3w = { Distance = 3, Accuracy = 1, Forgiveness = 2 },
			pong_gale_5w = { Distance = 5, Accuracy = 0, Forgiveness = 1 },
		},
		Stats = { Wins = 4 },
		Quests = {}, Shop = { Rotation = 0, Purchased = {} }, Meta = { CreatedAt = 1, Sessions = 3 },
	}
	local migrated, why = ProfileTemplate.prepare(v1, 100)
	expect("A v1 profile loads as v2", migrated ~= nil and why == nil and (migrated :: any).SchemaVersion == 2)
	if migrated then
		expect("Owned clubs become their category clubs (merged ones kept once)", migrated.OwnedClubs.pong_gale_fw and migrated.OwnedClubs.titleless_tour_li and migrated.OwnedClubs.titleless_tour_si and migrated.OwnedClubs.pong_gale_3w == nil)
		expect("The main legacy slot decides a merged category's club (3W->FW, 5i->LI, 7i->SI)", migrated.EquippedClubs.FW == "pong_gale_fw" and migrated.EquippedClubs.LI == "titleless_tour_li" and migrated.EquippedClubs.SI == "tatermade_swift_si" and migrated.EquippedClubs.DR == "tatermade_swift_dr" and migrated.EquippedClubs.WG == "tatermade_swift_wg")
		local gale = migrated.ClubUpgrades.pong_gale_fw
		expect("Upgrade levels renamed (Distance->Power, Forgiveness->Spin), best level kept on merge", gale ~= nil and gale.Power == 5 and gale.Accuracy == 1 and gale.Spin == 2)
		expect("Iron skins go to BOTH iron slots; Wood skins to Fairway Wood", migrated.OwnedItems.skin_crimson_longiron == 2 and migrated.OwnedItems.skin_crimson_shortiron == 2 and migrated.OwnedItems.skin_ocean_fairwaywood == 1 and migrated.OwnedItems.skin_crimson_iron == nil)
		expect("Equipped legacy skins move to the new slots", migrated.EquippedItems.LongIron == "skin_crimson_longiron" and migrated.EquippedItems.ShortIron == "skin_crimson_shortiron" and migrated.EquippedItems.FairwayWood == "skin_ocean_fairwaywood" and migrated.EquippedItems.Iron == nil)
		expect("Balances, stats and the new Earnings section survive / appear", migrated.Coins == 5000 and migrated.Gems == 3 and migrated.Stats.Wins == 4 and migrated.Earnings.Day == 0 and migrated.Earnings.Range == 0)
	end
	local junk, junkWhy = ProfileTemplate.prepare({ SchemaVersion = 1, OwnedClubs = 5, EquippedClubs = "x", ClubUpgrades = { a = 1 }, OwnedItems = false, EquippedItems = { Iron = 3 } }, 0)
	local junkOk = junk ~= nil and junkWhy == nil
	if junk then
		for _, category in ClubStats.Categories do
			if junk.EquippedClubs[category.Label] == nil then
				junkOk = false
			end
		end
	end
	expect("A garbage v1 profile still migrates into a full, valid starter bag", junkOk)
	expect("A v3 profile is refused as too new", select(2, ProfileTemplate.prepare({ SchemaVersion = 3 }, 0)) == "too_new")
end

print("-- match flow: intro, swing lead, auto-putter")
do
	local mid: ClubDatabase.Stats = { Power = 70, Accuracy = 70, Spin = 70 }
	local function statsFor(_label: string): ClubDatabase.Stats
		return mid
	end
	local specs: { MatchEngine.PlayerSpec } = {
		{ Id = "H1", Name = "One", IsBot = false, StatsFor = statsFor },
		{ Id = "B1", Name = "Bot", IsBot = true, StatsFor = statsFor },
	}
	local intro = Config.Match.HoleIntroSeconds
	local e = MatchEngine.new({ Players = specs, Holes = CourseDatabase.sequence(1, 2), Seed = 11, Now = 0 })
	local first = e.snapshot(0)
	expect("Each hole opens with the Intro phase (first player already shown)", e.phase() == "Intro" and first.ActiveId ~= nil and math.abs(first.IntroSecondsLeft - intro) < 1e-9 and first.TurnSecondsLeft == 0)
	local ok, why = e.submitSwing("H1", 80, 0, 3)
	local botOk = BotBrain.play(e, "B1", "Hard", function(): number
		return 0.5
	end, 3)
	local noShots = true
	for _, event in e.drainEvents() do
		if event.Type == "Shot" then
			noShots = false
		end
	end
	expect("Nobody can swing during the intro - humans or bots", not ok and why == "not_your_turn" and not botOk and noShots)
	e.tick(intro - 0.01)
	local still = e.phase() == "Intro"
	e.tick(intro)
	local opened = e.snapshot(intro)
	expect("The turn opens when the intro ends, with a full turn clock", still and e.phase() == "Swing" and math.abs(opened.TurnSecondsLeft - Config.Match.TurnSeconds) < 1e-9)
	local active = e.activeId() :: string
	local shotOk
	if active == "H1" then
		shotOk = e.submitSwing("H1", 80, 0, intro + 5)
	else
		shotOk = e.submitBotSwing("B1", "DR", 0, 80, 0, intro + 5)
	end
	local shot: any = nil
	for _, event in e.drainEvents() do
		if event.Type == "Shot" then
			shot = event.Data
		end
	end
	local lead = Config.Match.SwingLeadSeconds
	expect("A shot carries the swing lead (ImpactDelay) and power for the clients' swing animation", shotOk and shot ~= nil and shot.ImpactDelay == lead and shot.Power == 80)
	if shot then
		local landsAt = intro + 5 + lead + shot.TotalSeconds + Config.Match.FlightPadSeconds
		e.tick(landsAt - 0.05)
		local waiting = e.phase() == "Flight"
		e.tick(landsAt)
		expect("The engine waits swing lead + flight + pad before the next turn", waiting and e.phase() ~= "Flight")
	end

	-- Auto-putter: play two bots to the end; every turn that starts on the green
	-- defaults to the putter, every turn off it never does.
	local bots: { MatchEngine.PlayerSpec } = {
		{ Id = "B1", Name = "A", IsBot = true, StatsFor = statsFor },
		{ Id = "B2", Name = "B", IsBot = true, StatsFor = statsFor },
	}
	local seed = 99
	local rng = function(): number
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	local m = MatchEngine.new({ IntroSeconds = 0, Players = bots, Holes = CourseDatabase.sequence(1, 3), Seed = 4, Now = 0 })
	local clock, greenTurns, puttsOk, offGreenOk = 0, 0, true, true
	for _ = 1, 4000 do
		if m.isFinished() then
			break
		end
		clock += 0.25
		m.tick(clock)
		local id = m.activeId()
		if id and m.phase() == "Swing" then
			local snap = m.snapshot(clock)
			for _, view in snap.Players do
				if view.Id == id then
					if view.Lie == "Green" then
						greenTurns += 1
						puttsOk = puttsOk and view.ClubLabel == "PT"
					else
						offGreenOk = offGreenOk and view.ClubLabel ~= "PT"
					end
				end
			end
			BotBrain.play(m, id, "Hard", rng, clock)
		end
		m.drainEvents()
	end
	expect(`Auto-putter: all {greenTurns} turns on the green start with the putter, none off it`, m.isFinished() and greenTurns > 0 and puttsOk and offGreenOk)

	-- On the green, other clubs are refused; off it, any club is fine.
	local g = MatchEngine.new({ IntroSeconds = 0, Players = bots, Holes = { CourseDatabase.hole(3) }, Seed = 2, Now = 0 })
	local gid = g.activeId() :: string
	local teeOk = g.setClub(gid, "WG")
	local refusedOnGreen = false
	local t = 0
	for _ = 1, 2000 do
		if g.isFinished() or refusedOnGreen then
			break
		end
		t += 0.25
		g.tick(t)
		local id = g.activeId()
		if id and g.phase() == "Swing" then
			for _, view in g.snapshot(t).Players do
				if view.Id == id and view.Lie == "Green" then
					local okWedge, whyWedge = g.setClub(id, "WG")
					refusedOnGreen = not okWedge and whyWedge == "putter_only_on_green" and g.setClub(id, "PT")
				end
			end
			if not refusedOnGreen then
				BotBrain.play(g, id, "Hard", rng, t)
			end
		end
		g.drainEvents()
	end
	expect("Putter only on the green (other clubs refused there, allowed elsewhere)", teeOk and refusedOnGreen)
	expect("Intro banner reads the hole and par", string.find(MatchView.hud(first, "H1", statsFor).Banner, "PAR") ~= nil)
end

print("-- aim guide")
do
	local base = ClubStats.baseline()
	local dr = ClubStats.get("DR") :: ClubStats.Category
	local guide = AimGuide.compute({ Terrain = ShotPhysics.flatTerrain("Fairway"), X = 10, Z = 5, HeadingRad = 0, Slot = dr, Stats = base, Lie = "Tee", Power = 100 })
	local first, last = guide.Points[1], guide.Points[#guide.Points]
	local apex = 0
	for _, point in guide.Points do
		apex = math.max(apex, point.Y)
	end
	expect("Driver arc: starts at the ball, ends on the ground at the carry", not guide.IsPutt and math.abs(first.X - 10) < 1 and math.abs(first.Z - 5) < 1 and last.Y < 0.5 and math.abs(guide.DistanceYds - dr.BaseCarryYds) < dr.BaseCarryYds * 0.02)
	expect("Arc has a real apex and a bounded point count", apex > 15 and #guide.Points <= AimGuide.MAX_POINTS + 1 and #guide.Points >= 8)
	local turned = AimGuide.compute({ Terrain = ShotPhysics.flatTerrain("Fairway"), X = 0, Z = 0, HeadingRad = math.rad(90), Slot = dr, Stats = base, Lie = "Tee", Power = 100 })
	expect("The arc follows the aim heading", math.abs(turned.EndX) < 2 and turned.EndZ > 200)
	local half = AimGuide.compute({ Terrain = ShotPhysics.flatTerrain("Fairway"), X = 0, Z = 0, HeadingRad = 0, Slot = dr, Stats = base, Lie = "Tee", Power = 50 })
	expect("The arc grows with power (live while the gauge rises)", half.DistanceYds < guide.DistanceYds * 0.6 and half.DistanceYds > guide.DistanceYds * 0.4)
	local pt = ClubStats.get("PT") :: ClubStats.Category
	local putt = AimGuide.compute({ Terrain = ShotPhysics.flatTerrain("Green"), X = 0, Z = 0, HeadingRad = 0, Slot = pt, Stats = base, Lie = "Green", Power = 50 })
	local flat = true
	for _, point in putt.Points do
		if point.Y > 1e-6 then
			flat = false
		end
	end
	expect("Putting line: on the ground, ~half the full-power roll at 50%", putt.IsPutt and flat and math.abs(putt.DistanceYds - Config.Swing.PuttFullPowerYards / 2) < 2.5)
	local sloped: ShotPhysics.Terrain = {
		heightAt = function(_x: number, _z: number): number
			return 0
		end,
		lieAt = function(_x: number, _z: number): Types.LieId
			return "Green"
		end,
		slopeAt = function(_x: number, _z: number): (number, number)
			return 0, 0.03
		end,
	}
	local breaking = AimGuide.compute({ Terrain = sloped, X = 0, Z = 0, HeadingRad = 0, Slot = pt, Stats = base, Lie = "Green", Power = 60 })
	expect("Putting line bends with the green's slope (downhill to -Z here)", breaking.EndZ < -0.3)
end

print("-- driving range")
do
	local YD = Config.Physics.YardsToMeters
	local overlap, ordered = false, true
	for i, a in RangeRules.Targets do
		local ax, az = RangeRules.centreOf(a)
		for j, b in RangeRules.Targets do
			if i < j then
				local bx, bz = RangeRules.centreOf(b)
				if math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2) < (a.RadiusYds + b.RadiusYds) * YD then
					overlap = true
				end
			end
		end
		if i > 1 then
			local prev = RangeRules.Targets[i - 1]
			if not (a.DistanceYds > prev.DistanceYds and a.Coins > prev.Coins and a.RadiusYds >= prev.RadiusYds) then
				ordered = false
			end
		end
		if a.DistanceYds + a.RadiusYds > RangeRules.LengthYds or math.abs(a.LateralYds) + a.RadiusYds > RangeRules.HalfWidthYds then
			ordered = false
		end
	end
	expect("Targets don't overlap, sit on the range, and pay more the further out they are", not overlap and ordered)
	local t = RangeRules.Targets[3]
	local cx, cz = RangeRules.centreOf(t)
	local hitCentre, bull = RangeRules.targetAt(cx, cz)
	local hitEdge, edgeBull = RangeRules.targetAt(cx + t.RadiusYds * YD * 0.9, cz)
	local miss = RangeRules.targetAt(cx + t.RadiusYds * YD * 1.1, cz + 30)
	expect("targetAt: bullseye in the inner third, plain hit at the edge, miss outside", hitCentre == t and bull and hitEdge == t and not edgeBull and miss == nil)
	expect("Bullseye pays the multiplier; a miss pays nothing", RangeRules.payout(t, true) == t.Coins * Config.Range.BullseyeMultiplier and RangeRules.payout(t, false) == t.Coins and RangeRules.payout(nil, true) == 0)
	local wx, wz = RangeRules.toWorld(12.5, -3.25)
	local bx, bz = RangeRules.fromWorld(wx, wz)
	expect("Range frame <-> world round-trips; downrange is world -X", math.abs(bx - 12.5) < 1e-9 and math.abs(bz + 3.25) < 1e-9 and wx < RangeRules.ORIGIN.X)

	-- Every target can actually be hit from a bay with a perfect strike.
	local bay = RangeRules.bay(2) :: RangeRules.Bay
	local teeX, teeZ = RangeRules.teeOf(bay)
	local base = ClubStats.baseline()
	local allReachable = true
	for _, target in RangeRules.Targets do
		local tx, tz = RangeRules.centreOf(target)
		local aim = math.deg(math.atan2(tz - teeZ, tx - teeX))
		local hit = false
		for _, category in ClubStats.Categories do
			if category.Class ~= "Putter" and not hit then
				for power = 10, 100, 2 do
					local shot = RangeRules.resolve(bay, category.Label, base, power, 0, aim)
					if shot and shot.TargetId == target.Id then
						hit = true
						break
					end
				end
			end
		end
		if not hit then
			allReachable = false
			print(`  unreachable target {target.Id}`)
		end
	end
	expect("Every target green can be hit (and held) from a bay", allReachable)
	expect("No putting at the range; unknown clubs/bays refused", RangeRules.resolve(bay, "PT", base, 50, 0, 0) == nil and RangeRules.resolve(bay, "7i", base, 50, 0, 0) == nil and RangeRules.bay(9) == nil)
	local a = RangeRules.resolve(bay, "SI", base, 77, -0.2, 3) :: RangeRules.Shot
	local b = RangeRules.resolve(bay, "SI", base, 77, -0.2, 3) :: RangeRules.Shot
	expect("Range shots are deterministic and start at the bay tee", a.Final.X == b.Final.X and a.Coins == b.Coins and math.abs(a.Samples[1][2] - teeX) < 0.5 and math.abs(a.Samples[1][4] - teeZ) < 0.5)
end

print("-- lobby zone rewards")
do
	local day = 20000 * 86400
	local d = ProfileTemplate.new(0)
	d.Coins = 0
	local cap = Config.Range.DailyCoinCap
	local first = ZoneRewards.pay(d, "Range", cap - 100, day + 10)
	local second = ZoneRewards.pay(d, "Range", 500, day + 20)
	local third = ZoneRewards.pay(d, "Range", 50, day + 30)
	expect("Range pays until the daily cap, then nothing", first == cap - 100 and second == 100 and third == 0 and d.Coins == cap and ZoneRewards.remaining(d, "Range", day + 40) == 0)
	expect("Earnings count as coins earned", d.Stats.TotalCoinsEarned >= cap)
	local afkStill = ZoneRewards.pay(d, "Afk", 30, day + 50)
	expect("Each zone has its own cap", afkStill == 30 and ZoneRewards.earnedToday(d, "Afk", day + 60) == 30)
	local tomorrow = ZoneRewards.pay(d, "Range", 40, day + 86400 + 5)
	expect("A new UTC day resets the caps", tomorrow == 40 and d.Earnings.Range == 40 and d.Earnings.Afk == 0)
	expect("Bad amounts pay nothing", ZoneRewards.pay(d, "Afk", -5, day) == 0 and ZoneRewards.pay(d, "Afk", 0 / 0, day) == 0 and ZoneRewards.pay(d, "Afk", 0.5, day) == 0)

	local tick = Config.Afk.TickSeconds
	local timer: ZoneRewards.AfkTimer = { NextPayAt = nil }
	local due = 0
	timer, due = ZoneRewards.afkStep(timer, true, 100)
	local entered = due == 0 and timer.NextPayAt == 100 + tick
	timer, due = ZoneRewards.afkStep(timer, true, 100 + tick - 1)
	local early = due == 0
	timer, due = ZoneRewards.afkStep(timer, true, 100 + tick)
	expect("AFK: a full minute inside pays one tick; not before", entered and early and due == 1 and timer.NextPayAt == 100 + 2 * tick)
	timer, due = ZoneRewards.afkStep(timer, false, 100 + tick + 30)
	local left = due == 0 and timer.NextPayAt == nil
	timer, due = ZoneRewards.afkStep(timer, true, 100 + tick + 31)
	timer, due = ZoneRewards.afkStep(timer, true, 100 + 2 * tick + 30)
	expect("AFK: stepping out restarts the timer (no partial-minute farming)", left and due == 0 and ZoneRewards.afkSecondsLeft(timer, 100 + 2 * tick + 30) == 1)

	expect("The AFK lounge presence test matches the deck", LobbyLayout.insideAfk(LobbyLayout.AFK_LOUNGE.X, 3, LobbyLayout.AFK_LOUNGE.Z) and not LobbyLayout.insideAfk(0, 3, 100) and not LobbyLayout.insideAfk(LobbyLayout.AFK_LOUNGE.X, 40, LobbyLayout.AFK_LOUNGE.Z))
	local layout = LobbyLayout.build()
	local names: { [string]: CourseLayout.PartSpec } = {}
	for _, part in layout.Parts do
		names[part.Name] = part
	end
	local targetsBuilt = true
	for _, target in RangeRules.Targets do
		local part = names["RangeTarget_" .. target.Id]
		local tx, tz = RangeRules.toWorld(RangeRules.centreOf(target))
		if part == nil or math.abs(part.X - tx) > 1e-6 or math.abs(part.Z - tz) > 1e-6 then
			targetsBuilt = false
		end
	end
	local matsBuilt = true
	for _, bay in RangeRules.Bays do
		if names["RangeMat_" .. bay.Id] == nil then
			matsBuilt = false
		end
	end
	local clearOfTrees = true
	for _, part in layout.Parts do
		if string.sub(part.Name, 1, 9) == "TreeTrunk" then
			local lounge = LobbyLayout.AFK_LOUNGE
			if LobbyLayout.inRangeArea(part.X, part.Z) or math.sqrt((part.X - lounge.X) ^ 2 + (part.Z - lounge.Z) ^ 2) < lounge.Radius + 4 then
				clearOfTrees = false
			end
		end
	end
	expect("The built range matches RangeRules (targets + bays) and the lounge exists", targetsBuilt and matsBuilt and names.AfkDeck ~= nil)
	-- The wheel stand must not overlap any other lobby furniture.
	local w = LobbyLayout.WHEEL
	local wheelClear = true
	for _, part in layout.Parts do
		if string.sub(part.Name, 1, 5) ~= "Wheel" and part.Name ~= "Ground" and part.Name ~= "Plaza" and part.Name ~= "PlazaRing" and part.Y > 0.5 then
			-- Gap between the wheel's footprint circle and the part's (unrotated) box.
			local half = math.max(part.SX, part.SZ) / 2 -- generous for rotated parts
			local dx = math.max(math.abs(part.X - w.X) - (if part.YawDeg == 0 then part.SX / 2 else half), 0)
			local dz = math.max(math.abs(part.Z - w.Z) - (if part.YawDeg == 0 then part.SZ / 2 else half), 0)
			if math.sqrt(dx * dx + dz * dz) < w.Radius + 3 then
				wheelClear = false
				print("  wheel overlaps " .. part.Name)
			end
		end
	end
	expect("The daily wheel stand is clear of benches, lamps and trees", wheelClear)
	expect("No trees on the range or the lounge", clearOfTrees)
end

print("-- swing poses & podium")
do
	local impact = SwingPose.impactTime("Swing") :: number
	local atImpact = SwingPose.sample("Swing", impact, 100)
	local top = SwingPose.sample("Swing", 0.7, 100)
	local softTop = SwingPose.sample("Swing", 0.7, 20)
	expect("The club meets the ball at the server's swing lead", impact == Config.Match.SwingLeadSeconds and SwingPose.impactTime("Putt") == impact and SwingPose.impactTime("Victory") == nil)
	expect("Swing keyframes stay ordered (lead must follow the top of the backswing)", Config.Match.SwingLeadSeconds > 0.8 and SwingPose.duration("Swing") > impact + 1)
	expect("Impact pose: hands back down at the ball, chest opening to the target", atImpact.RArmPitch < 40 and atImpact.SpineYaw > 0 and atImpact.SpineYaw < 30)
	expect("Backswing turns away from the target; less power = shorter backswing", top.SpineYaw < -60 and top.RArmPitch > 90 and softTop.SpineYaw > top.SpineYaw)
	local finite = true
	for _, kind in { "Idle", "Address", "PuttAddress", "Swing", "Putt", "Victory", "Defeat" } :: { SwingPose.Kind } do
		for t = 0, 4, 0.05 do
			for _, v in SwingPose.sample(kind, t, 70) :: any do
				if v ~= v or math.abs(v) > 200 then
					finite = false
				end
			end
		end
	end
	expect("Every pose is finite and within joint limits at every time", finite)
	local victory = SwingPose.sample("Victory", 0.45, nil)
	local defeat = SwingPose.sample("Defeat", 1.0, nil)
	expect("Victory raises the arms and hops; defeat hangs the head", victory.RArmPitch > 140 and victory.Hop > 0 and defeat.HeadPitch < -20 and defeat.Hop == 0)

	local snap: any = {
		HoleCount = 3,
		Players = {
			{ Id = "me", Name = "Me", IsBot = false, Total = 14, Forfeited = false },
			{ Id = "bot", Name = "Rival Bot", IsBot = true, Total = 12, Forfeited = false },
		},
		Result = { WinnerId = "bot", Draw = false, Reason = "complete" },
	}
	local podium = PodiumView.build(snap, "me")
	local winner, loser = podium.Entries[1], podium.Entries[2]
	expect("Podium: winner on the top step playing Victory, loser lower playing Defeat", winner.Id == "bot" and winner.Animation == "Victory" and winner.Place == 1 and loser.Id == "me" and loser.Animation == "Defeat" and winner.StepHeight > loser.StepHeight and loser.IsMe)
	expect("Podium title is from my point of view", podium.Title == "DEFEAT" and string.find(podium.Subtitle, "Rival Bot") ~= nil)
	snap.Result = { WinnerId = nil, Draw = true, Reason = "complete" }
	local drawn = PodiumView.build(snap, "me")
	expect("Draw: equal steps, side by side, no gloating", drawn.Title == "DRAW" and drawn.Entries[1].StepHeight == drawn.Entries[2].StepHeight and drawn.Entries[1].SlotX ~= drawn.Entries[2].SlotX and drawn.Entries[1].Animation == "Idle")
	snap.Players[1].Forfeited = true
	snap.Players[1].Total = 3
	snap.Result = { WinnerId = "bot", Draw = false, Reason = "forfeit" }
	local ff = PodiumView.build(snap, "bot")
	expect("Forfeit: the forfeiter is the loser whatever their strokes", ff.Entries[1].Id == "bot" and ff.Entries[2].TotalText == "forfeited" and ff.Title == "VICTORY" and string.find(ff.Subtitle, "forfeit") ~= nil)
end

print("-- putting balance (cup capture + magnet)")
do
	local P = Config.Physics
	local mx, mz = ShotPhysics.magnetAt({ X = 1, Z = 0 }, 0.8, 0, 0.5)
	local fx = ShotPhysics.magnetAt({ X = 1, Z = 0 }, 0.8, 0, P.MagnetMaxSpeed + 1)
	local far = ShotPhysics.magnetAt({ X = 1, Z = 0 }, 1 - P.MagnetRadius - 0.01, 0, 0.5)
	expect("Magnet pulls a slow ball near the rim toward the cup; ignores fast or distant balls", mx > 0 and math.abs(mz) < 1e-12 and fx == 0 and far == 0)
	expect("Capture radius is bigger than the visual cup (forgiving drops)", P.CupCaptureRadius > P.CupRadius + 0.04)

	-- A putt on a flat green from 6 m, aimed a little off-line, at a pace that
	-- would finish ~0.6 m past the hole.
	local green = ShotPhysics.flatTerrain("Green")
	local mu = Config.Lies.Green.RollFriction
	local speed = math.sqrt(2 * mu * P.Gravity * 6.6)
	local function putt(lateralAtCup: number): ShotPhysics.ShotResult
		return ShotPhysics.simulate({
			BallSpeed = speed, LaunchAngleRad = 0, BackspinRpm = 0, SidespinRpm = 0,
			AimOffsetRad = math.atan2(lateralAtCup, 6), IsPutt = true,
		}, green, nil, { X = 6, Z = 0 })
	end
	expect("A putt passing 9 cm from the centre drops (old 5.4 cm cup would miss it)", putt(0.09).Outcome == "Holed")
	local savedAccel = P.MagnetAccel
	P.MagnetAccel = 0
	local nearMiss = P.CupCaptureRadius + 0.01
	local noMagnet = putt(nearMiss)
	P.MagnetAccel = savedAccel
	local withMagnet = putt(nearMiss)
	expect("The magnet curls in a near-miss just outside the capture radius that would otherwise roll past", noMagnet.Outcome ~= "Holed" and withMagnet.Outcome == "Holed")

	-- Cup capture vs lip-out, by the speed the ball has when it reaches the cup.
	local function arriving(speedAtCup: number, lateral: number): ShotPhysics.ShotResult
		local d = 3
		local v0 = math.sqrt(speedAtCup * speedAtCup + 2 * mu * P.Gravity * d)
		return ShotPhysics.simulate({
			BallSpeed = v0, LaunchAngleRad = 0, BackspinRpm = 0, SidespinRpm = 0, AimOffsetRad = math.atan2(lateral, d), IsPutt = true,
		}, green, nil, { X = d, Z = 0 })
	end
	expect("A ball rolling over the cup at a reasonable speed (1.2 m/s) drops in", arriving(1.2, 0).Outcome == "Holed")
	expect("A firm putt (1.8 m/s, just under the capture speed) still drops if it's on line", arriving(P.CupCaptureSpeed * 0.9, 0).Outcome == "Holed")
	local tooFast = arriving(P.CupCaptureSpeed * 1.6, 0)
	expect("A ball much faster than the capture speed rolls over the cup (lips out) and carries on past it", tooFast.Outcome == "Rest" and tooFast.FinalX > 3.5)
	local edge = arriving(1.2, P.CupCaptureRadius * 0.8)
	expect("A slow ball catching the edge of the cup drops in", edge.Outcome == "Holed")
	expect("A clearly missed putt (40 cm wide) still misses", putt(0.4).Outcome ~= "Holed")
	local blast = ShotPhysics.simulate({
		BallSpeed = math.sqrt(2 * mu * P.Gravity * 30), LaunchAngleRad = 0, BackspinRpm = 0, SidespinRpm = 0, AimOffsetRad = 0, IsPutt = true,
	}, green, nil, { X = 6, Z = 0 })
	expect("A putt charged straight over the hole at speed lips out", blast.Outcome ~= "Holed")
end

print("-- course elevation & slope-aware physics")
do
	local YDS = Config.Physics.YardsToMeters
	local function at(hole: CourseDatabase.HoleDef, xYds: number, zYds: number): number
		return (CourseRelief.ground(hole, xYds * YDS, zYds * YDS))
	end
	local everyTee, everyGreen = true, true
	for _, hole in CourseDatabase.Holes do
		local relief = hole.Relief :: CourseDatabase.Relief
		local teeTop = relief.Profile[1] + relief.TeeRaise
		if math.abs(CourseRelief.ground(hole, hole.Tee.X, hole.Tee.Z) - teeTop) > 0.05 then
			everyTee = false
		end
		local pin = CourseRelief.ground(hole, hole.Pin.X, hole.Pin.Z)
		if math.abs(pin - CourseRelief.greenPlane(hole, 1, hole.Pin.X, hole.Pin.Z)) > 0.02 then
			everyGreen = false
		end
	end
	expect("Every tee box sits on its plateau (tee elevation + raise)", everyTee)
	expect("Every pin sits on its green's tilted plane", everyGreen)
	local cliff, valley, pitch = CourseDatabase.hole(4), CourseDatabase.hole(7), CourseDatabase.hole(5)
	expect("Hole 4 plays off a cliff-top tee >= 12 m above the green; hole 5 plays uphill", CourseDatabase.elevationChange(cliff) <= -12 and CourseDatabase.elevationChange(pitch) >= 5)
	local valleyFloor = at(valley, 200, -8)
	expect("Hole 7 dips into a valley between its tee and green", valleyFloor < at(valley, 0, 0) - 5 and valleyFloor < at(valley, 405, -20) - 5)
	local raised = CourseDatabase.hole(5)
	local greenEdge = at(raised, 140 + 12 + 10, 0) -- 10 yards beyond the back of the green
	expect("Greens are raised on banks above their surroundings", at(raised, 140, 0) > greenEdge + 0.4)
	local h1 = CourseDatabase.hole(1)
	local b = h1.Bunkers[1]
	expect("Bunkers are sunk below the fairway around them", CourseRelief.ground(h1, b.X, b.Z) < CourseRelief.ground(h1, b.X + b.R + 3, b.Z) - 0.3)
	local island = CourseDatabase.hole(8)
	local level = CourseRelief.waterAt(island, island.Pin.X + 20 * YDS, 0)
	expect("Island green: green on the island, open water around it, the water surface is what a ball meets",
		CourseTerrain.lieAt(island, island.Pin.X, island.Pin.Z) == "Green" and CourseTerrain.lieAt(island, island.Pin.X + 20 * YDS, 0) == "Water"
			and level ~= nil and math.abs(CourseTerrain.forHole(island).heightAt(island.Pin.X + 20 * YDS, 0) - (level :: number)) < 1e-9)
	local overflow = false
	for _, hole in CourseDatabase.Holes do
		for i, water in hole.Water do
			local lvl = CourseRelief.waterLevel(hole, i) :: number
			for k = 0, 15 do
				local a = k / 16 * 2 * math.pi
				local rim = CourseRelief.exact(hole, water.X + math.cos(a) * (water.R + 1), water.Z + math.sin(a) * (water.R + 1))
				local rx, rz = water.X + math.cos(a) * (water.R + 1), water.Z + math.sin(a) * (water.R + 1)
				local inOther = false
				for _, other in hole.Water do
					if (rx - other.X) ^ 2 + (rz - other.Z) ^ 2 < other.R * other.R then
						inOther = true
					end
				end
				if rim < lvl - 1e-6 and not inOther and CourseTerrain.lieAt(hole, rx, rz) ~= "Green" then
					overflow = true
				end
			end
		end
	end
	expect("No pond's water level is above the ground just outside it (water never spills)", not overflow)
	-- The cached gradient agrees with the exact height field.
	local gradOk = true
	for _, probe in { { 150, 5 }, { 300, -20 }, { 60, 30 } } do
		local x, z = probe[1] * YDS, probe[2] * YDS
		local _, gx, gz = CourseRelief.ground(cliff, x, z)
		local e = 0.5
		local fx = (CourseRelief.exact(cliff, x + e, z) - CourseRelief.exact(cliff, x - e, z)) / (2 * e)
		local fz = (CourseRelief.exact(cliff, x, z + e) - CourseRelief.exact(cliff, x, z - e)) / (2 * e)
		if math.abs(gx - fx) > 0.03 or math.abs(gz - fz) > 0.03 then
			gradOk = false
		end
	end
	expect("The terrain gradient matches the height field (within 3%)", gradOk)
	expect("The flat flag ignores elevation (classic part courses)", CourseTerrain.forHole(cliff, true).heightAt(0, 0) == 0 and CourseTerrain.forHole(cliff).heightAt(0, 0) > 10)

	-- Slope-aware roll: the same putt runs further downhill, shorter uphill, and
	-- curves (breaks) across a side slope.
	local function slope(gx: number, gz: number): ShotPhysics.Terrain
		return {
			heightAt = function(x: number, z: number): number
				return gx * x + gz * z
			end,
			lieAt = function(_x: number, _z: number): Types.LieId
				return "Green"
			end,
			slopeAt = function(_x: number, _z: number): (number, number)
				return gx, gz
			end,
		}
	end
	local putt: ShotPhysics.Launch = { BallSpeed = 3, LaunchAngleRad = 0, BackspinRpm = 0, SidespinRpm = 0, AimOffsetRad = 0, IsPutt = true }
	local flatRun = ShotPhysics.simulate(putt, slope(0, 0), nil, nil)
	local down = ShotPhysics.simulate(putt, slope(-0.03, 0), nil, nil)
	local up = ShotPhysics.simulate(putt, slope(0.03, 0), nil, nil)
	local side = ShotPhysics.simulate(putt, slope(0, 0.03), nil, nil)
	expect("Slope physics: downhill putts run further, uphill putts die early", down.FinalX > flatRun.FinalX + 1 and up.FinalX < flatRun.FinalX - 1)
	expect("Slope physics: a side slope breaks the putt toward the low side", side.FinalZ < -0.2)
	local tee4 = CourseTerrain.shotFrame(CourseTerrain.forHole(cliff), cliff.Tee.X, cliff.Tee.Z, 0)
	local drive = SwingMath.computeLaunch({ Slot = ClubDatabase.getSlot("DR") :: ClubDatabase.BagSlot, Stats = { Power = 60, Accuracy = 60, Spin = 60 }, Power = 100, AccuracyOffset = 0, Lie = "Tee" })
	local downhillDrive = ShotPhysics.simulate(drive, tee4, nil, nil)
	local flatDrive = ShotPhysics.simulate(drive, ShotPhysics.flatTerrain("Fairway"), nil, nil)
	expect("A drive off hole 4's cliff-top tee carries further than on flat ground", downhillDrive.CarryYds > flatDrive.CarryYds + 5)
end

print("-- smooth terrain: materials, build plan, surface injection, decor")
do
	expect("Terrain materials map to golf lies (LeafyGrass short fairway, Grass tall rough, Sand bunker, Water)",
		SurfaceMaterials.lieFor("LeafyGrass", nil) == "Fairway" and SurfaceMaterials.lieFor("Grass", nil) == "Rough"
			and SurfaceMaterials.BuildMaterials.Fairway == "LeafyGrass" and SurfaceMaterials.BuildMaterials.Rough == "Grass"
			and SurfaceMaterials.lieFor("Sand", nil) == "Sand" and SurfaceMaterials.lieFor("Water", nil) == "Water"
			and SurfaceMaterials.lieFor("Neon", nil) == "Rough")
	expect("A part's GolfLie attribute beats its material; junk attributes are ignored",
		SurfaceMaterials.lieFor("Grass", "Green") == "Green" and SurfaceMaterials.lieFor("Sand", "Tee") == "Tee" and SurfaceMaterials.lieFor("LeafyGrass", "Lava") == "Fairway" and SurfaceMaterials.lieFor("LeafyGrass", 5) == "Fairway")
	local rock = SurfaceMaterials.physicsFor("Rock", "Rough")
	local mud = SurfaceMaterials.physicsFor("Mud", "Rough")
	expect("Material physics refine the lie: rock bounces/rolls more than rough, mud swallows the ball",
		rock.Restitution > Config.Lies.Rough.Restitution and rock.RollFriction < Config.Lies.Rough.RollFriction and mud.RollFriction > Config.Lies.Rough.RollFriction
			and SurfaceMaterials.physicsFor("LeafyGrass", "Fairway") == Config.Lies.Fairway and Config.Lies.Rough.Restitution == 0.20)

	-- ShotPhysics honours a terrain's physicsAt (same lie, different material).
	local function landOn(def: Config.LieDef?): ShotPhysics.ShotResult
		local terrainWith: ShotPhysics.Terrain = {
			heightAt = function(_x: number, _z: number): number
				return 0
			end,
			lieAt = function(_x: number, _z: number): Types.LieId
				return "Rough"
			end,
			slopeAt = function(_x: number, _z: number): (number, number)
				return 0, 0
			end,
			physicsAt = function(_x: number, _z: number): Config.LieDef?
				return def
			end,
		}
		return SwingMath.resolveShot({ Slot = ClubStats.get("LI") :: ClubStats.Category, Stats = ClubStats.baseline(), Power = 100, AccuracyOffset = 0, Lie = "Fairway" }, terrainWith, nil).Result
	end
	expect("A shot landing on rock runs out further than the same shot landing in rough", landOn(rock).RollYds > landOn(nil).RollYds + 5)

	local SPM = CourseLayout.STUDS_PER_METER
	local YDS = Config.Physics.YardsToMeters
	local finale = CourseDatabase.hole(9)
	local hole = CourseDatabase.hole(2)
	local plan = TerrainPlan.build(hole)
	local partBy: { [string]: TerrainPlan.SurfacePart } = {}
	for _, p in plan.Parts do
		partBy[p.Name] = p
	end
	local fairway = TerrainPlan.column(hole, 5 * Config.Physics.YardsToMeters * SPM, 0)
	local rough = TerrainPlan.column(hole, 120 * Config.Physics.YardsToMeters * SPM, 50 * Config.Physics.YardsToMeters * SPM)
	local bunker = hole.Bunkers[1]
	local sand = TerrainPlan.column(hole, bunker.X * SPM, bunker.Z * SPM)
	local sandRim = TerrainPlan.column(hole, (bunker.X + bunker.R + 2) * SPM, bunker.Z * SPM)
	local pond = hole.Water[1]
	local water = TerrainPlan.column(hole, pond.X * SPM, pond.Z * SPM)
	local outside = TerrainPlan.column(hole, (hole.Bounds.MaxX + 20) * SPM, 0)
	local road = TerrainPlan.column(finale, 150 * YDS * SPM, 62 * YDS * SPM)
	expect("Sculpt columns: short LeafyGrass fairway, tall Grass rough, sunken Sand bunker, Mud bed under a water surface, OB road of Ground",
		fairway.Material == "LeafyGrass" and rough.Material == "Grass" and sand.Material == "Sand" and sand.Top < sandRim.Top - 0.5
			and water.Material == "Mud" and water.WaterTop ~= nil and (water.WaterTop :: number) > water.Top + 2 and outside.Material == "Grass" and road.Material == "Ground")
	local green = partBy.Green_1
	expect("Greens and the tee are smooth turf parts tagged with their lie; the green tilts with the hole's slope",
		green ~= nil and green.Lie == "Green" and green.SlopeX == hole.GreenSlope.X and green.SlopeZ == hole.GreenSlope.Z and partBy.TeeBox.Lie == "Tee" and partBy.Fringe_1.Lie == nil)
	local hole1 = (green :: TerrainPlan.SurfacePart).Hole
	local plug, bottom, pole = partBy.CupPlug, partBy.CupBottom, partBy.PinPole
	expect("A real cup: the green part carries a pocket deeper than the ball, centred on the pin, with a dark bottom inside it",
		hole1 ~= nil and math.abs(hole1.X - hole.Pin.X * SPM) < 1e-9 and math.abs(hole1.Z - hole.Pin.Z * SPM) < 1e-9
			and hole1.Depth > CourseLayout.BALL_DIAMETER and hole1.Diameter == CourseLayout.CUP_DIAMETER
			and bottom ~= nil and bottom.Y < plan.Pin.Y - CourseLayout.BALL_DIAMETER and bottom.CanQuery == false)
	expect("An invisible cup plug keeps raycasts reading a flat green (lie Green), but nothing collides with it",
		plug ~= nil and plug.Lie == "Green" and plug.CanQuery and not plug.CanCollide and plug.Transparency == 1)
	expect("The flagstick is thin, centred in the cup, and can't stop the ball (no collision, no raycast hits)",
		pole ~= nil and pole.SX <= 0.2 and math.abs(pole.X - hole.Pin.X * SPM) < 1e-9 and not pole.CanCollide and not pole.CanQuery)
	expect("The ball is small (like real golf) and the cup ~2-3x its size; out-of-bounds stakes are placed",
		CourseLayout.BALL_DIAMETER <= 0.5 and CourseLayout.CUP_DIAMETER >= 2 * CourseLayout.BALL_DIAMETER and CourseLayout.CUP_DIAMETER <= 3 * CourseLayout.BALL_DIAMETER and partBy.OBStake_1 ~= nil)
	local captureStuds = Config.Physics.CupCaptureRadius * SPM
	expect("A captured ball's centre is over the hole (capture radius < cup radius), so it can visibly drop in",
		captureStuds < CourseLayout.CUP_DIAMETER / 2 and captureStuds > CourseLayout.CUP_DIAMETER / 4)
	local onGreen = TerrainPlan.column(hole, hole.Pin.X * SPM, hole.Pin.Z * SPM)
	expect("Terrain under the green is carved below the turf part (no grass poking through, room for the cup)",
		onGreen.Top < plan.Pin.Y - TerrainPlan.CUP_DEPTH and onGreen.Top > plan.Pin.Y - TerrainPlan.GREEN_PART_THICKNESS - 0.5)
	local lo, hi = CourseRelief.range(hole, hole.Bounds.MinX, hole.Bounds.MaxX, hole.Bounds.MinZ, hole.Bounds.MaxZ, 4)
	expect("The sculpt region covers the bounds plus apron, from below the lowest ground to above the highest",
		plan.Min.X < hole.Bounds.MinX * SPM and plan.Max.X > hole.Bounds.MaxX * SPM and plan.Min.Y < lo * SPM - 8 and plan.Max.Y > hi * SPM + 8)
	expect("The cup sits on the tilted green plane", math.abs(plan.Pin.Y - (CourseRelief.greenPlane(hole, 1, hole.Pin.X, hole.Pin.Z) * SPM + TerrainPlan.GREEN_LIFT)) < 1e-9)

	-- The engine plays on whatever surface it is given.
	local sandEverywhere: CourseTerrain.CourseSurface = {
		Terrain = ShotPhysics.flatTerrain("Sand"),
		lieAt = function(_x: number, _z: number): Types.LieId
			return "Sand"
		end,
		inBounds = function(_x: number, _z: number): boolean
			return true
		end,
	}
	local function statsFor(_label: string): ClubDatabase.Stats
		return ClubStats.baseline()
	end
	local injected = MatchEngine.new({
		IntroSeconds = 0, Players = { { Id = "A", Name = "A", IsBot = true, StatsFor = statsFor }, { Id = "B", Name = "B", IsBot = true, StatsFor = statsFor } },
		Holes = { CourseDatabase.hole(1) }, Seed = 3, Now = 0,
		Surface = function(_hole: CourseDatabase.HoleDef): CourseTerrain.CourseSurface
			return sandEverywhere
		end,
	})
	local shooter = injected.activeId() :: string
	injected.submitBotSwing(shooter, "DR", 0, 80, 0, 1)
	local lieAfter = ""
	for _, view in injected.snapshot(1).Players do
		if view.Id == shooter then
			lieAfter = view.Lie
		end
	end
	expect("MatchEngine resolves lies through the injected course surface (raycast terrain in Studio)", lieAfter == "Sand")

	local decor = DecorPlanner.forHole(hole, 77)
	local again = DecorPlanner.forHole(hole, 77)
	local inBand, clear, kinds = true, true, {}
	local circles: { CourseDatabase.Circle } = {}
	for _, list in { hole.Greens, hole.Bunkers, hole.Water } do
		for _, c in list do
			table.insert(circles, c)
		end
	end
	local keepOut: DecorPlanner.Input = { Bounds = hole.Bounds, Circles = circles, Capsules = hole.Fairway, Seed = 0 }
	for _, item in decor do
		if not DecorPlanner.inBand(hole.Bounds, item.X, item.Z) then
			inBand = false
		end
		if DecorPlanner.clearance(keepOut, item.X, item.Z) < Config.Decor.ClearanceMeters - 1e-9 then
			clear = false
		end
		kinds[item.Kind] = true
	end
	expect(`Decor: {#decor} items, all in the border band and clear of every playing surface`, #decor > 40 and #decor <= Config.Decor.MaxItems and inBand and clear)
	expect("Decor is deterministic per seed and mixes trees, bushes, rocks and grass patches", #again == #decor and again[5].X == decor[5].X and kinds.Tree and kinds.Bush and kinds.Rock and kinds.GrassPatch)
end

print("-- aerial aim reticle")
do
	local dr = ClubStats.get("DR") :: ClubStats.Category
	local pt = ClubStats.get("PT") :: ClubStats.Category
	expect("ClubStats max distance: driver 250 yds at baseline, more with Power; putter = full putt roll",
		math.abs(ClubStats.maxDistanceYds(dr) - 250) < 1e-9 and ClubStats.maxDistanceYds(dr, { Power = 90, Accuracy = 50, Spin = 50 }) > 260 and ClubStats.maxDistanceYds(pt) == Config.Swing.PuttFullPowerYards)
	local YD = Config.Physics.YardsToMeters
	local maxM = 200 * YD
	local inside = AimMath.clamp(0, 0, 100, 10, 0, maxM)
	expect("A reticle inside the limits is kept as placed", not inside.Clamped and math.abs(inside.X - 100) < 1e-9 and math.abs(inside.Z - 10) < 1e-9 and math.abs(inside.AimDeg - math.deg(math.atan2(10, 100))) < 1e-9)
	local tooFar = AimMath.clamp(0, 0, 500, 0, 0, maxM)
	expect("Too far: pulled back to the club's max distance on the same line", tooFar.Clamped and math.abs(tooFar.DistanceMeters - maxM) < 1e-9 and math.abs(tooFar.Z) < 1e-9)
	local wide = AimMath.clamp(0, 0, 0, 100, 0, maxM)
	expect("Too wide: turned back to the max aim angle the server allows", wide.Clamped and math.abs(wide.AimDeg - Config.Match.MaxAimDegrees) < 1e-9)
	local behind = AimMath.clamp(10, 10, 10, 10, math.rad(45), maxM)
	expect("A click on the ball itself gives a short shot straight at the pin", behind.AimDeg == 0 and math.abs(behind.DistanceMeters - AimMath.MIN_METERS) < 1e-9)
	local def = AimMath.defaultReticle(0, 0, 0, 300, 120)
	expect("Default reticle: on the pin line, capped at the club's reach", math.abs(def.X) < 1e-9 and math.abs(def.Z - 120) < 1e-9 and def.AimDeg == 0)
	-- The target power really sends a perfect strike about that far (carry% ~ power%).
	local base = ClubStats.baseline()
	local within = true
	for _, fraction in { 0.35, 0.6, 0.85 } do
		local power = AimMath.targetPower(fraction * 250, ClubStats.maxDistanceYds(dr, base)) * 100
		local carry = AimGuide.compute({ Terrain = ShotPhysics.flatTerrain("Fairway"), X = 0, Z = 0, HeadingRad = 0, Slot = dr, Stats = base, Lie = "Fairway", Power = power }).DistanceYds
		if math.abs(carry - fraction * 250) > 250 * 0.07 then
			within = false
			print(`  target {fraction * 250} -> carry {carry}`)
		end
	end
	expect("The reticle's target power carries the ball to the reticle (within 7% of full reach)", within)
	expect("Target power is clamped to the valid range", AimMath.targetPower(400, 250) == 1 and AimMath.targetPower(0, 250) == Config.Swing.MinPower / 100)
end

print("-- daily wheelspin")
do
	local day = 24 * 60 * 60
	local d = ProfileTemplate.new(0)
	d.Coins, d.Gems = 0, 0
	local t0 = 1000000
	local first = WheelRules.state(d, t0)
	expect("A new player's free spin is ready", first.FreeReady and first.CanSpin and first.ExtraSpins == 0)
	local seq = { 0.0, 0.5 }
	local k = 0
	local rng = function(): number
		k += 1
		return seq[(k - 1) % #seq + 1]
	end
	local result = WheelRules.spin(d, t0, rng)
	expect("Spinning uses the free spin, restarts the 24 h cooldown and grants the rolled segment",
		result ~= nil and result.UsedFree and result.SegmentIndex == 1 and d.Wheel.LastFreeSpinAt == t0 and d.Coins == Config.Wheel.Segments[1].Amount)
	local after = WheelRules.state(d, t0 + 60)
	local _, why = WheelRules.spin(d, t0 + 60, rng)
	expect("No second spin until the cooldown ends", not after.CanSpin and math.abs(after.SecondsUntilFree - (day - 60)) < 1e-9 and why == "no_spins")
	expect("The free spin comes back after 24 hours", WheelRules.state(d, t0 + day).FreeReady)

	local broke, whyBroke = WheelRules.buyWithGems(d)
	d.Gems = Config.Wheel.GemSpinPrice
	local bought = WheelRules.buyWithGems(d)
	expect("Extra spins cost gems (refused when broke)", not broke and whyBroke == "insufficient_funds" and bought and d.Gems == 0 and d.Wheel.ExtraSpins == 1)
	local paid = WheelRules.spin(d, t0 + 120, rng)
	expect("A bought spin is used while the free one is cooling down", paid ~= nil and not paid.UsedFree and d.Wheel.ExtraSpins == 0 and d.Wheel.LastFreeSpinAt == t0)
	local g1 = WheelRules.grantPurchase(d, "receipt-A")
	local g2 = WheelRules.grantPurchase(d, "receipt-A")
	expect("A Robux receipt grants spins exactly once (re-delivery is ignored)", g1 and not g2 and d.Wheel.ExtraSpins == Config.Wheel.RobuxSpinsPerPurchase)

	-- Weighted odds: a cumulative table whose steps are exactly the weight shares.
	local weightTotal = 0
	for _, segment in Config.Wheel.Segments do
		weightTotal += segment.Weight
	end
	local odds = WheelRules.odds()
	local cumulative = WheelRules.cumulative()
	local exact, oddsTotal = true, 0
	for i, segment in Config.Wheel.Segments do
		oddsTotal += odds[i]
		if math.abs(odds[i] - segment.Weight / weightTotal) > 1e-12 then
			exact = false
		end
	end
	expect("Odds are fractions equal to weight / total weight and sum to exactly 1 (no more 3146%)", exact and math.abs(oddsTotal - 1) < 1e-12 and cumulative[#cumulative] == 1)
	-- Boundaries: a roll lands in the segment whose cumulative interval holds it.
	local function constantRoll(v: number): () -> number
		return function(): number
			return v
		end
	end
	local edgesOk = WheelRules.pick(constantRoll(0)) == 1 and WheelRules.pick(constantRoll(1)) == #Config.Wheel.Segments
	for i = 1, #cumulative - 1 do
		if WheelRules.pick(constantRoll(cumulative[i] - 1e-9)) ~= i or WheelRules.pick(constantRoll(cumulative[i])) ~= i + 1 then
			edgesOk = false
		end
	end
	expect("pick() maps each cumulative interval to its own segment (edges included)", edgesOk)
	local counts: { number } = {}
	local prng = Prng.new(4242)
	local n = 100000
	for _ = 1, n do
		local i = WheelRules.pick(prng.next)
		counts[i] = (counts[i] or 0) + 1
	end
	local close = true
	for i, p in odds do
		if math.abs((counts[i] or 0) / n - p) > 0.006 then
			close = false
		end
	end
	expect("100k rolls match the intended drop rates (each within 0.6 points)", close)
	expect("The jackpot is the rarest segment", odds[#odds] == math.min(table.unpack(odds)))
	local stops = true
	for index = 1, #Config.Wheel.Segments do
		for _, jitter in { -1, -0.3, 0, 0.6, 1 } do
			if WheelRules.segmentAt(WheelRules.restingAngle(index, 5, jitter)) ~= index then
				stops = false
			end
		end
	end
	expect("The spin animation always stops on the segment the server rolled", stops)
	local to = WheelRules.restingAngle(3, 6, 0.4)
	local mid = WheelRules.spinAngle(10, to, 100, 5, 102.5)
	expect("spinAngle eases from the start angle to exactly the resting angle (shared by the 2D and 3D wheels)",
		WheelRules.spinAngle(10, to, 100, 5, 100) == 10 and WheelRules.spinAngle(10, to, 100, 5, 105) == to and WheelRules.spinAngle(10, to, 100, 5, 999) == to
			and mid > 10 + (to - 10) * 0.9 and mid < to and WheelRules.segmentAt(WheelRules.spinAngle(10, to, 100, 5, 105)) == 3)

	local c = ProfileTemplate.new(0)
	local cosmeticIndex = 0
	for i, segment in Config.Wheel.Segments do
		if segment.Kind == "Cosmetic" then
			cosmeticIndex = i
		end
	end
	local before = 0
	for _, count in c.OwnedItems do
		before += count
	end
	-- Force the cosmetic segment: rng that lands inside its weight band.
	local cum = 0
	for i = 1, cosmeticIndex - 1 do
		cum += Config.Wheel.Segments[i].Weight
	end
	local totalWeight = 0
	for _, segment in Config.Wheel.Segments do
		totalWeight += segment.Weight
	end
	local target = (cum + 0.5) / totalWeight
	local cr = WheelRules.spin(c, t0, function(): number
		return target
	end)
	local afterItems = 0
	for _, count in c.OwnedItems do
		afterItems += count
	end
	local item = if cr then ItemDatabase.get(cr.Reward.ItemId) else nil
	expect("Cosmetic segments grant a real, non-default item of that rarity", cr ~= nil and cr.Reward.Kind == "Cosmetic" and item ~= nil and not item.Default and item.Rarity == Config.Wheel.Segments[cosmeticIndex].Rarity and afterItems == before + 1)

	local junk = ProfileTemplate.new(0) :: any
	junk.Wheel = { LastFreeSpinAt = -5, ExtraSpins = 9999, TotalSpins = "x", Receipts = { "ok", 5, {} } }
	local fixed = ProfileTemplate.prepare(junk, 0)
	expect("Profile repair clamps wheel data", fixed ~= nil and fixed.Wheel.ExtraSpins == Config.Wheel.MaxStoredSpins and fixed.Wheel.LastFreeSpinAt == 0 and #fixed.Wheel.Receipts == 1)
	local old = ProfileTemplate.new(0) :: any
	old.Wheel = nil
	local filled = ProfileTemplate.prepare(old, 0)
	expect("Profiles saved before the wheel existed get an empty Wheel section", filled ~= nil and filled.Wheel.ExtraSpins == 0 and filled.Wheel.LastFreeSpinAt == 0)
end

print("-- cosmetics data")
do
	local problems = CosmeticsData.validate()
	for _, problem in problems do
		print("  " .. problem)
	end
	expect("Every cosmetic resolves to a complete look", #problems == 0)
	local gold = CosmeticsData.ball("ball_golden")
	local none = CosmeticsData.ball(nil)
	expect("Ball looks: material + glow per skin; unknown ids fall back to a plain white ball", gold.Material == "Foil" and gold.Glow and none.Material == "SmoothPlastic" and none.Color[1] == 240)
	local nova = CosmeticsData.trail("trail_nova")
	expect("Trails escalate from a streak to sparkles to a lagging Beam ribbon", CosmeticsData.trail("trail_chalk").Style == "Trail" and CosmeticsData.trail("trail_grass").Style == "Sparkle" and nova.Style == "Ribbon" and nova.ParticleRate > 0)
	local club = CosmeticsData.club("skin_crimson_longiron", "LongIron")
	local plain = CosmeticsData.club(nil, "Putter")
	expect("Club looks: skin colours/material, the category's head shape, template lookup order", club.HeadColor[1] == 190 and club.Material == "Metal" and club.Shape == "Iron" and club.TemplateNames[1] == "skin_crimson_longiron" and club.TemplateNames[2] == "LongIron" and plain.Shape == "Putter" and #plain.TemplateNames == 1)
	expect("Animations fall back to procedural poses until an AnimationId is set", CosmeticsData.animation("swing_samurai").AnimationId == "" and CosmeticsData.animation("swing_samurai").Pose == "Swing" and CosmeticsData.animation("emote_trophy").Pose == "Victory")
	expect("Hole effects scale with rarity", CosmeticsData.holeEffect("hole_supernova").Count > CosmeticsData.holeEffect("hole_confetti").Count)
end

print("-- assets")
do
	local allBlank = true
	for _, id in Assets.Images :: { [string]: string } do
		if Assets.isSet(id) then
			allBlank = false
		end
	end
	expect("Placeholder asset ids are detected as missing (UI falls back)", Assets.isSet("") == false and Assets.isSet("rbxassetid://0") == false and Assets.isSet((nil :: any)) == false and Assets.isSet("rbxassetid://12345") and Assets.image("CoinIcon") == nil)
	expect("No real asset ids are required to run (all fallbacks)", allBlank and Assets.animation("Swing") == nil)
	local slotsOk = true
	for _, move in { "Swing", "Putt", "Victory", "Defeat", "Address", "PuttAddress" } do
		local slot = Assets.Animations[move]
		if slot == nil or slot.R15 == nil or slot.R6 == nil or Assets.animation(move, "R6") ~= nil or Assets.animation(move, "R15") ~= nil then
			slotsOk = false
		end
	end
	expect("Every golf move has an R15 and an R6 animation slot (blank = procedural pose)", slotsOk)
	expect("Sounds fall back to built-in Roblox sounds until uploaded", string.sub(Assets.sound("CupDrop"), 1, 9) == "rbxasset:" and Assets.sound("Nope") == "")
end

print("-- putter meter (auto-scaled, linear)")
do
	local FT = Config.Swing.MetersPerFoot
	expect("The putter meter's full scale is 1.5x the putt, between 10 and 150 feet",
		math.abs(SwingMath.puttRange(20 * FT) - 30 * FT) < 1e-9 and math.abs(SwingMath.puttRange(2 * FT) - 10 * FT) < 1e-9 and math.abs(SwingMath.puttRange(300 * FT) - 150 * FT) < 1e-9)
	local flat = ShotPhysics.flatTerrain("Green")
	local putter = ClubDatabase.getSlot("PT") :: ClubDatabase.BagSlot
	local function rolled(power: number, holeFeet: number): number
		local shot = SwingMath.resolveShot({ Slot = putter, Stats = ClubStats.baseline(), Power = power, AccuracyOffset = 0, Lie = "Green", PuttRangeMeters = SwingMath.puttRange(holeFeet * FT) }, flat, nil)
		return shot.Result.FinalX / FT
	end
	local linear = true
	for _, holeFeet in { 4, 20, 60 } do
		local range = SwingMath.puttRange(holeFeet * FT) / FT
		for _, power in { 20, 50, 80, 100 } do
			if math.abs(rolled(power, holeFeet) - power / 100 * range) > range * 0.02 + 0.1 then
				linear = false
			end
		end
	end
	expect("Putter power is LINEAR in distance: p% rolls p% of the meter's range on a flat green (4, 20 and 60 ft putts)", linear)
	local tapIn = rolled(100 / 1.5, 3)
	expect("A 3-foot putt is no longer squeezed into the start of the meter: the hole sits at 2/3 power on a 10-ft scale", math.abs(tapIn - 6.67) < 0.3)
	local layout = GaugeView.layout({ Phase = "Power", Mode = "Putt", Power = 0.5, Needle = 0, LockedPower = nil }, 0.1, nil, { RangeFeet = 30, HoleFeet = 20 })
	local ticks = layout.PuttTicks :: { GaugeView.PuttTick }
	expect("Putt meter: tick marks labelled in feet at a round step, the hole marker at its distance, readout in feet",
		ticks ~= nil and #ticks == 7 and ticks[2].Label == "5" and math.abs(ticks[7].X - 1) < 1e-9
			and math.abs((layout.HoleX :: number) - 20 / 30) < 1e-9 and layout.PowerLabel == "15 FT" and layout.TargetPower == layout.HoleX)
	local wide = GaugeView.puttTicks(150)
	expect("Long putt scales use a wider tick step (never more than 8 ticks)", #wide <= 8 and #wide >= 4)
	local full = GaugeView.layout({ Phase = "Power", Mode = "Full", Power = 0.62, Needle = 0, LockedPower = nil }, 0.1, nil)
	expect("Full swings keep the percent readout and no putt ticks", full.PowerLabel == "62%" and full.PuttTicks == nil and full.HoleX == nil)
end

print("-- club seat (clubhead on the ground)")
do
	local toward: ClubSeat.Vec = { X = 1, Y = 0, Z = 0 }
	local function check(grip: ClubSeat.Vec, sole: ClubSeat.Vec, length: number): (boolean, ClubSeat.Seat)
		local seat = ClubSeat.solve(grip, sole, toward, length)
		return math.abs(ClubSeat.reach(grip, sole, toward, seat.Shift) - seat.Length) < 1e-9, seat
	end
	local fits, normal = check({ X = 0, Y = 3, Z = 0 }, { X = 2.5, Y = 0, Z = 0 }, 4.2)
	expect("A normal golfer: the club reaches the ground exactly behind the ball, no scaling", fits and normal.Scale == 1)
	local tooFar, far = check({ X = 0, Y = 3, Z = 0 }, { X = 6, Y = 0, Z = 0 }, 4.2)
	expect("Standing too far from the ball: the golfer slides closer (positive shift)", tooFar and far.Shift > 0)
	local tooClose, close = check({ X = 0, Y = 3, Z = 0 }, { X = 0.5, Y = 0, Z = 0 }, 4.2)
	expect("Standing too close: the golfer slides back (negative shift)", tooClose and close.Shift < 0)
	local tall, big = check({ X = 0, Y = 6, Z = 0 }, { X = 2.5, Y = 0, Z = 0 }, 4.2)
	expect("A tall avatar whose hands are higher than the club is long gets a longer club that still rests on the ground", tall and big.Scale > 1 and big.Length > 6)
	local uphill, up = check({ X = 0, Y = 3, Z = 0 }, { X = 2.5, Y = 0.8, Z = 0 }, 4.2)
	expect("On a slope (ground higher behind the ball) the sole still lands on the ground", uphill and up.Scale == 1)
end

for _, caseId in CaseDatabase.Order do
	print(`case {caseId}: expected sell value {CaseDatabase.expectedSellValue(caseId)} vs price {CaseDatabase.Cases[caseId].Price.Amount}`)
end

if failures > 0 then
	error(`{failures} check(s) failed`)
end
print("ALL CHECKS PASSED")
