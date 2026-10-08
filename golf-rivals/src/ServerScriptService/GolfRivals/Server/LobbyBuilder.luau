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

	The DAILY WHEEL is a cylinder (DailyWheel) whose face is a SurfaceGui drawn by
	WheelArt, with a pointer and a "Spin the wheel" prompt; clients animate it
	from the attributes WheelService sets after each spin. Neon parts are tagged
	"GolfRivalsNeon" for the client's colour tweens (LobbyAmbience).

	Driving-range mats get a ProximityPrompt ("Hit balls") carrying a BayId
	attribute; the client's RangeController turns a trigger into a RangeJoin request
	(the server re-checks the distance itself). The AFK lounge needs no prompt: the
	server's ZoneService checks positions.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Logger = require(Shared.Logger)
local LobbyLayout = require(Shared.LobbyLayout)
local PartFactory = require(Shared.PartFactory)
local WheelArt = require(Shared.WheelArt)
local LightingDirector = require(script.Parent.LightingDirector)

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


-- The daily wheel: a thin cylinder facing the plaza, its face drawn by WheelArt.
local function buildWheel(parent: Instance)
	local w = LobbyLayout.WHEEL
	local yaw = math.rad(LobbyLayout.wheelYawDeg())
	local facing = Vector3.new(-math.sin(yaw), 0, -math.cos(yaw)) -- toward the plaza
	local hub = Vector3.new(w.X, w.HubY, w.Z)

	local wheel = Instance.new("Part")
	wheel.Name = "DailyWheel"
	wheel.Shape = Enum.PartType.Cylinder -- axis = local X
	wheel.Size = Vector3.new(1, w.Radius * 2, w.Radius * 2)
	wheel.Anchored = true
	wheel.CanCollide = false
	wheel.Color = Color3.fromRGB(30, 34, 52)
	wheel.Material = Enum.Material.SmoothPlastic
	-- Local X faces the plaza, local Y is up: the Right face shows the art upright.
	wheel.CFrame = CFrame.fromMatrix(hub, facing, Vector3.yAxis)
	wheel:SetAttribute("BaseCFrame", wheel.CFrame)
	wheel:SetAttribute("SpinTo", 0)

	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Right
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0.15
	local canvas = Instance.new("Frame")
	canvas.Size = UDim2.fromScale(1, 1)
	canvas.BackgroundTransparency = 1
	canvas.Parent = gui
	WheelArt.draw(canvas)
	gui.Parent = wheel

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "WheelPrompt"
	prompt.ActionText = "Spin the wheel"
	prompt.ObjectText = "Daily Spin"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 16
	prompt.RequiresLineOfSight = false
	prompt.Parent = wheel
	wheel.Parent = parent

	-- Pointer above the wheel, pointing down at the winning segment.
	local pointer = Instance.new("WedgePart")
	pointer.Name = "WheelPointer"
	pointer.Size = Vector3.new(0.6, 2.4, 2.2)
	pointer.Anchored = true
	pointer.CanCollide = false
	pointer.Color = Color3.fromRGB(255, 70, 90)
	pointer.Material = Enum.Material.Neon
	pointer.CFrame = CFrame.lookAt(hub + Vector3.new(0, w.Radius + 0.9, 0) + facing * 0.8, hub + Vector3.new(0, w.Radius + 0.9, 0) + facing * 0.8 + facing)
		* CFrame.Angles(math.rad(180), 0, 0)
	pointer.Parent = parent
end

function LobbyBuilder.build()
	local layout = LobbyLayout.build()
	local folder = Instance.new("Folder")
	folder.Name = "Lobby"

	for _, spec in layout.Parts do
		local part = PartFactory.create(spec, Vector3.zero)
		if spec.Material == "Neon" then
			CollectionService:AddTag(part, "GolfRivalsNeon")
		end
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

	buildWheel(folder)
	folder.Parent = workspace
	LightingDirector.apply()
	Logger.info("Lobby", `Lobby built: {#layout.Parts} parts, {#layout.Signs} signs, {#layout.Lights} lights.`)
end

return LobbyBuilder
