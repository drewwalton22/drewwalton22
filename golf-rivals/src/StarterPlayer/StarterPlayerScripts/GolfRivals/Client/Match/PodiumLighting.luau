--!strict
-- ROBLOX-ONLY: changes Lighting and lights on this client only.
--[[
	PodiumLighting.luau  (Client/Match)

	WHAT WAS LIGHTING THE PODIUM. The stage floats 900 studs above the arena in
	open sky, so it was lit by the course's outdoor setup (LightingDirector):
	a low golden-hour SUN (Brightness 2.6) raking in from one side, the
	ATMOSPHERE's haze 1.6 + glare 0.35 glowing white right behind the stage, BLOOM
	(threshold 0.92) blowing out every bright surface, SUNRAYS, +0.15 exposure and
	the sky's environment light, all stacked on the stage's own lights. Clamping
	some of those (the old fix) still left one avatar orange and the other in
	shadow with a glowing haze behind them.

	THE FIX. PodiumStage now builds a closed studio room around the stage AND the
	camera, so the sun and sky can't reach inside, and lights it with its own
	key / fill / rim lights. While the podium shows, this module sets known-good
	values (not "clamp whatever is there"):

	  Lighting   Brightness 1, ExposureCompensation 0, neutral indoor Ambient
	             (an even base light on every face), environment light down
	  Atmosphere Density / Haze / Glare 0 (no white haze inside the room)
	  Bloom      very gentle (only the neon strips glow), SunRays off
	  Colour     neutral ColorCorrection (no tint, light contrast)
	  Lights     every other bright light near the stage is switched off

	restore() puts every saved value back exactly (also called when leaving the
	match). Lighting edits made by a client don't replicate, so other players are
	unaffected.
]]

local Lighting = game:GetService("Lighting")

local PodiumLighting = {}

local PODIUM_RADIUS = 160 -- studs around the podium whose bright lights are switched off

-- Known-good values while the podium is on screen.
local SCENE: { [string]: any } = {
	Brightness = 1,
	ExposureCompensation = 0,
	Ambient = Color3.fromRGB(118, 116, 130),
	OutdoorAmbient = Color3.fromRGB(128, 128, 136),
	EnvironmentDiffuseScale = 0.25,
	EnvironmentSpecularScale = 0.35,
}
local EFFECTS: { [string]: { [string]: any } } = {
	Atmosphere = { Density = 0, Haze = 0, Glare = 0 },
	BloomEffect = { Intensity = 0.25, Threshold = 1.8, Size = 18 },
	SunRaysEffect = { Enabled = false },
	ColorCorrectionEffect = { Brightness = 0, Contrast = 0.06, Saturation = 0.12, TintColor = Color3.new(1, 1, 1) },
}

type Saved = {
	Scene: { [string]: any },
	Effects: { [Instance]: { [string]: any } },
	Lights: { [Light]: boolean },
}

local saved: Saved? = nil

local function apply(target: Instance, values: { [string]: any }, store: { [string]: any })
	for prop, value in values do
		local ok, old = pcall(function(): any
			return (target :: any)[prop]
		end)
		if ok then
			store[prop] = old
			pcall(function()
				(target :: any)[prop] = value
			end)
		end
	end
end

-- Light the podium at `origin`. `keep` lists the stage's own lights (left on).
function PodiumLighting.apply(origin: Vector3, keep: { Light }?)
	if saved then
		PodiumLighting.restore()
	end
	local state: Saved = { Scene = {}, Effects = {}, Lights = {} }
	saved = state

	apply(Lighting, SCENE, state.Scene)
	for _, effect in Lighting:GetChildren() do
		local values = EFFECTS[effect.ClassName]
		if values then
			local store: { [string]: any } = {}
			apply(effect, values, store)
			state.Effects[effect] = store
		end
	end

	local keepSet: { [Light]: boolean } = {}
	local kept: { Light } = keep or {}
	for _, light in kept do
		keepSet[light] = true
	end
	for _, instance in workspace:GetDescendants() do
		if instance:IsA("Light") and instance.Enabled and not keepSet[instance] and instance.Brightness > 1 then
			local host = instance.Parent
			if host and host:IsA("BasePart") and (host.Position - origin).Magnitude <= PODIUM_RADIUS then
				state.Lights[instance] = true
				instance.Enabled = false
			end
		end
	end
end

-- Put everything back the way it was.
function PodiumLighting.restore()
	local state = saved
	if state == nil then
		return
	end
	saved = nil
	for prop, value in state.Scene do
		pcall(function()
			(Lighting :: any)[prop] = value
		end)
	end
	for effect, values in state.Effects do
		if effect.Parent then
			for prop, value in values do
				pcall(function()
					(effect :: any)[prop] = value
				end)
			end
		end
	end
	for light in state.Lights do
		if light.Parent then
			light.Enabled = true
		end
	end
end

return PodiumLighting
