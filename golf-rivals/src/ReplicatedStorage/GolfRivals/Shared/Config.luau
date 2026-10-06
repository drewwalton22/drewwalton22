--!strict
--[[
	Config.luau  (ReplicatedStorage.GolfRivals.Shared)

	Global tuning knobs. Everything a designer might want to rebalance lives
	here (not buried in system code). Sections are filled in as each system is
	built; swing physics, bots and quests get their own sections later.
]]

local Types = require(script.Parent.Types)

export type LeagueDef = {
	Id: string,
	DisplayName: string,
	EntryFee: number, -- coins each player pays to queue
	WinPayout: number, -- coins the winner receives
}

export type BotProfile = {
	Stats: { Distance: number, Accuracy: number, Forgiveness: number }, -- applied to every club
	PowerSigma: number, -- gauge execution noise, percentage points of power (std dev)
	OffsetSigma: number, -- gauge execution noise on the accuracy offset (std dev, offset units)
	BlunderChance: number, -- chance of a badly mistimed click (|offset| ~ 0.7)
	WindAwareness: number, -- 0..1 fraction of the real wind the bot accounts for when planning
	AimCandidates: { number }, -- aim offsets (degrees) the bot evaluates; picks the safest/closest
	ClubMistakeChance: number, -- chance of picking a neighbouring club
}

export type LieDef = {
	SpeedMult: number, -- multiplies ball speed when HITTING from this lie
	SpinMult: number, -- multiplies backspin when hitting from this lie
	AccuracyPenalty: number, -- 0..1 shrinks the green zone / amplifies curve (before Forgiveness)
	Restitution: number, -- vertical bounce: v_normal_out = Restitution * v_normal_in
	TangentRetain: number, -- fraction of along-surface speed kept after impact (before backspin check)
	RollFriction: number, -- rolling-resistance coefficient (decel = RollFriction * g)
	Sinks: boolean, -- true = ball is lost on contact (water)
}

local Config = {}

-- ECONOMY ---------------------------------------------------------------
Config.Economy = {
	StartingCoins = 2500,
	StartingGems = 0,
	-- Cap on cases opened in one request (the "Open x3" UI + anti-spam).
	MaxCasesPerOpen = 10,
	SellBatchMax = 200, -- most item entries in one Sell request
	-- Hard caps keep balances exact (doubles are exact below 2^53) and bound
	-- the damage of any future duplication bug.
	MaxCoins = 1e12,
	MaxGems = 1e9,
}

-- PLAYER DATA (DataStore) -----------------------------------------------
-- Session locking: a server writes its JobId + a timestamp into the record when
-- it loads a profile and refreshes the timestamp on every autosave. Another
-- server sees a lock younger than LockTimeoutSeconds and refuses to load (the
-- player is retried, then told to rejoin). A lock older than the timeout is
-- treated as a crashed server and may be taken over.
Config.Data = {
	StoreName = "GolfRivalsProfiles",
	KeyPrefix = "Player_",
	AutosaveSeconds = 60, -- must be well below LockTimeoutSeconds
	LockTimeoutSeconds = 600,
	LoadAttempts = 6, -- tries when the profile is locked or the DataStore errors
	LoadRetrySeconds = 3,
	ReleaseAttempts = 3,
	-- After a purchase/case/trade the server saves within this many seconds
	-- (debounced) instead of waiting for the next autosave.
	SaveSoonSeconds = 5,
}

-- DAILY ROTATING SHOP ---------------------------------------------------
-- Rotation index = floor(os.time() / RotationSeconds). Every server computes
-- the same index from the same clock, so all servers show the same shop with
-- no cross-server messaging. The server seeds an RNG with that index and
-- draws SlotsPerRarity items (from a deterministically sorted pool) per tier.
Config.Shop = {
	RotationSeconds = 24 * 60 * 60,
	SlotsPerRarity = {
		Common = 3,
		Uncommon = 3,
		Rare = 2,
		Unique = 2,
		Legendary = 1,
		Mythical = 1,
	} :: { [Types.RarityId]: number },
}

