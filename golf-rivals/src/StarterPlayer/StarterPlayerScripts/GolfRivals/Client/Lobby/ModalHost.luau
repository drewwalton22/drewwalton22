--!strict
--[[
	ModalHost.luau  (Client/Lobby)

	The window that lobby screens open inside: a dimmed backdrop, a titled panel with
	a close button, and one content frame. Screens register a factory once and are
	built lazily the first time they open:

	    host.register("Shop", { Title = "SKIN SHOP", create = function(content, host) ... return api end })
	    host.open("Shop")     -- builds if needed, shows, calls api.onOpen then api.refresh
	    host.close()

	`api.refresh()` is also called by the lobby whenever the profile changes while the
	screen is open. Escape closes the window.
]]

local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent.Parent.UI.Theme)
local Kit = require(script.Parent.Parent.UI.Kit)

export type ScreenApi = {
	refresh: () -> (),
	onOpen: (() -> ())?,
	onClose: (() -> ())?,
}

export type Host = {
	Gui: ScreenGui,
	register: (name: string, factory: Factory) -> (),
	open: (name: string) -> (),
	close: () -> (),
	current: () -> string?,
	refreshCurrent: () -> (),
	setVisible: (visible: boolean) -> (),
}

export type Factory = {
	Title: string,
	create: (content: Frame, host: Host) -> ScreenApi,
}

local ModalHost = {}

function ModalHost.new(): Host
	local gui = Kit.screenGui("GolfRivalsLobbyScreens", 10)
	gui.Enabled = true

	local backdrop = Kit.new("TextButton", {
		Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45, Text = "", AutoButtonColor = false,
		Visible = false, Parent = gui,
	}) :: TextButton

	local window = Kit.panel({
		Size = UDim2.new(0.88, 0, 0.84, 0), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), Parent = backdrop,
	}, { Kit.new("UISizeConstraint", { MaxSize = Vector2.new(1180, 700), MinSize = Vector2.new(760, 460) }) })

	local titleLabel = Kit.label("", { Size = UDim2.new(1, -80, 0, 48), Position = UDim2.fromOffset(20, 0), TextSize = 22, Font = Theme.Fonts.Title, Parent = window })
	local content = Kit.new("Frame", { Size = UDim2.new(1, -24, 1, -64), Position = UDim2.fromOffset(12, 52), BackgroundTransparency = 1, Parent = window }) :: Frame

	local factories: { [string]: Factory } = {}
	local apis: { [string]: ScreenApi? } = {}
	local frames: { [string]: Frame? } = {}
	local currentName: string? = nil

	local function close()
		local name = currentName
		if name == nil then
			return
		end
		currentName = nil
		backdrop.Visible = false
		local api = apis[name]
		if api and api.onClose then
			api.onClose()
		end
	end

	local host: Host
	local function open(name: string)
		local factory = factories[name]
		if factory == nil then
			return
		end
		if currentName and currentName ~= name then
			close()
		end
		if frames[name] == nil then
			local frame = Kit.new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, Parent = content }) :: Frame
			frames[name] = frame
			apis[name] = factory.create(frame, host)
		end
		for otherName, frame in frames do
			if frame then
				frame.Visible = otherName == name
			end
		end
		titleLabel.Text = factory.Title
		currentName = name
		backdrop.Visible = true
		local api = apis[name]
		if api then
			if api.onOpen then
				api.onOpen()
			end
			api.refresh()
		end
	end

	Kit.button("✕", "ghost", close, { Size = UDim2.fromOffset(40, 36), Position = UDim2.new(1, -52, 0, 6), TextSize = 18, Parent = window })
	-- Clicking the dim area outside the window closes it (clicks inside don't reach it).
	backdrop.Activated:Connect(function()
		close()
	end)
	local clickShield = Kit.new("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", ZIndex = 0, Parent = window }) :: TextButton
	clickShield.AutoButtonColor = false

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not processed and input.KeyCode == Enum.KeyCode.Escape and currentName ~= nil then
			close()
		end
	end)

	host = {
		Gui = gui,
		register = function(name: string, factory: Factory)
			factories[name] = factory
		end,
		open = open,
		close = close,
		current = function(): string?
			return currentName
		end,
		refreshCurrent = function()
			local name = currentName
			local api = if name then apis[name] else nil
			if api then
				api.refresh()
			end
		end,
		setVisible = function(visible: boolean)
			gui.Enabled = visible
			if not visible then
				close()
			end
		end,
	}
	return host
end

return ModalHost
