--!strict
-- ROBLOX-ONLY: configures Lighting and its post effects.
--[[
	LightingDirector.luau  (ServerScriptService.GolfRivals.Server)

	The world's look, injected in code so a fresh place looks finished:

	  golden-hour sun, soft dynamic shadows (GlobalShadows + ShadowSoftness),
	  PBR-friendly environment lighting (EnvironmentDiffuse / SpecularScale),
	  Atmosphere (haze + glare), Bloom, SunRays, ColorCorrection, a Sky, and
	  realistic water colour / waves for Smooth Terrain lakes.

	Everything is replicated (server-side Lighting), so every player gets it. The
	client's LobbyAmbience adds what should only exist in the lobby (depth of
	field, neon accent colour tweens, ambient particles) and removes it in matches.

	TWO STUDIO SETTINGS SCRIPTS CAN'T TOUCH (set them by hand; see the docs):
	  Lighting > Technology = Future   (real-time shadows from every light)
	  Terrain  > Decoration = on       (animated grass blades)
]]

local Lighting = game:GetService("Lighting")

local LightingDirector = {}

local function ensure(className: string, name: string): Instance
	local existing = Lighting:FindFirstChild(name)
	if existing and existing.ClassName == className then
		return existing
	end
	local created = Instance.new(className)
	created.Name = name
	created.Parent = Lighting
	return created
end

function LightingDirector.apply()
	Lighting.ClockTime = 17.4 -- golden hour
	Lighting.GeographicLatitude = 38
	Lighting.Brightness = 2.6
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 0.35 -- soft, dynamic shadow edges
	Lighting.EnvironmentDiffuseScale = 0.6
	Lighting.EnvironmentSpecularScale = 0.8
	Lighting.Ambient = Color3.fromRGB(78, 74, 92)
	Lighting.OutdoorAmbient = Color3.fromRGB(120, 112, 126)
	Lighting.ExposureCompensation = 0.15

	local atmosphere = ensure("Atmosphere", "GR_Atmosphere") :: Atmosphere
	atmosphere.Density = 0.3
	atmosphere.Offset = 0.15
	atmosphere.Color = Color3.fromRGB(255, 214, 178)
	atmosphere.Decay = Color3.fromRGB(255, 150, 112)
	atmosphere.Glare = 0.35
	atmosphere.Haze = 1.6

	local bloom = ensure("BloomEffect", "GR_Bloom") :: BloomEffect
	bloom.Intensity = 0.45
	bloom.Size = 26
	bloom.Threshold = 0.92

	local rays = ensure("SunRaysEffect", "GR_SunRays") :: SunRaysEffect
	rays.Intensity = 0.12
	rays.Spread = 0.75

	local color = ensure("ColorCorrectionEffect", "GR_Color") :: ColorCorrectionEffect
	color.Saturation = 0.18
	color.Contrast = 0.1
	color.Brightness = 0.02
	color.TintColor = Color3.fromRGB(255, 246, 236)

	local sky = ensure("Sky", "GR_Sky") :: Sky
	sky.SunAngularSize = 14
	sky.MoonAngularSize = 9
	sky.StarCount = 1500

	local terrain = workspace.Terrain
	terrain.WaterColor = Color3.fromRGB(38, 112, 150)
	terrain.WaterReflectance = 0.6
	terrain.WaterTransparency = 0.55
	terrain.WaterWaveSize = 0.12
	terrain.WaterWaveSpeed = 8
end

return LightingDirector