-- TRADE-UP CONTRACT -----------------------------------------------------
Config.TradeUp = {
	InputCount = 5, -- items consumed per contract
	-- true: all 5 inputs must share a category (club skins with club skins...)
	-- and the reward is rolled from that same category.
	RequireSameCategory = true,
}

-- CLUB UPGRADES ---------------------------------------------------------
-- Each club has three stats, each upgraded independently with coins.
--   stat(level) = min(StatCap, base + level * PointsPerUpgrade)
--   cost(level -> level+1) = round_to_50( CostBase * CostGrowth ^ level )
Config.Clubs = {
	StatCap = 100,
	MaxUpgradeLevel = 10,
	PointsPerUpgrade = 2,
	UpgradeCostBase = 500,
	UpgradeCostGrowth = 1.35,
	-- Overall (OVR) = weighted stat average. 0.4/0.3/0.3 reproduces the mockup:
	-- Distance 92, Accuracy 78, Forgiveness 85 -> 36.8 + 23.4 + 25.5 = 85.7 -> 86.
	OVRWeights = { Distance = 0.4, Accuracy = 0.3, Forgiveness = 0.3 },
}

-- 3-CLICK SWING --------------------------------------------------------
-- Click 1 starts the gauge, click 2 locks power, click 3 locks accuracy.
--   power marker:   m(t) = (t - t1) / RiseSeconds                 (0 -> 1)
--   after click 2:  marker falls back to the green zone's centre, reaching it
--                   at  tCenter = t2 + power * FallSeconds
--   accuracy:       offset = clamp((t3 - tCenter) / AccuracyWindowSeconds, -1, 1)
--                   offset < 0 = clicked EARLY = slice (curves right)
--                   offset > 0 = clicked LATE  = hook  (curves left)
-- Skill only: no random numbers anywhere in shot resolution.
Config.Swing = {
	RiseSeconds = 1.1, -- 0% -> 100% power takes this long
	FallSeconds = 0.9, -- 100% -> centre takes this long (scaled by locked power)
	AccuracyWindowSeconds = 0.30, -- |offset| = 1 at this many seconds from the centre
	MinPower = 1, -- percent; below this the swing is a whiff and is rejected

	-- Green zone (zero curve). Half-width in offset units, widened by Accuracy:
	--   greenHalfWidth = GreenHalfWidth + GreenWidthPerAccuracy * accuracy/100
	GreenHalfWidth = 0.05,
	GreenWidthPerAccuracy = 0.05,
	GoodHalfWidth = 0.35, -- "Good" quality band (UI feedback only)

	-- Outside the green zone, curve severity (0..1) =
	--   ((|offset| - green) / (1 - green)) ^ SidespinExponent * (1 - AccuracyMitigation * accuracy/100)
	-- and sidespin rpm = severity * MaxSidespinRpm.
	SidespinExponent = 1.4,
	AccuracyMitigation = 0.5,
	MaxSidespinRpm = 1800,
	MaxPuttAngleDeg = 4, -- putts: aim error at severity 1

	-- Power -> ball speed: speed = fullSpeed * (power/100) ^ PowerToSpeedExponent.
	-- Chosen empirically so carry% ~ power%: with 0.52, carry at 25/50/75% power
	-- lands within ~5 points of 25/50/75% of full carry for every club (verified
	-- in tools/verify_shared.luau). Re-run that check after touching Physics.
	PowerToSpeedExponent = 0.52,
	-- Distance stat: speed *= 1 + DistanceSpeedPerPoint * (distance - Baseline).
	-- BaseCarryYds in ClubDatabase is the carry AT the baseline stat.
	DistanceStatBaseline = 50,
	DistanceSpeedPerPoint = 0.0025,
	-- Forgiveness removes this fraction of a lie's AccuracyPenalty at stat 100.
	LieForgivenessReduction = 0.7,
	-- Putter: a 100% putt rolls this far on a flat green (before Distance stat).
	PuttFullPowerYards = 40,

	-- Anti-cheat: a submission faster than a human could have clicked is
	-- rejected (see SwingMath.minSwingSeconds). Tolerance absorbs network jitter.
	TimingToleranceSeconds = 0.35,
}

