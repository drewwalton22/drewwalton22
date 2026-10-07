--!strict
--[[
	Assets.luau  (ReplicatedStorage.GolfRivals.Shared)

	One registry for every uploaded asset the game can use (images, animations).
	EVERY entry ships as "" (not uploaded yet) and the game is fully playable that
	way: each consumer has a built-in fallback -
	  * images     -> drawn with Frames / a Color3 (UI/AssetLoader)
	  * animations -> procedural poses (SwingPose + Match/GolferRig)
	So a missing, mistyped or moderated asset id can never break a screen or a swing.

	HOW TO ADD ART
	  1. Upload in Studio (Asset Manager / right-click a KeyframeSequence -> Save to
	     Roblox). The ready-made golf animations are in
	     ServerStorage > GolfRivals > AnimationsToPublish (docs/STUDIO_SETUP.md has
	     the click-by-click steps).
	  2. Paste the id here, e.g.  CoinIcon = "rbxassetid://1234567890".
	  3. Swing / Putt animations carry a marker named "Impact" on the frame where the
	     club meets the ball; the ball launches on that marker. Without the marker the
	     ball launches at Config.Match.SwingLeadSeconds.

	ANIMATIONS ARE PER RIG TYPE: an R15 animation can't move an R6 avatar (different
	body parts), so each move has an R15 and an R6 slot. A blank slot = the
	procedural pose (SwingPose), so every avatar always swings.
]]

local Assets = {}

-- UI images (ImageLabel.Image). "" = use the drawn fallback.
Assets.Images = {
	CoinIcon = "",
	GemIcon = "",
	-- Lobby side-menu tiles
	ShopTile = "",
	CasesTile = "",
	LoadoutTile = "",
	TradeUpTile = "",
	QuestsTile = "",
	LeaderboardTile = "",
	-- Big bottom buttons
	PlayButton = "",
}

-- Character animations (Animation.AnimationId) per rig type. "" = procedural.
-- File names in AnimationsToPublish: <Move>_R15 / <Move>_R6.
Assets.Animations = {
	Swing = { R15 = "", R6 = "" }, -- full swing; has an "Impact" marker
	Putt = { R15 = "", R6 = "" }, -- putting stroke; has an "Impact" marker
	Victory = { R15 = "", R6 = "" }, -- looped on the podium winner (when no emote is equipped)
	Defeat = { R15 = "", R6 = "" }, -- looped on the podium loser
	Address = { R15 = "", R6 = "" }, -- looped while lining up a full shot
	PuttAddress = { R15 = "", R6 = "" }, -- looped while lining up a putt
} :: { [string]: { R15: string, R6: string } }

-- Sound effects (Sound.SoundId). "" = the built-in Roblox sound in Sounds below.
Assets.SoundIds = {
	CupDrop = "", -- the ball rattling into the cup
	Swing = "", -- the club whooshing through the ball
}

-- Built-in sounds that ship with every Roblox client (always available).
Assets.BuiltInSounds = {
	CupDrop = "rbxasset://sounds/clickfast.wav",
	Swing = "rbxasset://sounds/swoosh.wav",
} :: { [string]: string }

-- True when `id` looks like a real asset reference. Placeholder values ("",
-- "rbxassetid://0", nil) are treated as missing.
function Assets.isSet(id: any): boolean
	if type(id) ~= "string" or id == "" then
		return false
	end
	local number = string.match(id, "^rbxassetid://(%d+)$") or string.match(id, "^https?://www%.roblox%.com/asset/%?id=(%d+)$")
	return number ~= nil and tonumber(number) ~= nil and (tonumber(number) :: number) > 0
end

function Assets.image(name: string): string?
	local id = (Assets.Images :: { [string]: string })[name]
	return if Assets.isSet(id) then id else nil
end

-- The uploaded animation for a move on a rig type ("R15" / "R6"), or nil.
function Assets.animation(name: string, rigType: string?): string?
	local slot = Assets.Animations[name]
	if slot == nil then
		return nil
	end
	local id = if rigType == "R6" then slot.R6 else slot.R15
	return if Assets.isSet(id) then id else nil
end

-- A sound id: the uploaded one if set, else the built-in fallback ("" if none).
function Assets.sound(name: string): string
	local id = (Assets.SoundIds :: { [string]: string })[name]
	if Assets.isSet(id) then
		return id
	end
	return Assets.BuiltInSounds[name] or ""
end

return Assets
