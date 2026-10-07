--!strict
-- verify_features.luau: offline checks for the newer features (podium emotes,
-- wheel geometry, cosmetic models ...). Run by tools/check.sh after
-- verify_shared.luau (which hit luau-analyze's per-file complexity limit).

local Assets = require("./Assets")
local CosmeticsData = require("./CosmeticsData")
local Config = require("./Config")
local CosmeticModels = require("./CosmeticModels")
local ItemDatabase = require("./ItemDatabase")
local WheelRules = require("./WheelRules")

local failures = 0
local function expect(label: string, condition: any)
	if condition then
		print("  PASS  " .. label)
	else
		failures += 1
		print("  FAIL  " .. label)
	end
end

print("-- victory emotes (podium cosmetics)")
do
	-- Victory emotes are cosmetics: one free default, the rest sold in the shop / case.
	local emoteIds: { string } = {}
	local defaults = 0
	for _, item in ItemDatabase.Ordered do
		if item.Slot == "Emote" then
			table.insert(emoteIds, item.Id)
			if item.Default then
				defaults += 1
			end
		end
	end
	local default = ItemDatabase.get(CosmeticsData.DEFAULT_EMOTE)
	expect("Victory emotes: exactly one default (Fist Pump) that everyone owns, the rest purchasable", defaults == 1 and default ~= nil and default.Default and #emoteIds >= 5)
	local allBuiltIn = true
	for _, id in emoteIds do
		for _, rig in { "R15", "R6" } do
			local look = CosmeticsData.animation(id, rig)
			local builtIn = false
			for _, v in CosmeticsData.BuiltInEmotes[rig] do
				if v == look.AnimationId then
					builtIn = true
				end
			end
			if not builtIn or look.Pose ~= "Victory" then
				allBuiltIn = false
			end
		end
	end
	expect("Every victory emote plays a built-in Roblox emote for its body type until you publish your own", allBuiltIn)
	local r15 = CosmeticsData.animation(CosmeticsData.DEFAULT_EMOTE, "R15")
	local r6 = CosmeticsData.animation(CosmeticsData.DEFAULT_EMOTE, "R6")
	expect("R15 and R6 golfers get the matching emote asset", r15.AnimationId == CosmeticsData.BuiltInEmotes.R15.cheer and r6.AnimationId == CosmeticsData.BuiltInEmotes.R6.cheer)
	expect("Bots always use the procedural victory pose", CosmeticsData.animation("emote_moonwalk", "Bot").AnimationId == "" and CosmeticsData.animation("emote_moonwalk", "Bot").Pose == "Victory")
	local saved = Assets.Animations.Victory.R15
	Assets.Animations.Victory.R15 = "rbxassetid://123456"
	local published = CosmeticsData.animation(CosmeticsData.DEFAULT_EMOTE, "R15").AnimationId
	Assets.Animations.Victory.R15 = saved
	expect("Once the Victory animation is published, the default emote plays it", published == "rbxassetid://123456")
	expect("Rarer emotes add podium flair (Legendary sparkle, Mythical aura)", CosmeticsData.animation("emote_ascension", "R15").Effect == "Aura" and CosmeticsData.animation("emote_trophy", "R15").Effect == "Sparkle" and CosmeticsData.animation("emote_fistpump", "R15").Effect == "None")
	local inPool = 0
	for _, items in ItemDatabase.ShopPool do
		for _, item in items do
			if item.Slot == "Emote" then
				inPool += 1
			end
		end
	end
	expect("Every non-default victory emote can appear in the daily shop", inPool == #emoteIds - 1)
end


print("-- daily wheel drawing (exact wedges, pointer, layout)")
do
	local n = #Config.Wheel.Segments
	local width = 360 / n
	-- What the face SHOULD show at screen angle theta when turned by `rotation`.
	local function truth(rotation: number, theta: number): number
		return math.floor(((theta - rotation) % 360) / width) % n + 1
	end
	local exact = true
	local perHalfOk = true
	local rotation = 0
	while rotation < 720 do
		local pieces = WheelRules.wedgePieces(rotation)
		local counts: { [string]: number } = { Right = 0, Left = 0 }
		for _, piece in pieces do
			counts[piece.Half] += 1
		end
		if counts.Right > n or counts.Left > n then
			perHalfOk = false
		end
		local theta = 0.25
		while theta < 360 do
			-- Skip a hair either side of a boundary (anti-aliasing territory).
			local offset = (theta - rotation) % width
			if offset > 0.05 and offset < width - 0.05 and WheelRules.paintedAt(pieces, theta) ~= truth(rotation, theta) then
				exact = false
			end
			theta += 0.5
		end
		rotation += 7.3
	end
	expect("Stacked half-disc wedges paint every segment exactly where it belongs, at any wheel angle", exact)
	expect("Never more pieces in a half than there are segments (enough frames pre-built)", perHalfOk)

	local landed = true
	for index = 1, n do
		for turns = 5, 7 do
			for _, jitter in { -1, -0.5, 0, 0.5, 1 } do
				local angle = WheelRules.restingAngle(index, turns, jitter)
				local pieces = WheelRules.wedgePieces(angle)
				if WheelRules.segmentAt(angle) ~= index or WheelRules.paintedAt(pieces, 0.01) ~= index or WheelRules.paintedAt(pieces, 359.99) ~= index then
					landed = false
				end
			end
		end
	end
	expect("The pointer (12 o'clock) always rests on the DRAWN wedge of the rolled prize (any turns, any jitter)", landed)

	local aimed = true
	for _, start in { 0, 12.5, 45, 90, 135, 179.9, 180, 225, 300, 359 } do
		-- UIGradient Rotation r shows the half-disc centred at 270 + r degrees.
		if ((270 + WheelRules.halfDiscRotation(start)) - (start + 90)) % 360 > 1e-9 then
			aimed = false
		end
	end
	expect("Each half-disc's gradient is aimed so it covers [start, start + 180]", aimed)

	local layout = WheelRules.layout()
	expect("Icon, amount and COINS/GEMS/ITEM text fit inside their wedge, clear of the hub and rim pegs", WheelRules.slotFits(layout.Icon) and WheelRules.slotFits(layout.Label) and WheelRules.slotFits(layout.Kind))
	expect("Wheel text stays readable (amount at least 12% of the wheel wide)", layout.Label.Width >= 0.12 and layout.Icon.Width >= 0.08)
end


print("-- code-built cosmetic models")
do
	local BALL_CLEARANCE = 0.55 -- GolferRig: ball centre to the sole point
	local BALL_RADIUS = 0.4
	local seated = true
	local grounded = true
	local signatures: { [string]: boolean } = {}
	local distinct = true
	for _, class in CosmeticModels.classes() do
		for _, rarity in { "Common", "Uncommon", "Rare", "Unique", "Legendary", "Mythical" } do
			local spec = CosmeticModels.club(class, rarity)
			local lead = CosmeticModels.faceX(spec) - spec.Sole.X
			if lead < 0 or lead > BALL_CLEARANCE - BALL_RADIUS then
				seated = false
				print(`  {class} {rarity}: face {lead} ahead of the sole`)
			end
			if CosmeticModels.bottomY(spec) < spec.Sole.Y - 0.01 then
				grounded = false
				print(`  {class} {rarity}: dips {spec.Sole.Y - CosmeticModels.bottomY(spec)} below the sole`)
			end
		end
		local common = CosmeticModels.club(class, "Common")
		local names: { string } = {}
		for _, p in common.Pieces do
			table.insert(names, `{p.Name}:{p.Shape}:{string.format("%.2f", p.Size.X)}x{string.format("%.2f", p.Size.Y)}`)
		end
		local key = table.concat(names, ",")
		if signatures[key] then
			distinct = false
		end
		signatures[key] = true
	end
	expect("Every clubhead's face stops short of the ball when its sole rests behind it (all classes, all rarities)", seated)
	expect("No clubhead part dips below its sole (the club rests ON the ground)", grounded)
	expect("Each club category has its own distinct head model", distinct)
	local lofts = true
	local order = { "Driver", "FairwayWood", "LongIron", "ShortIron", "Wedge" }
	for i = 2, #order do
		if CosmeticModels.club(order[i], "Common").Loft <= CosmeticModels.club(order[i - 1], "Common").Loft then
			lofts = false
		end
	end
	expect("Lofts rise from driver to wedge; the putter is nearly upright", lofts and CosmeticModels.club("Putter", "Common").Loft < 5)

	local function count(spec: CosmeticModels.ClubSpec): number
		return #spec.Pieces
	end
	local grows = true
	local previous = 0
	for _, rarity in { "Common", "Uncommon", "Rare", "Unique", "Legendary", "Mythical" } do
		local n = count(CosmeticModels.club("Driver", rarity))
		if n < previous then
			grows = false
		end
		previous = n
	end
	local common, mythical = CosmeticModels.tier("Common"), CosmeticModels.tier("Mythical")
	local legendary, unique = CosmeticModels.tier("Legendary"), CosmeticModels.tier("Unique")
	expect("Rarer clubs get more detail (pieces never decrease with rarity)", grows and count(CosmeticModels.club("Driver", "Mythical")) > count(CosmeticModels.club("Driver", "Common")))
	expect("Only Legendary and Mythical glow, sparkle and leave a swing trail; only Mythical pulses", legendary.Glow and legendary.Sparkles and legendary.SwingTrail and not legendary.Pulse
		and mythical.Pulse and not unique.Glow and not common.Glow and unique.Neon and not common.Neon)

	local patterned = CosmeticModels.patternedBalls()
	local allBalls = true
	for _, item in ItemDatabase.Ordered do
		if item.Slot == "BallModel" and not table.find(patterned, item.Id) then
			allBalls = false
		end
	end
	local blackhole = CosmeticModels.ball("ball_blackhole")
	expect("Every ball cosmetic has its own pattern; the Black Hole has a spinning accretion disc", allBalls and blackhole.Disc ~= nil and blackhole.SpinRate ~= 0)
	expect("Unknown balls fall back to a plain sphere", #CosmeticModels.ball("nope").Bands == 0 and CosmeticModels.ball(nil).Disc == nil)
end

if failures > 0 then
	error(`{failures} feature check(s) failed`)
end
print("ALL FEATURE CHECKS PASSED")
