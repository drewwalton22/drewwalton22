--!strict
--[[
	ClubSeat.luau  (ReplicatedStorage.GolfRivals.Shared)

	Where a golfer must stand so the CLUBHEAD RESTS ON THE GROUND right behind the
	ball, for any club length and any avatar height (pure math, tested offline;
	Client/Golf/GolferRig applies it).

	After the address pose is on, the hands hold the grip at point H. The sole of
	the club must touch the ground point S (just behind the ball, at the real
	ground height there - slopes included). The club is rigid with length L
	(grip -> sole), so we need |S - H'| = L where H' is the grip after sliding the
	golfer by `shift` studs along `toward` (the horizontal direction from the
	golfer to the ball):

	    w = S - H,  |w - shift * toward|^2 = L^2
	    shift = (w . toward) - sqrt((w . toward)^2 - |w|^2 + L^2)

	(the smaller root: the golfer moves as little as possible). If no real root
	exists the club is too short for this golfer's hands - a tall avatar - so the
	club is scaled up just enough (`scale`), and the golfer is placed with it.
]]

export type Vec = { X: number, Y: number, Z: number }

export type Seat = {
	Shift: number, -- studs to slide the golfer along `toward` (+ = closer to the ball)
	Scale: number, -- club scale factor (1 = as built)
	Length: number, -- the club's length after scaling
}

local ClubSeat = {}

ClubSeat.MIN_REACH = 0.6 -- studs: keep at least this much horizontal reach (no vertical clubs)

local function dot(a: Vec, b: Vec): number
	return a.X * b.X + a.Y * b.Y + a.Z * b.Z
end

-- `grip` H, `sole` S, `toward` unit horizontal vector golfer -> ball, `length` L.
function ClubSeat.solve(grip: Vec, sole: Vec, toward: Vec, length: number): Seat
	local w: Vec = { X = sole.X - grip.X, Y = sole.Y - grip.Y, Z = sole.Z - grip.Z }
	local along = dot(w, toward)
	local height = math.abs(w.Y)
	local scale = 1
	local l = length
	-- The club must at least reach the ground with some horizontal reach left over.
	local needed = math.sqrt(height * height + ClubSeat.MIN_REACH * ClubSeat.MIN_REACH)
	if l < needed then
		scale = needed / length
		l = needed
	end
	local disc = along * along - dot(w, w) + l * l
	local shift = along - math.sqrt(math.max(disc, 0))
	return { Shift = shift, Scale = scale, Length = l }
end

-- The grip -> sole distance after the shift (for tests / sanity checks).
function ClubSeat.reach(grip: Vec, sole: Vec, toward: Vec, shift: number): number
	local x = sole.X - (grip.X + toward.X * shift)
	local y = sole.Y - (grip.Y + toward.Y * shift)
	local z = sole.Z - (grip.Z + toward.Z * shift)
	return math.sqrt(x * x + y * y + z * z)
end

return ClubSeat
