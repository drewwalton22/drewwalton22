--!strict
--[[
	Reasons.luau  (Client/Lobby)

	Turns the machine-readable `reason` codes the server returns into messages a
	player can act on.
]]

local Reasons = {}

local TEXT: { [string]: string } = {
	insufficient_funds = "Not enough coins or gems.",
	no_spins = "No spins left - come back tomorrow or buy one!",
	max_spins = "You already have the maximum number of stored spins.",
	already_spinning = "The wheel is still spinning.",
	already_purchased = "You already bought that today.",
	not_in_shop = "That offer is no longer in the shop.",
	unknown_item = "That item doesn't exist.",
	not_owned = "You don't own that.",
	insufficient_spare = "Your equipped or starter copy can't be used.",
	bad_count = "Pick between 1 and 10 cases.",
	bad_items = "Nothing valid to sell.",
	bad_inputs = "A trade-up needs exactly 5 items.",
	unknown_case = "That case doesn't exist.",
	max_level = "Already at the maximum level.",
	stat_capped = "That stat is already maxed out.",
	bad_stat = "That stat can't be upgraded.",
	already_owned = "You already own that club.",
	not_for_sale = "That club isn't for sale.",
	unknown_club = "That club doesn't exist.",
	mixed_rarity = "All five items must share a rarity.",
	mixed_category = "All five items must be the same type.",
	max_rarity = "Mythical items can't be traded up.",
	no_reward_pool = "No reward is available for that trade.",
	rate_limited = "Slow down a moment!",
	server_error = "Something went wrong. Please try again.",
	internal_error = "Something went wrong. Please try again.",
	not_loaded = "Your data is still loading.",
	unknown_league = "That league doesn't exist.",
	already_busy = "You're already queued or in a match.",
	not_queued = "You aren't in a queue.",
	bad_difficulty = "Pick Easy, Medium or Hard.",
	not_complete = "That quest isn't finished yet.",
	already_claimed = "Reward already claimed.",
	not_active = "That quest isn't active any more.",
	unknown_quest = "That quest doesn't exist.",
	not_in_match = "You aren't in a match.",
	-- Driving range
	busy = "Leave the queue or match first.",
	unknown_bay = "That bay doesn't exist.",
	bay_taken = "Someone is using that bay. Try another one.",
	no_character = "Your character is still loading.",
	too_far = "Walk up to the bay first.",
	no_bay = "Take a bay at the driving range first.",
	bad_club = "Pick a club (no putting at the range).",
	bad_aim = "Aim further toward the targets.",
	ball_not_ready = "Wait for the next ball.",
	too_fast = "Swing again - that was too quick.",
	bad_power = "Swing again.",
	bad_offset = "Swing again.",
	power_too_low = "Give it a bit more power.",
	putter_only_on_green = "On the green you putt.",
}

function Reasons.text(reason: any): string
	if type(reason) == "string" then
		return TEXT[reason] or "That didn't work."
	end
	return "That didn't work."
end

return Reasons