-- BALL FLIGHT PHYSICS (SI units: metres, seconds, kg; local frame:
-- +X downrange, +Y up, +Z right). The server is authoritative.
Config.Physics = {
	Gravity = 9.81,
	AirDensity = 1.225,
	BallMass = 0.04593,
	BallRadius = 0.02135,
	DragCoeff = 0.25,
	LiftPerSpin = 1.9, -- lift coefficient per unit spin parameter (Cl = LiftPerSpin * S)
	LiftCap = 0.30, -- max lift coefficient
	SpinDecayPerSec = 0.04, -- spin loses this fraction per second (exponential)
	TimeStep = 0.01, -- flight integration step
	RollTimeStep = 0.02, -- roll integration step
	SampleInterval = 0.05, -- trajectory sample spacing sent to the client
	MaxFlightSeconds = 15,
	MaxRollSeconds = 40,
	MaxBounces = 6,
	MinBounceSpeed = 1.0, -- m/s: below this normal speed the ball stops bouncing and rolls
	-- Landing check: tangent speed kept = TangentRetain * (1 - BackspinBrake * spin/SpinReference)
	-- (can go negative: a wedge on a green spins back), floored at MinTangentRetain.
	BackspinBrake = 0.9,
	SpinReferenceRpm = 8000,
	MinTangentRetain = -0.3,
	SpinImpactLoss = 0.6, -- spin multiplier after each bounce
	CupRadius = 0.054, -- metres (4.25 in hole)
	CupCaptureSpeed = 1.6, -- m/s: faster than this and the ball lips over the cup
	YardsToMeters = 0.9144,
	MphToMetersPerSec = 0.44704,
	MetersToFeet = 3.28084,
}

-- LIES / SURFACES -------------------------------------------------------
Config.Lies = {
	Tee = { SpeedMult = 1.0, SpinMult = 1.0, AccuracyPenalty = 0.0, Restitution = 0.45, TangentRetain = 0.7, RollFriction = 0.10, Sinks = false },
	Fairway = { SpeedMult = 1.0, SpinMult = 1.0, AccuracyPenalty = 0.0, Restitution = 0.45, TangentRetain = 0.7, RollFriction = 0.10, Sinks = false },
	Rough = { SpeedMult = 0.92, SpinMult = 0.6, AccuracyPenalty = 0.30, Restitution = 0.20, TangentRetain = 0.35, RollFriction = 0.45, Sinks = false },
	Sand = { SpeedMult = 0.84, SpinMult = 0.5, AccuracyPenalty = 0.45, Restitution = 0.05, TangentRetain = 0.05, RollFriction = 1.20, Sinks = false },
	Green = { SpeedMult = 1.0, SpinMult = 1.0, AccuracyPenalty = 0.0, Restitution = 0.35, TangentRetain = 0.60, RollFriction = 0.056, Sinks = false },
	Water = { SpeedMult = 1.0, SpinMult = 1.0, AccuracyPenalty = 0.0, Restitution = 0.0, TangentRetain = 0.0, RollFriction = 1.0, Sinks = true },
} :: { [Types.LieId]: LieDef }

