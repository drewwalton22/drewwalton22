--!strict
-- verify_features.luau: offline checks for the newer features (podium emotes,
-- wheel geometry, cosmetic models ...). Run by tools/check.sh after
-- verify_shared.luau (which hit luau-analyze's per-file complexity limit).

local Assets = require("./Assets")
local CosmeticsData = require("./CosmeticsData")
local ItemDatabase = require("./ItemDatabase")

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

if failures > 0 then
	error(`{failures} feature check(s) failed`)
end
print("ALL FEATURE CHECKS PASSED")
