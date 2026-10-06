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
	  1. Upload in Studio (Asset Manager / Animation Editor -> Publish).
	  2. Paste the id here, e.g.  CoinIcon = "rbxassetid://1234567890".
	  3. For the swing animation, add an animation event (marker) named "Impact" on the
	     frame where the club meets the ball; the ball launches on that marker. Without
	     the marker the ball launches at Config.Match.SwingLeadSeconds.
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

-- Character animations (Animation.AnimationId). "" = procedural fallback.
Assets.Animations = {
	Swing = "", -- full swing; needs an "Impact" marker
	Putt = "", -- putting stroke; needs an "Impact" marker
	Victory = "", -- looped on the podium winner
	Defeat = "", -- looped on the podium loser
	Address = "", -- looped while lining up a shot
}

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

function Assets.animation(name: string): string?
	local id = (Assets.Animations :: { [string]: string })[name]
	return if Assets.isSet(id) then id else nil
end

return Assets