-- MATCHES ---------------------------------------------------------------
-- Stroke play over HolesPerMatch consecutive holes; fewest total strokes wins,
-- equal totals draw (entry fees refunded). Turn order is "away plays first":
-- the ball farthest from the pin shoots next; the first tee goes to a coin toss,
-- later tees to whoever scored lower on the previous hole.
Config.Match = {
	HolesPerMatch = 3,
	TurnSeconds = 40, -- time to complete the 3 clicks before a timeout shot
	MaxTimeouts = 3, -- timeouts before a forfeit
	AutoShotPower = 60, -- a timed-out turn plays this (deliberately poor) shot...
	AutoShotOffset = 0.5, -- ...with this accuracy offset (a clear slice)
	FlightPadSeconds = 2.5, -- pause after the ball stops before the next turn starts
	MaxStrokesOverPar = 4, -- pick-up: a hole ends at par + this many strokes
	GimmeMeters = 0.6, -- a ball resting this close on the green is holed (costs 1 stroke)
	PenaltyStrokes = 1, -- water / out of bounds: replay from the same spot
	MaxWindMph = 15,
	MaxAimDegrees = 30, -- aim adjustment either side of the pin line
	BotThinkSeconds = { Min = 1.5, Max = 3.5 }, -- bots pause like a person would
	EndScreenSeconds = 6, -- results screen before the match is cleaned up
}

-- RANKED MATCHMAKING ----------------------------------------------------
-- Players queue per league and are paired by OVR. The acceptable OVR gap starts
-- at BaseOvrWindow and widens by WindowGrowthPerSecond while waiting, so nobody
-- waits forever but close matches are preferred.
Config.Matchmaking = {
	BaseOvrWindow = 10,
	WindowGrowthPerSecond = 2,
	MaxOvrWindow = 100,
	TickSeconds = 1,
}

-- AI BOTS ---------------------------------------------------------------
-- Practice mode (no entry fee, no coin payout - bots can't be farmed). Bots play
-- with the SAME physics as players: they plan a swing, then execute it with
-- human-like gauge error.
Config.Bots = {
	Easy = {
		Stats = { Distance = 50, Accuracy = 40, Forgiveness = 45 },
		PowerSigma = 9, OffsetSigma = 0.32, BlunderChance = 0.10, WindAwareness = 0.2,
		AimCandidates = { 0 }, ClubMistakeChance = 0.25,
	},
	Medium = {
		Stats = { Distance = 65, Accuracy = 60, Forgiveness = 60 },
		PowerSigma = 4, OffsetSigma = 0.14, BlunderChance = 0.03, WindAwareness = 0.6,
		AimCandidates = { -6, 0, 6 }, ClubMistakeChance = 0.08,
	},
	Hard = {
		Stats = { Distance = 85, Accuracy = 80, Forgiveness = 75 },
		PowerSigma = 1.5, OffsetSigma = 0.05, BlunderChance = 0.0, WindAwareness = 1.0,
		AimCandidates = { -8, -4, 0, 4, 8 }, ClubMistakeChance = 0.0,
	},
} :: { [string]: BotProfile }
Config.BotDifficulties = { "Easy", "Medium", "Hard" } :: { string }

-- RANKED LEAGUES --------------------------------------------------------
-- Both players pay EntryFee; the winner takes WinPayout.
--   WinPayout == 2 * EntryFee  -> zero-sum (the pot), no coins minted.
--   WinPayout >  2 * EntryFee  -> the difference is minted (a coin faucet).
-- Rookie/Amateur/Pro are zero-sum. Champion pays 25,000 on a 10,000 fee, so
-- it mints 5,000 coins per match (matches the design mockup). That is a
-- deliberate top-league reward; MaxPayoutMultiplier caps how generous any
-- league may get and DatabaseValidator rejects anything above it.
Config.LeagueRules = {
	MaxPayoutMultiplier = 2.5, -- WinPayout / EntryFee must be <= this
}
Config.Leagues = {
	{ Id = "Rookie", DisplayName = "Rookie League", EntryFee = 100, WinPayout = 200 },
	{ Id = "Amateur", DisplayName = "Amateur League", EntryFee = 500, WinPayout = 1000 },
	{ Id = "Pro", DisplayName = "Pro League", EntryFee = 2500, WinPayout = 5000 },
	{ Id = "Champion", DisplayName = "Champion League", EntryFee = 10000, WinPayout = 25000 },
} :: { LeagueDef }

return Config
