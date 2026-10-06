--!strict
--[[
	WheelController.luau  (Client/Lobby)

	The physical DAILY WHEEL in the lobby (workspace.Lobby.DailyWheel, built by the
	server's LobbyBuilder):

	  * pressing its "Spin the wheel" prompt (E / tap) opens the WheelScreen
	  * when anyone spins, WheelService writes SpinFrom / SpinTo / SpinStart /
	    SpinDuration attributes on the part; every client animates the part locally
	    from those (smooth, no network jitter) with the same ease-out as the screen,
	    so the whole lobby watches the wheel spin and land on the server's result.

	Angles are clockwise degrees as seen from the front (WheelRules convention).
	The art is on the cylinder's +X face, so a clockwise turn of `a` degrees is a
	rotation of -a about the part's local X axis.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")

local Bus = require(script.Parent.Parent.Bus)

local WheelController = {}

local function easeOutQuint(t: number): number
	local u = 1 - math.clamp(t, 0, 1)
	return 1 - u * u * u * u * u
end

local function wheelPart(): BasePart?
	local lobby = workspace:FindFirstChild("Lobby")
	local part = if lobby then lobby:FindFirstChild("DailyWheel") else nil
	return if part and part:IsA("BasePart") then part else nil
end

-- Current wheel angle (clockwise degrees) from the part's spin attributes.
function WheelController.angleAt(part: BasePart, serverNow: number): number
	local from = part:GetAttribute("SpinFrom")
	local to = part:GetAttribute("SpinTo")
	local start = part:GetAttribute("SpinStart")
	local duration = part:GetAttribute("SpinDuration")
	if type(to) ~= "number" then
		return 0
	end
	if type(from) ~= "number" or type(start) ~= "number" or type(duration) ~= "number" or duration <= 0 then
		return to
	end
	return from + (to - from) * easeOutQuint((serverNow - start) / duration)
end

function WheelController.start()
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, player: Player)
		if player == Players.LocalPlayer and prompt.Name == "WheelPrompt" then
			Bus.OpenScreen.fire("Wheel")
		end
	end)

	local lastAngle: number? = nil
	RunService.RenderStepped:Connect(function()
		local part = wheelPart()
		if part == nil then
			return
		end
		local base = part:GetAttribute("BaseCFrame")
		if typeof(base) ~= "CFrame" then
			return
		end
		local angle = WheelController.angleAt(part, workspace:GetServerTimeNow())
		if angle ~= lastAngle then
			lastAngle = angle
			part.CFrame = (base :: CFrame) * CFrame.Angles(math.rad(-angle), 0, 0)
		end
	end)
end

return WheelController
