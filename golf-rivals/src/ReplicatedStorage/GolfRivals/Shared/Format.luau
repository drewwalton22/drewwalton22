--!strict
--[[
	Format.luau  (ReplicatedStorage.GolfRivals.Shared)

	Text formatting for the UI, in one place so every screen prints numbers the same
	way ("12,450", "278 YDS", "02:15:09", "-1 Birdie").
]]

local Format = {}

-- 1234567 -> "1,234,567"  (rounds toward zero; negative numbers keep their sign)
function Format.commas(n: number): string
	local whole = if n >= 0 then math.floor(n) else math.ceil(n)
	local negative = whole < 0
	local digits = tostring(math.abs(whole))
	local out = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if out:sub(1, 1) == "," then
		out = out:sub(2)
	end
	return (if negative then "-" else "") .. out
end

function Format.yards(n: number): string
	return Format.commas(math.floor(n + 0.5)) .. " YDS"
end

function Format.feet(n: number): string
	return Format.commas(math.floor(n + 0.5)) .. " FT"
end

function Format.rpm(n: number): string
	return Format.commas(math.floor(n + 0.5)) .. " RPM"
end

function Format.mph(n: number): string
	return string.format("%.0f MPH", n)
end

-- 75 -> "1:15"
function Format.clock(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

-- 8109 -> "02:15:09" (shop rotation countdown)
function Format.countdown(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d:%02d", s // 3600, (s % 3600) // 60, s % 60)
end

-- Score relative to par as a signed number: 0 -> "E", -2 -> "-2", +3 -> "+3".
function Format.relative(strokes: number, par: number): string
	local diff = strokes - par
	if diff == 0 then
		return "E"
	end
	return (if diff > 0 then "+" else "") .. tostring(diff)
end

-- Golf names for a finished hole.
function Format.scoreName(strokes: number, par: number): string
	if strokes == 1 then
		return "Hole in One!"
	end
	local diff = strokes - par
	if diff <= -3 then
		return "Albatross"
	elseif diff == -2 then
		return "Eagle"
	elseif diff == -1 then
		return "Birdie"
	elseif diff == 0 then
		return "Par"
	elseif diff == 1 then
		return "Bogey"
	elseif diff == 2 then
		return "Double Bogey"
	end
	return "+" .. tostring(diff)
end

-- 1 -> "1st", 2 -> "2nd", 11 -> "11th"
function Format.ordinal(n: number): string
	local mod100 = n % 100
	local suffix = "th"
	if mod100 < 11 or mod100 > 13 then
		local mod10 = n % 10
		suffix = if mod10 == 1 then "st" elseif mod10 == 2 then "nd" elseif mod10 == 3 then "rd" else "th"
	end
	return tostring(n) .. suffix
end

return Format
