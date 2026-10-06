--!strict
-- ROBLOX-ONLY: creates Workspace parts and Lighting effects. The layout it builds is
-- the pure, tested LobbyLayout.
--[[
	LobbyBuilder.luau  (ServerScriptService.GolfRivals.Server)

	Builds the 3D social hub once at server start so every player shares it: ground,
	plaza and fountain, the clubhouse with its signboard, practice green, trees, lamps
	(with real lights), and the SpawnLocation named "LobbySpawn" that the client uses
	to bring players home after a match. Also sets the golden-hour lighting.

	Signs are parts with a SurfaceGui on the Front face; LobbyLayout guarantees the
	front faces the plaza.

	Driving-range mats get a ProximityPrompt ("Hit balls") carrying a BayId
	attribute; the client's RangeController turns a trigger into a RangeJoin request
	(the server re-checks the distance itself). The AFK lounge needs no prompt: the
	server's ZoneService checks positions.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Logger = require(Shared.Logger)
local LobbyLayout = require(Shared.LobbyLayout)
local PartFactory = require(Shared.PartFactory)

local LobbyBuilder = {}

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function buildSign(sign: LobbyLayout.Sign, parent: Instance)
	local board = Instance.new("Part")
	board.Name = sign.Name
	board.Anchored = true
	board.CanCollide = false
	board.Material = Enum.Material.SmoothPlastic
	board.Color = rgb(sign.Color)
	board.Size = Vector3.new(sign.SX, sign.SY, 2)
	board.CFrame = CFrame.new(sign.X, sign.Y, sign.Z) * CFrame.Angles(0, math.rad(sign.YawDeg), 0)

	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0.2
	gui.Parent = board

	local count = #sign.Lines
	for index, line in sign.Lines do
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.new(1, -40, 1 / count, -6)
		label.Position = UDim2.new(0, 20, (index - 1) / count, 3)
		label.Text = line
		label.TextColor3 = rgb(sign.TextColor)
		label.Font = Enum.Font.GothamBlack
		label.TextScaled = true
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.Parent = gui
	end
	board.Parent = parent
end

local function setupLighting()
	Lighting.ClockTime = 17.6 -- golden hour
	Lighting.Brightness = 2.4
	Lighting.GlobalShadows = true
	Lighting.Ambient = Color3.fromRGB(86, 80, 96)
	Lighting.OutdoorAmbient = Color3.fromRGB(120, 110, 124)
	Lighting.ExposureCompensation = 0.2

	local atmosphere = Instance.new("Atmosphere")
	atmosphere.Density = 0.28
	atmosphere.Offset = 0.2
	atmosphere.Color = Color3.fromRGB(255, 214, 178)
	atmosphere.Decay = Color3.fromRGB(255, 160, 120)
	atmosphere.Glare = 0.2
	atmosphere.Haze = 1.4
	atmosphere.Parent = Lighting

	local bloom = Instance.new("BloomEffect")
	bloom.Intensity = 0.35
	bloom.Size = 22
	bloom.Threshold = 0.95
	bloom.Parent = Lighting

	local rays = Instance.new("SunRaysEffect")
	rays.Intensity = 0.1
	rays.Spread = 0.8
	rays.Parent = Lighting

	local color = Instance.new("ColorCorrectionEffect")
	color.Saturation = 0.15
	color.Contrast = 0.08
	color.TintColor = Color3.fromRGB(255, 246, 236)
	color.Parent = Lighting
end

function LobbyBuilder.build()
	local layout = LobbyLayout.build()
	local folder = Instance.new("Folder")
	folder.Name = "Lobby"

	for _, spec in layout.Parts do
		local part = PartFactory.create(spec, Vector3.zero)
		local bayId = string.match(spec.Name, "^RangeMat_(%d+)$")
		if bayId then
			local prompt = Instance.new("ProximityPrompt")
			prompt.Name = "RangeBayPrompt"
			prompt.ActionText = "Hit balls"
			prompt.ObjectText = `Driving range · Bay {bayId}`
			prompt.KeyboardKeyCode = Enum.KeyCode.E
			prompt.HoldDuration = 0
			prompt.MaxActivationDistance = 12
			prompt.RequiresLineOfSight = false
			prompt:SetAttribute("BayId", tonumber(bayId))
			prompt.Parent = part
		end
		part.Parent = folder
	end
	for _, sign in layout.Signs do
		buildSign(sign, folder)
	end
	for index, light in layout.Lights do
		local anchor = Instance.new("Part")
		anchor.Name = `LampLight_{index}`
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.Transparency = 1
		anchor.Size = Vector3.new(1, 1, 1)
		anchor.Position = Vector3.new(light.X, light.Y, light.Z)
		local pointLight = Instance.new("PointLight")
		pointLight.Range = light.Range
		pointLight.Brightness = light.Brightness
		pointLight.Color = rgb(light.Color)
		pointLight.Parent = anchor
		anchor.Parent = folder
	end

	-- Everyone spawns on the plaza, facing the clubhouse.
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "LobbySpawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Transparency = 1
	spawn.CanCollide = true
	spawn.Size = Vector3.new(16, 1, 16)
	local spawnPosition = Vector3.new(layout.Spawn.X, layout.Spawn.Y, layout.Spawn.Z)
	spawn.CFrame = CFrame.lookAt(spawnPosition, spawnPosition + Vector3.new(0, 0, -1))
	spawn.Parent = workspace

	folder.Parent = workspace
	setupLighting()
	Logger.info("Lobby", `Lobby built: {#layout.Parts} parts, {#layout.Signs} signs, {#layout.Lights} lights.`)
end

return LobbyBuilder
