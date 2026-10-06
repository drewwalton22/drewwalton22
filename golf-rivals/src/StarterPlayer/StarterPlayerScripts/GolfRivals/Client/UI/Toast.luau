--!strict
--[[
	Toast.luau  (Client/UI)

	Short messages that slide in at the top of the screen ("Match found!", "You won
	200 coins!"). Driven by the server's `Notify` remote and by local UI feedback.
]]

local Theme = require(script.Parent.Theme)
local Kit = require(script.Parent.Kit)

local Toast = {}

local gui: ScreenGui? = nil
local holder: Frame? = nil

local KIND_COLORS: { [string]: Color3 } = {
	info = Theme.Colors.Blue,
	success = Theme.Colors.Good,
	error = Theme.Colors.Danger,
}

local function ensureGui(): Frame
	if holder and holder.Parent then
		return holder
	end
	local screen = Kit.screenGui("GolfRivalsToasts", 100)
	gui = screen
	-- Below the top-centre banners and clear of Roblox's top bar.
	local created = Kit.new("Frame", {
		Name = "Holder",
		BackgroundTransparency = 1,
		Size = UDim2.new(0, 420, 0, 300),
		Position = UDim2.new(0.5, -210, 0, 132),
		Parent = Kit.safeArea(screen),
	}, { Kit.list(Enum.FillDirection.Vertical, 8, { HorizontalAlignment = Enum.HorizontalAlignment.Center }) }) :: Frame
	holder = created
	return created
end

function Toast.show(message: string, kind: string?, seconds: number?)
	local parent = ensureGui()
	local accent = KIND_COLORS[kind or "info"] or Theme.Colors.Blue
	local toast = Kit.panel({
		Size = UDim2.new(0, 400, 0, 44),
		BackgroundColor3 = Theme.Colors.PanelDark,
		BackgroundTransparency = 1,
		Parent = parent,
	}, {
		Kit.label(message, {
			Size = UDim2.new(1, -20, 1, 0),
			Position = UDim2.fromOffset(14, 0),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTransparency = 1,
		}),
	})
	local stroke = toast:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = accent
	end
	local text = toast:FindFirstChildOfClass("TextLabel")
	Kit.tween(toast, 0.2, { BackgroundTransparency = 0.05 })
	if text then
		Kit.tween(text, 0.2, { TextTransparency = 0 })
	end
	task.delay(seconds or 3.5, function()
		if toast.Parent then
			Kit.tween(toast, 0.3, { BackgroundTransparency = 1 })
			if text then
				Kit.tween(text, 0.3, { TextTransparency = 1 })
			end
			task.wait(0.35)
			toast:Destroy()
		end
	end)
end

return Toast
