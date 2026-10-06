--!strict
-- ROBLOX-ONLY: uses UserInputService / RunService.
--[[
	SwingController.luau  (StarterPlayerScripts.GolfRivals.Client)

	Binds player input to the shared 3-click SwingStateMachine and, when the
	third click completes, sends the two swing numbers to the server:

	    Remotes.fire("SubmitSwing", power, accuracyOffset)

	Clicks: left mouse, touch tap, or Space (all count as "a click").
	The controller only reports intent - the server recomputes the shot with
	SwingMath/ShotPhysics and also rejects submissions faster than a human could
	produce (SwingMath.validateSubmission), so a hacked client gains nothing by
	sending perfect numbers instantly.

	UI hookup: pass `onGauge`; it is called every frame while enabled with the
	current gauge (phase + marker 0..1, negative after the centre) so the power
	bar UI (built in the lobby/HUD step) can draw it. This controller has no
	visuals of its own.

	USAGE (from the match HUD, when the server says it's your turn):
	    local controller = SwingController.new(function(gauge) ... end)
	    controller.enable()   -- arms the gauge; the next click is "click 1"
	    controller.disable()  -- turn over / menu open
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("GolfRivals"):WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local SwingStateMachine = require(Shared:WaitForChild("SwingStateMachine"))

export type Controller = {
	enable: () -> (),
	disable: () -> (),
	destroy: () -> (),
}

local SwingController = {}

local function isClick(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
		or input.KeyCode == Enum.KeyCode.Space
end

function SwingController.new(onGauge: ((SwingStateMachine.Gauge) -> ())?): Controller
	local machine = SwingStateMachine.new()
	local enabled = false

	-- If the machine finished (3rd click, or an auto-lock deadline), send it once.
	local function submitIfDone()
		local result = machine.result()
		if result then
			enabled = false -- one shot per arm; the server re-arms us next turn
			Remotes.fire("SubmitSwing", result.Power, result.AccuracyOffset)
		end
	end

	local inputConnection = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		-- gameProcessed = the click landed on a GUI button; don't swing for that.
		if not enabled or gameProcessed or not isClick(input) then
			return
		end
		machine.click(os.clock())
		submitIfDone()
	end)

	-- Per-frame: advance auto-lock deadlines and feed the UI.
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
		enable = function()
			machine.reset()
			enabled = true
		end,
		disable = function()
			enabled = false
			machine.reset()
		end,
		destroy = function()
			enabled = false
			inputConnection:Disconnect()
			frameConnection:Disconnect()
		end,
	}
end

return SwingController
