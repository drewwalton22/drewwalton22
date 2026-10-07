--!strict
-- ROBLOX-ONLY: camera, input and world reticle. The distance / angle limits are
-- the pure, tested AimMath module.
--[[
	AerialAim.luau  (Client/Golf)

	AIMING with a target reticle and two camera views.

	  begin(...)            a glowing reticle sits on the ground where the ball
	                        should land; the camera smooth-tweens to the current view
	  VIEWS (toggle: V key or the HUD's VIEW button)
	    "Aerial"            top-down, centred above the landing area. Its HEIGHT
	                        follows the terrain: it always clears the highest ground
	                        between the ball and the target (hills, a cliff-top tee)
	    "Behind"            behind the golfer, looking down the line at the target
	  drag / tap            move the reticle in either view (mouse drag, touch drag,
	                        or click a spot); it is clamped by AimMath to
	                          distance <= ClubStats.maxDistanceYds(current club)
	                          angle    <= +/- MaxAimDegrees from the pin line
	                        and an arc of markers on the ground shows the club's
	                        maximum reach across the allowed angle
	  arrow keys            fine-tune: left / right = aim, up / down = distance
	  mouse wheel           zoom the aerial camera
	  setInteractive(false) the reticle stays on the ground but input stops (the
	                        swing stage); the caller moves the camera

	The reticle tilts to the ground under it, so it lies flat on slopes.

	Coordinates: everything is in the course frame (metres) of whoever uses it - the
	match hole frame or the driving-range frame - through the `Frame` callbacks.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local AimMath = require(ReplicatedStorage.GolfRivals.Shared.AimMath)

local CameraController = require(script.Parent.Parent.Match.CameraController)

export type Frame = {
	toWorld: (x: number, y: number, z: number) -> Vector3, -- course metres -> world studs
	toCourse: (world: Vector3) -> (number, number), -- world studs -> course (x, z) metres
	groundAt: (x: number, z: number) -> Vector3, -- world point on the ground at course (x, z)
	Include: { Instance }, -- what drag rays may hit (e.g. workspace.Terrain + course parts);
	                       -- a miss falls back to the ball's height plane
}

export type Limits = {
	BallX: number,
	BallZ: number,
	PinHeadingRad: number, -- ball -> pin direction (course frame)
	MaxMeters: number, -- the club's full distance
	MaxAimDeg: number,
}

export type View = "Aerial" | "Behind"

export type Aim = {
	begin: (limits: Limits, startX: number?, startZ: number?) -> (),
	setLimits: (limits: Limits) -> (), -- club / lie changed: re-clamp the reticle
	reticle: () -> AimMath.Reticle?,
	setInteractive: (on: boolean) -> (),
	nudge: (deltaDeg: number, deltaFraction: number) -> (), -- rotate / stretch the reticle
	focusCamera: () -> (), -- (re)frame the camera for the current view
	view: () -> View,
	toggleView: () -> View,
	hide: () -> (),
	destroy: () -> (),
}

local AerialAim = {}

local RETICLE_COLOR = Color3.fromRGB(255, 226, 92)
local CLAMPED_COLOR = Color3.fromRGB(255, 150, 80)
local REACH_COLOR = Color3.fromRGB(120, 230, 255)
local NUDGE_DEG = 1
local NUDGE_FRACTION = 0.03
local REACH_MARKERS = 25

local function flatDisc(name: string, color: Color3, transparency: number, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = Enum.PartType.Cylinder
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = transparency
	part.Size = Vector3.new(0.2, 4, 4)
	part.Parent = parent
	return part
end

-- onChanged(reticle, final): every move (final = the drag ended / a key nudge).
-- onView(view): the camera view changed (to update a HUD button).
function AerialAim.new(parent: Instance, frame: Frame, onChanged: (reticle: AimMath.Reticle, final: boolean) -> (), onView: ((view: View) -> ())?): Aim
	local folder = Instance.new("Folder")
	folder.Name = "AerialAim"
	folder.Parent = parent

	local ring = flatDisc("Reticle", RETICLE_COLOR, 0.15, folder)
	local core = flatDisc("ReticleCore", Color3.new(1, 1, 1), 0.1, folder)
	local markers: { Part } = {}
	for i = 1, REACH_MARKERS do
		local dot = Instance.new("Part")
		dot.Name = `Reach_{i}`
		dot.Shape = Enum.PartType.Ball
		dot.Anchored = true
		dot.CanCollide = false
		dot.CanQuery = false
		dot.CanTouch = false
		dot.CastShadow = false
		dot.Material = Enum.Material.Neon
		dot.Color = REACH_COLOR
		dot.Transparency = 1
		dot.Parent = folder
		markers[i] = dot
	end
	local label = Instance.new("BillboardGui")
	label.Name = "Distance"
	label.Size = UDim2.fromOffset(140, 36)
	label.StudsOffsetWorldSpace = Vector3.new(0, 6, 0)
	label.AlwaysOnTop = true
	label.LightInfluence = 0
	label.Adornee = ring
	label.Parent = ring
	local labelText = Instance.new("TextLabel")
	labelText.Size = UDim2.fromScale(1, 1)
	labelText.BackgroundTransparency = 1
	labelText.Font = Enum.Font.GothamBlack
	labelText.TextScaled = true
	labelText.TextColor3 = Color3.new(1, 1, 1)
	labelText.TextStrokeTransparency = 0.3
	labelText.Parent = label

	local limits: Limits? = nil
	local current: AimMath.Reticle? = nil
	local interactive = false
	local dragging = false
	local zoom = 1.0
	local visible = false
	local view: View = "Aerial"

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = frame.Include
	params.IgnoreWater = false

	local function setVisible(on: boolean)
		visible = on
		ring.Transparency = if on then 0.15 else 1
		core.Transparency = if on then 0.1 else 1
		label.Enabled = on
		if not on then
			for _, dot in markers do
				dot.Transparency = 1
			end
		end
	end

	local function ballWorld(l: Limits): Vector3
		return frame.groundAt(l.BallX, l.BallZ)
	end

	-- A CFrame lying on the ground at course (x, z), tilted to its slope.
	local function onGround(x: number, z: number, lift: number): CFrame
		local centre = frame.groundAt(x, z)
		local e = 0.6
		local dx = frame.groundAt(x + e, z) - frame.groundAt(x - e, z)
		local dz = frame.groundAt(x, z + e) - frame.groundAt(x, z - e)
		local up = dz:Cross(dx)
		if up.Magnitude < 1e-6 then
			up = Vector3.yAxis
		end
		up = up.Unit
		if up.Y < 0 then
			up = -up
		end
		local right = (Vector3.xAxis - up * up.X)
		right = if right.Magnitude > 1e-6 then right.Unit else Vector3.zAxis
		return CFrame.fromMatrix(centre + up * lift, right, up)
	end

	local function render()
		local l, r = limits, current
		if l == nil or r == nil or not visible then
			return
		end
		-- The reticle scales with the camera height so it reads at any zoom.
		local size = math.clamp(r.DistanceMeters * 0.06, 1.2, 9) * 3.5 * zoom
		local upright = CFrame.Angles(0, 0, math.pi / 2) -- cylinder axis (X) -> the ground normal
		ring.Size = Vector3.new(0.15, size, size)
		ring.CFrame = onGround(r.X, r.Z, 0.25) * upright
		core.Size = Vector3.new(0.2, size * 0.28, size * 0.28)
		core.CFrame = onGround(r.X, r.Z, 0.3) * upright
		ring.Color = if r.Clamped then CLAMPED_COLOR else RETICLE_COLOR
		labelText.Text = `{math.floor(r.DistanceYds + 0.5)} YDS`

		-- Max-reach arc across the allowed aim angles, on the ground.
		local dotSize = math.clamp(l.MaxMeters * 0.012, 0.6, 3) * zoom
		for i, dot in markers do
			local t = (i - 1) / (REACH_MARKERS - 1)
			local heading = l.PinHeadingRad + math.rad(-l.MaxAimDeg + 2 * l.MaxAimDeg * t)
			local x, z = l.BallX + math.cos(heading) * l.MaxMeters, l.BallZ + math.sin(heading) * l.MaxMeters
			dot.Size = Vector3.new(dotSize, dotSize, dotSize)
			dot.CFrame = CFrame.new(frame.groundAt(x, z) + Vector3.new(0, dotSize * 0.4, 0))
			dot.Transparency = 0.25
		end
	end

	-- Highest ground (world Y) along the line ball -> target and around the target.
	local function peakBetween(l: Limits, r: AimMath.Reticle): number
		local peak = -math.huge
		for i = 0, 12 do
			local t = i / 12
			local x, z = l.BallX + (r.X - l.BallX) * t, l.BallZ + (r.Z - l.BallZ) * t
			peak = math.max(peak, frame.groundAt(x, z).Y)
		end
		local spread = math.max(r.DistanceMeters * 0.25, 8)
		for k = 0, 5 do
			local a = k / 6 * 2 * math.pi
			peak = math.max(peak, frame.groundAt(r.X + math.cos(a) * spread, r.Z + math.sin(a) * spread).Y)
		end
		return peak
	end

	local function focusCamera()
		local l, r = limits, current
		if l == nil or r == nil then
			return
		end
		local ball, target = ballWorld(l), frame.groundAt(r.X, r.Z)
		if view == "Aerial" then
			CameraController.aerial(target, ball, zoom, peakBetween(l, r))
		else
			CameraController.behind(ball, target)
		end
	end

	local function setView(newView: View)
		if newView == view then
			return
		end
		view = newView
		if interactive then
			focusCamera()
		end
		if onView then
			onView(view)
		end
	end

	local function moveTo(x: number, z: number, final: boolean)
		local l = limits
		if l == nil then
			return
		end
		local r = AimMath.clamp(l.BallX, l.BallZ, x, z, l.PinHeadingRad, l.MaxMeters, l.MaxAimDeg)
		current = r
		render()
		if interactive then
			focusCamera()
		end
		onChanged(r, final)
	end

	-- Screen point -> course point under it (terrain / course parts, else the ball's height plane).
	local function pick(screen: Vector3): (number?, number?)
		local camera = workspace.CurrentCamera
		local l = limits
		if camera == nil or l == nil then
			return nil, nil
		end
		local ray = camera:ScreenPointToRay(screen.X, screen.Y)
		local hit = workspace:Raycast(ray.Origin, ray.Direction * 5000, params)
		if hit then
			return frame.toCourse(hit.Position)
		end
		local planeY = ballWorld(l).Y
		if math.abs(ray.Direction.Y) < 1e-4 then
			return nil, nil
		end
		local t = (planeY - ray.Origin.Y) / ray.Direction.Y
		if t <= 0 then
			return nil, nil
		end
		return frame.toCourse(ray.Origin + ray.Direction * t)
	end

	local function dragTo(screen: Vector3, final: boolean)
		local x, z = pick(screen)
		if x and z then
			moveTo(x, z, final)
		end
	end

	-- Fine-tune with keys: rotate (degrees) / scale the distance.
	local function nudge(deltaDeg: number, deltaFraction: number)
		local l, r = limits, current
		if l == nil or r == nil then
			return
		end
		local heading = l.PinHeadingRad + math.rad(r.AimDeg + deltaDeg)
		local distance = r.DistanceMeters * (1 + deltaFraction)
		moveTo(l.BallX + math.cos(heading) * distance, l.BallZ + math.sin(heading) * distance, true)
	end

	local connections: { RBXScriptConnection } = {}
	table.insert(connections, UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not interactive or processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragTo(input.Position, false)
		elseif input.KeyCode == Enum.KeyCode.V then
			setView(if view == "Aerial" then "Behind" else "Aerial")
		elseif input.KeyCode == Enum.KeyCode.Left then
			nudge(-NUDGE_DEG, 0)
		elseif input.KeyCode == Enum.KeyCode.Right then
			nudge(NUDGE_DEG, 0)
		elseif input.KeyCode == Enum.KeyCode.Up then
			nudge(0, NUDGE_FRACTION)
		elseif input.KeyCode == Enum.KeyCode.Down then
			nudge(0, -NUDGE_FRACTION)
		end
	end))
	table.insert(connections, UserInputService.InputChanged:Connect(function(input: InputObject, _processed: boolean)
		if not interactive then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseWheel and view == "Aerial" then
			zoom = math.clamp(zoom * (if input.Position.Z > 0 then 0.88 else 1.14), 0.4, 2.5)
			render()
			focusCamera()
		elseif dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			dragTo(input.Position, false)
		end
	end))
	table.insert(connections, UserInputService.InputEnded:Connect(function(input: InputObject, _processed: boolean)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			dragging = false
			local r = current
			if interactive and r then
				onChanged(r, true)
			end
		end
	end))

	setVisible(false)

	return {
		begin = function(newLimits: Limits, startX: number?, startZ: number?)
			limits = newLimits
			setVisible(true)
			interactive = true
			dragging = false
			if startX and startZ then
				current = AimMath.clamp(newLimits.BallX, newLimits.BallZ, startX, startZ, newLimits.PinHeadingRad, newLimits.MaxMeters, newLimits.MaxAimDeg)
			else
				local heading = newLimits.PinHeadingRad
				current = AimMath.clamp(newLimits.BallX, newLimits.BallZ, newLimits.BallX + math.cos(heading) * newLimits.MaxMeters, newLimits.BallZ + math.sin(heading) * newLimits.MaxMeters, heading, newLimits.MaxMeters, newLimits.MaxAimDeg)
			end
			render()
			focusCamera()
			local r = current
			if r then
				onChanged(r, true)
			end
		end,
		setLimits = function(newLimits: Limits)
			local r = current
			limits = newLimits
			if r then
				moveTo(r.X, r.Z, true)
			end
		end,
		reticle = function(): AimMath.Reticle?
			return current
		end,
		setInteractive = function(on: boolean)
			interactive = on
			dragging = false
			if on then
				focusCamera()
			end
		end,
		focusCamera = focusCamera,
		nudge = nudge,
		view = function(): View
			return view
		end,
		toggleView = function(): View
			setView(if view == "Aerial" then "Behind" else "Aerial")
			return view
		end,
		hide = function()
			interactive = false
			dragging = false
			limits, current = nil, nil
			setVisible(false)
		end,
		destroy = function()
			for _, connection in connections do
				connection:Disconnect()
			end
			folder:Destroy()
		end,
	}
end

return AerialAim
