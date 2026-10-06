--!strict
-- ROBLOX-ONLY: uses UserInputService / RunService.
--[[
	SwingController.luau  (StarterPlayerScripts.GolfRivals.Client)

	Binds player input to the shared 2-stage SwingStateMachine (power, then
	accuracy) and, when the second click completes, reports the two swing numbers:

	    onSubmit(power, accuracyOffset)        -- or, by default,
	    Remotes.fire("SubmitSwing", power, accuracyOffset)

	Clicks: left mouse, touch tap, or Space (all count as "a click"). Clicks that
	land on a GUI button are ignored, so pressing a club chip never swings.

	The controller only reports intent - the server recomputes the shot with
	SwingMath/ShotPhysics and rejects submissions faster than the timing bar allows
	(SwingMath.validateSubmission), so a hacked client gains nothing.

	USAGE (when the server says it's your turn and aiming is done):
	    local controller = SwingController.new(onGauge, onSubmit)
	    controller.enable("Full")   -- the power marker starts moving now
	    controller.enable("Putt")   -- the slower putting bar
	    controller.disable()        -- turn over / back to aiming / menu open
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("GolfRivals"):WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local SwingStateMachine = require(Shared:WaitForChild("SwingStateMachine"))

export type Controller = {
	enable: (mode: SwingStateMachine.Mode?) -> (),
	disable: () -> (),
	isEnabled: () -> boolean,
	destroy: () -> (),
}

local SwingController = {}

local function isClick(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
		or input.KeyCode == Enum.KeyCode.Space
end

function SwingController.new(onGauge: ((SwingStateMachine.Gauge) -> ())?, onSubmit: ((power: number, offset: number) -> ())?): Controller
	local machine = SwingStateMachine.new()
	local enabled = false

	-- If the machine finished (2nd click, or the accuracy deadline), send it once.
	local function submitIfDone()
		local result = machine.result()
		if result then
			enabled = false -- one shot per arm; the caller re-arms next turn
			if onSubmit then
				onSubmit(result.Power, result.AccuracyOffset)
			else
				Remotes.fire("SubmitSwing", result.Power, result.AccuracyOffset)
			end
		end
	end

	local inputConnection = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if not enabled or gameProcessed or not isClick(input) then
			return
		end
		machine.click(os.clock())
		submitIfDone()
	end)

	-- Per-frame: advance the accuracy deadline and feed the UI.
	local frameConnection = RunService.RenderStepped:Connect(function()
		if not enabled then
			return
		end
		local gauge = machine.gauge(os.clock())
		if onGauge then
			onGauge(gauge)
		end
		submitIfDone()
	end)

	return {
		enable = function(mode: SwingStateMachine.Mode?)
			machine.reset()
			machine.start(os.clock(), mode or "Full")
			enabled = true
		end,
		disable = function()
			enabled = false
			machine.reset()
		end,
		isEnabled = function(): boolean
			return enabled
		end,
		destroy = function()
			enabled = false
			inputConnection:Disconnect()
			frameConnection:Disconnect()
		end,
	}
end

return SwingController
