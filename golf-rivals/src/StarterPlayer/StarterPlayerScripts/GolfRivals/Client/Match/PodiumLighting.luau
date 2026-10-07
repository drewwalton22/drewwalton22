--!strict
-- ROBLOX-ONLY: changes Lighting and lights on this client only.
--[[
	PodiumLighting.luau  (Client/Match)

	POST-GAME LIGHTING FIX. The end-of-match podium floats high above the arena in
	open sky, where the golden-hour sun, Bloom, SunRays, positive exposure and the
	stage lights (Future lighting) stacked up into a blinding white screen. While
	the podium is showing, this module:

	  * lowers Lighting.Brightness and ExposureCompensation
	  * tames the post effects: Bloom intensity way down (higher threshold),
	    SunRays off, ColorCorrection slightly darker with a touch more contrast
	  * disables every bright local light (Brightness > 1) within PODIUM_RADIUS of
	    the stage that isn't the stage's own soft key light

	restore() puts every saved value back exactly (also called when leaving the
	match). Changes are client-side only: Lighting edits on a client don't
	replicate, so other players are unaffected.
]]

local Lighting = game:GetService("Lighting")

local PodiumLighting = {}

local PODIUM_RADIUS = 160 -- studs around the podium whose bright lights are switched off

type Saved = {
	Brightness: number,
	Exposure: number,
	Effects: { [Instance]: { [string]: any } },
	Lights: { [Light]: boolean },
}

local saved: Saved? = nil

local function remember(store: { [Instance]: { [string]: any } }, instance: Instance, props: { string })
	local values: { [string]: any } = {}
	for _, prop in props do
		values[prop] = (instance :: any)[prop]
	end
	store[instance] = values
end

-- Dim the scene for the podium at `origin`. `keep` lists lights that stay on.
function PodiumLighting.apply(origin: Vector3, keep: { Light }?)
	if saved then
		PodiumLighting.restore()
	end
	local state: Saved = { Brightness = Lighting.Brightness, Exposure = Lighting.ExposureCompensation, Effects = {}, Lights = {} }
	saved = state

	Lighting.Brightness = math.min(Lighting.Brightness, 1.3)
	Lighting.ExposureCompensation = math.min(Lighting.ExposureCompensation, -0.4)

	for _, effect in Lighting:GetChildren() do
		if effect:IsA("BloomEffect") then
			remember(state.Effects, effect, { "Intensity", "Threshold", "Size" })
			effect.Intensity = math.min(effect.Intensity, 0.12)
			effect.Threshold = math.max(effect.Threshold, 1.6)
		elseif effect:IsA("SunRaysEffect") then
			remember(state.Effects, effect, { "Enabled" })
			effect.Enabled = false
		elseif effect:IsA("ColorCorrectionEffect") then
			remember(state.Effects, effect, { "Brightness", "Contrast" })
			effect.Brightness = math.min(effect.Brightness, -0.06)
			effect.Contrast = math.max(effect.Contrast, 0.14)
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
	Lighting.Brightness = state.Brightness
	Lighting.ExposureCompensation = state.Exposure
	for effect, values in state.Effects do
		if effect.Parent then
			for prop, value in values do
				(effect :: any)[prop] = value
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
