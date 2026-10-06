--!strict
--[[
	WheelRules.luau  (ReplicatedStorage.GolfRivals.Shared)

	The daily wheelspin's rules, pure and tested. The server's WheelService calls
	these on the real profile; the client uses `state`/`odds` for display only.

	  state(data, now)       free spin ready? seconds until it is, bought spins left
	  pick(rng)              weighted segment choice:
	                           P(segment) = Weight / sum(Weights)
	  spin(data, now, rng)   uses the FREE spin when ready (LastFreeSpinAt = now,
	                         i.e. the 24 h cooldown restarts), else one bought spin;
	                         rolls a segment and grants it:
	                           Coins / Gems  -> ProfileOps.add (counts as earned)
	                           Cosmetic      -> a random non-default item of the
	                                            segment's rarity (rng-picked)
	  buyWithGems(data)      spends GemSpinPrice gems for one stored spin
	  grantPurchase(data, purchaseId)
	                         Robux receipt -> RobuxSpinsPerPurchase stored spins,
	                         exactly once per PurchaseId (receipt ids are remembered,
	                         so a re-delivered receipt never grants twice)
]]

local Config = require(script.Parent.Config)
local ItemDatabase = require(script.Parent.ItemDatabase)
local ProfileOps = require(script.Parent.ProfileOps)
local ProfileTemplate = require(script.Parent.ProfileTemplate)

type ProfileData = ProfileTemplate.ProfileData

export type State = {
	FreeReady: boolean,
	SecondsUntilFree: number,
	ExtraSpins: number,
	CanSpin: boolean,
}

export type Reward = {
	Kind: "Coins" | "Gems" | "Cosmetic",
	Amount: number?,
	ItemId: string?,
}

export type SpinResult = {
	SegmentIndex: number,
	SegmentId: string,
	Reward: Reward,
	UsedFree: boolean,
}

local WheelRules = {}

local W = Config.Wheel

function WheelRules.state(data: ProfileData, now: number): State
	local wait = math.max(0, data.Wheel.LastFreeSpinAt + W.CooldownSeconds - now)
	local free = wait <= 0
	return {
		FreeReady = free,
		SecondsUntilFree = wait,
		ExtraSpins = data.Wheel.ExtraSpins,
		CanSpin = free or data.Wheel.ExtraSpins > 0,
	}
end

-- Each segment's chance in percent (for the odds list).
function WheelRules.odds(): { number }
	local total = 0
	for _, segment in W.Segments do
		total += segment.Weight
	end
	local list: { number } = {}
	for _, segment in W.Segments do
		table.insert(list, segment.Weight / total * 100)
	end
	return list
end

-- Weighted pick; `rng()` returns [0, 1).
function WheelRules.pick(rng: () -> number): number
	local total = 0
	for _, segment in W.Segments do
		total += segment.Weight
	end
	local roll = rng() * total
	for index, segment in W.Segments do
		roll -= segment.Weight
		if roll < 0 then
			return index
		end
	end
	return #W.Segments
end

local function grant(data: ProfileData, segment: Config.WheelSegment, rng: () -> number): Reward
	if segment.Kind == "Cosmetic" then
		local pool: { ItemDatabase.Item } = {}
		for _, item in ItemDatabase.Ordered do
			if item.Rarity == segment.Rarity and not item.Default then
				table.insert(pool, item)
			end
		end
		if #pool > 0 then
			local item = pool[math.clamp(math.floor(rng() * #pool) + 1, 1, #pool)]
			ProfileOps.grantItem(data, item.Id, 1)
			return { Kind = "Cosmetic", ItemId = item.Id }
		end
		-- No such items: pay a consolation in coins instead of nothing.
		ProfileOps.add(data, "Coins", 1000)
		return { Kind = "Coins", Amount = 1000 }
	end
	local amount = segment.Amount or 0
	ProfileOps.add(data, segment.Kind, amount)
	return { Kind = segment.Kind, Amount = amount }
end

function WheelRules.spin(data: ProfileData, now: number, rng: () -> number): (SpinResult?, string?)
	local state = WheelRules.state(data, now)
	if not state.CanSpin then
		return nil, "no_spins"
	end
	local usedFree = state.FreeReady
	if usedFree then
		data.Wheel.LastFreeSpinAt = now
	else
		data.Wheel.ExtraSpins -= 1
	end
	data.Wheel.TotalSpins += 1
	local index = WheelRules.pick(rng)
	local segment = W.Segments[index]
	return {
		SegmentIndex = index,
		SegmentId = segment.Id,
		Reward = grant(data, segment, rng),
		UsedFree = usedFree,
	}, nil
end

-- Wheel drawing convention: segment i is centred at (i - 0.5) * 360/n degrees,
-- clockwise from the pointer at the top. To stop with segment `index` under the
-- pointer the wheel turns to:
--   angle = -(centre(index) + jitter * 0.8 * halfWidth) + 360 * fullTurns  (degrees)
-- `jitter` in [-1, 1] lands it off-centre (but always inside the segment).
function WheelRules.segmentCentre(index: number): number
	return (index - 0.5) * 360 / #W.Segments
end

function WheelRules.restingAngle(index: number, fullTurns: number, jitter: number): number
	local half = 180 / #W.Segments
	return -(WheelRules.segmentCentre(index) + math.clamp(jitter, -1, 1) * 0.8 * half) + 360 * fullTurns
end

-- Which segment is under the pointer when the wheel is at `angle` degrees.
function WheelRules.segmentAt(angle: number): number
	local n = #W.Segments
	local underPointer = (-angle) % 360
	return math.floor(underPointer / (360 / n)) % n + 1
end

function WheelRules.buyWithGems(data: ProfileData): (boolean, string?)
	if data.Wheel.ExtraSpins >= W.MaxStoredSpins then
		return false, "max_spins"
	end
	local ok, why = ProfileOps.spend(data, { Currency = "Gems", Amount = W.GemSpinPrice })
	if not ok then
		return false, why
	end
	data.Wheel.ExtraSpins += 1
	return true, nil
end

-- Returns true if this purchase granted spins now, false if it was already granted.
function WheelRules.grantPurchase(data: ProfileData, purchaseId: string): boolean
	if table.find(data.Wheel.Receipts, purchaseId) then
		return false
	end
	table.insert(data.Wheel.Receipts, purchaseId)
	while #data.Wheel.Receipts > 50 do
		table.remove(data.Wheel.Receipts, 1)
	end
	data.Wheel.ExtraSpins = math.min(W.MaxStoredSpins, data.Wheel.ExtraSpins + W.RobuxSpinsPerPurchase)
	return true
end

return WheelRules
