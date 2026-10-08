--!strict
--[[
	LobbyAmbience.luau  (Client/Lobby)

	The lobby-only half of the visual suite (the server's LightingDirector sets the
	shared sky, sun, Atmosphere, Bloom, SunRays, ColorCorrection and soft shadows):

	  DEPTH OF FIELD  a gentle cinematic blur on the far background while in the
	                  lobby (off in matches, where you need to read the course)
	  COLOUR GRADE    a brighter, more saturated look in the lobby only
	  NEON ACCENTS    every part the server tagged "GolfRivalsNeon" (lamp caps,
	                  signs, the wheel stand trim) slowly cycles through the accent
	                  palette, each part phase-shifted so the plaza shimmers
	  AMBIENT FX      drifting pollen / firefly particles and soft light motes over
	                  the plaza, local to this client (no network cost)

	Everything pauses while a match or the driving range is on screen and comes
	back afterwards.
]]

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local Bus = require(script.Parent.Parent.Bus)

local LobbyAmbience = {}

local NEON_TAG = "GolfRivalsNeon"
local CYCLE_SECONDS = 9
local PALETTE = {
	Color3.fromRGB(64, 224, 255), -- cyan
	Color3.fromRGB(170, 90, 255), -- violet
	Color3.fromRGB(255, 80, 170), -- magenta
	Color3.fromRGB(255, 196, 60), -- gold
}

-- Palette colour at phase `t` (0..1, wraps), smoothly blended.
function LobbyAmbience.paletteAt(t: number): Color3
	local n = #PALETTE
	local x = (t % 1) * n
	local i = math.floor(x)
	local f = x - i
	f = f * f * (3 - 2 * f)
	return PALETTE[i % n + 1]:Lerp(PALETTE[(i + 1) % n + 1], f)
end

local function ambientEmitter(parent: BasePart, name: string, color: Color3, rate: number, size: number, speed: number, lifetime: number): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = name
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Color = ColorSequence.new(color)
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Rate = rate
	emitter.Lifetime = NumberRange.new(lifetime * 0.7, lifetime)
	emitter.Speed = NumberRange.new(speed * 0.5, speed)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, 0.35, 0)
	emitter.Drag = 0.6
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.2, size),
		NumberSequenceKeypoint.new(0.8, size * 0.8),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.25, 0.25),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Parent = parent
	return emitter
end

function LobbyAmbience.start()
	-- ---- depth of field ---------------------------------------------------------------------------
	local dof = Instance.new("DepthOfFieldEffect")
	dof.Name = "GR_LobbyDOF"
	dof.FarIntensity = 0.22
	dof.FocusDistance = 60
	dof.InFocusRadius = 70
	dof.NearIntensity = 0
	dof.Parent = Lighting

	-- ---- brighter, more colourful lobby grade ---------------------------------------------------------
	-- Its own ColorCorrection layered on the course look (effects stack), switched
	-- off in matches and on the range so the course keeps its natural colours.
	local grade = Instance.new("ColorCorrectionEffect")
	grade.Name = "GR_LobbyGrade"
	grade.Brightness = 0.05
	grade.Contrast = 0.06
	grade.Saturation = 0.28
	grade.TintColor = Color3.fromRGB(255, 250, 244)
	grade.Parent = Lighting

	-- ---- ambient particles (a big invisible volume over the plaza) ------------------------------------
	local volume = Instance.new("Part")
	volume.Name = "GR_AmbientVolume"
	volume.Anchored = true
	volume.CanCollide = false
	volume.CanQuery = false
	volume.CanTouch = false
	volume.Transparency = 1
	volume.Size = Vector3.new(170, 14, 170)
	volume.CFrame = CFrame.new(0, 9, 0)
	volume.Parent = workspace
	local pollen = ambientEmitter(volume, "Pollen", Color3.fromRGB(255, 236, 180), 14, 0.35, 0.8, 9)
	local fireflies = ambientEmitter(volume, "Fireflies", Color3.fromRGB(150, 255, 170), 6, 0.5, 1.4, 6)

	-- ---- neon accent tweens -----------------------------------------------------------------------------
	local neon: { [BasePart]: number } = {} -- part -> phase offset
	local function track(instance: Instance)
		if instance:IsA("BasePart") then
			neon[instance] = (instance.Position.X * 0.013 + instance.Position.Z * 0.007) % 1
		end
	end
	for _, instance in CollectionService:GetTagged(NEON_TAG) do
		track(instance)
	end
	CollectionService:GetInstanceAddedSignal(NEON_TAG):Connect(track)
	CollectionService:GetInstanceRemovedSignal(NEON_TAG):Connect(function(instance: Instance)
		if instance:IsA("BasePart") then
			neon[instance] = nil
		end
	end)

	local active = true
	local function setActive(on: boolean)
		active = on
		dof.Enabled = on
		grade.Enabled = on
		pollen.Enabled = on
		fireflies.Enabled = on
	end
	Bus.MatchEntered.connect(function()
		setActive(false)
	end)
	Bus.MatchExited.connect(function()
		setActive(true)
	end)
	Bus.RangeEntered.connect(function()
		setActive(false)
	end)
	Bus.RangeExited.connect(function()
		setActive(true)
	end)

	local accumulator = 0.0
	RunService.Heartbeat:Connect(function(dt: number)
		if not active then
			return
		end
		accumulator += dt
		if accumulator < 1 / 20 then
			return -- 20 colour updates a second is plenty for a slow cycle
		end
		accumulator = 0
		local t = os.clock() / CYCLE_SECONDS
		for part, phase in neon do
			part.Color = LobbyAmbience.paletteAt(t + phase)
		end
	end)
end

return LobbyAmbience
