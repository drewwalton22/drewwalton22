--!strict
--[[
	Kit.luau  (Client/UI)

	Small helpers for building UI in code, so screens read as a description of what
	they contain rather than pages of Instance.new boilerplate.

	    Kit.new("Frame", { Size = UDim2.fromScale(1, 1) }, { child1, child2 })

	Property tables are applied with plain assignment (an unknown property name is a
	loud error, which is what we want), `Parent` is applied last so a screen is never
	shown half-built, and children can be passed in the third argument.

	TOPBAR SAFETY: every ScreenGui ignores the GUI inset (so dim backdrops cover the
	whole screen), and HUD content goes inside Kit.safeArea(gui): a frame padded by
	GuiService.TopbarInset (the height of Roblox's own top-bar buttons, kept live if
	it changes) plus Theme.Gutter, so nothing ever sits under the Roblox menu,
	chat or voice buttons.
]]

local GuiService = game:GetService("GuiService")
local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)
local Icons = require(script.Parent.Icons)

local Kit = {}

export type Props = { [string]: any }

function Kit.new(className: string, props: Props?, children: { any }?): Instance
	local instance = Instance.new(className)
	local parent: Instance? = nil
	if props then
		for key, value in props do
			if key == "Parent" then
				parent = value
			else
				(instance :: any)[key] = value
			end
		end
	end
	if children then
		for _, child in children do
			(child :: Instance).Parent = instance
		end
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

function Kit.corner(radius: number?): Instance
	return Kit.new("UICorner", { CornerRadius = if radius then UDim.new(0, radius) else Theme.CornerRadius })
end

function Kit.stroke(color: Color3?, thickness: number?): Instance
	return Kit.new("UIStroke", {
		Color = color or Theme.Colors.Stroke,
		Thickness = thickness or 1.5,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

function Kit.padding(all: number): Instance
	local p = UDim.new(0, all)
	return Kit.new("UIPadding", { PaddingTop = p, PaddingBottom = p, PaddingLeft = p, PaddingRight = p })
end

function Kit.list(direction: Enum.FillDirection, gap: number, props: Props?): Instance
	local merged: Props = {
		FillDirection = direction,
		Padding = UDim.new(0, gap),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}
	if props then
		for k, v in props do
			merged[k] = v
		end
	end
	return Kit.new("UIListLayout", merged)
end

function Kit.grid(cellSize: UDim2, gap: number, props: Props?): Instance
	local merged: Props = {
		CellSize = cellSize,
		CellPadding = UDim2.fromOffset(gap, gap),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}
	if props then
		for k, v in props do
			merged[k] = v
		end
	end
	return Kit.new("UIGridLayout", merged)
end

-- Vertical two-colour gradient (top -> bottom).
function Kit.gradient(top: Color3, bottom: Color3): Instance
	return Kit.new("UIGradient", { Color = ColorSequence.new(top, bottom), Rotation = 90 })
end

-- A soft outer glow: a semi-transparent stroke around the object's border.
function Kit.glow(color: Color3?, thickness: number?, transparency: number?): Instance
	return Kit.new("UIStroke", {
		Color = color or Theme.Colors.Glow,
		Thickness = thickness or 2,
		Transparency = transparency or Theme.GlowTransparency,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

-- A subtle top-lit sheen (multiplies the background: white at the top, a little
-- darker at the bottom).
function Kit.sheen(shade: number?): Instance
	local bottom = shade or 0.78
	return Kit.new("UIGradient", {
		Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.new(bottom, bottom, bottom + 0.04)),
		Rotation = 90,
	})
end

-- A rounded, semi-translucent dark glass panel: sheen gradient + soft glow border.
function Kit.panel(props: Props?, children: { any }?): Frame
	local merged: Props = { BackgroundColor3 = Theme.Colors.Panel, BackgroundTransparency = Theme.PanelTransparency, BorderSizePixel = 0 }
	if props then
		for k, v in props do
			merged[k] = v
		end
	end
	local frame = Kit.new("Frame", merged, children) :: Frame
	Kit.corner().Parent = frame
	Kit.glow().Parent = frame
	Kit.sheen().Parent = frame
	return frame
end

function Kit.label(text: string, props: Props?): TextLabel
	local merged: Props = {
		Text = text,
		BackgroundTransparency = 1,
		TextColor3 = Theme.Colors.Text,
		Font = Theme.Fonts.Bold,
		TextSize = 16,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
	}
	if props then
		for k, v in props do
			merged[k] = v
		end
	end
	return Kit.new("TextLabel", merged) :: TextLabel
end

-- A button that calls onClick when pressed. `variant` picks the colour pair from
-- Theme.Variants: "primary" (green), "secondary" (blue), "ghost" (dark), "danger"
-- (red), "gold", "purple", "teal", "orange". Buttons get a soft top-to-bottom
-- gradient (white -> shade, multiplied over the base colour) and a press scale.
function Kit.button(text: string, variant: string?, onClick: (() -> ())?, props: Props?): TextButton
	local pair = Theme.Variants[variant or "primary"] or Theme.Variants.primary
	local merged: Props = {
		Text = text,
		AutoButtonColor = true,
		BackgroundColor3 = pair[1],
		TextColor3 = Theme.Colors.Text,
		Font = Theme.Fonts.Bold,
		TextSize = 16,
		BorderSizePixel = 0,
	}
	if props then
		for k, v in props do
			merged[k] = v
		end
	end
	local button = Kit.new("TextButton", merged) :: TextButton
	Kit.corner(10).Parent = button
	-- Gradient as a tint so changing BackgroundColor3 later (enable/disable) still works.
	Kit.new("UIGradient", {
		Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.new(0.78, 0.78, 0.82)),
		Rotation = 90,
		Parent = button,
	})
	if onClick then
		button.Activated:Connect(onClick)
	end
	return button
end

-- [icon] 1,234   (currency amount that never relies on the coin emoji)
function Kit.amount(currency: string, text: string, props: Props?): Frame
	local textSize = if props and props.TextSize then props.TextSize else 16
	local color = if props and props.TextColor3 then props.TextColor3 else (if currency == "Gems" then Theme.Colors.Gem else Theme.Colors.Gold)
	local frame = Kit.new("Frame", {
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, textSize + 6),
	}, {
		Kit.list(Enum.FillDirection.Horizontal, 5, { VerticalAlignment = Enum.VerticalAlignment.Center }),
	}) :: Frame
	local icon = Icons.currency(currency, UDim2.fromOffset(textSize + 2, textSize + 2))
	icon.LayoutOrder = 1
	icon.Parent = frame
	Kit.new("TextLabel", {
		Text = text,
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, textSize + 6),
		Font = if props and props.Font then props.Font else Theme.Fonts.Title,
		TextSize = textSize,
		TextColor3 = color,
		LayoutOrder = 2,
		Parent = frame,
	})
	if props then
		for k, v in props do
			if k ~= "TextSize" and k ~= "TextColor3" and k ~= "Font" then
				(frame :: any)[k] = v
			end
		end
	end
	return frame
end

-- A button reading "PREFIX  [icon] 1,234", centred. Returns the button and a
-- setter that rewrites prefix/amount (pass amount = nil to show only the prefix).
function Kit.priceButton(prefix: string, currency: string, amountText: string?, variant: string?, onClick: (() -> ())?, props: Props?): (TextButton, (prefix: string, amountText: string?) -> ())
	local textSize = if props and props.TextSize then props.TextSize else 16
	local button = Kit.button("", variant, onClick, props)
	local row = Kit.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = button,
	}, {
		Kit.list(Enum.FillDirection.Horizontal, 8, {
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
		}),
	}) :: Frame
	local function set(newPrefix: string, newAmount: string?)
		Kit.clear(row)
		if newPrefix ~= "" then
			Kit.new("TextLabel", {
				Text = newPrefix, BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, textSize + 4),
				Font = Theme.Fonts.Bold, TextSize = textSize, TextColor3 = Theme.Colors.Text, LayoutOrder = 1, Parent = row,
			})
		end
		if newAmount then
			Kit.amount(currency, newAmount, { TextSize = textSize, TextColor3 = Theme.Colors.Text, LayoutOrder = 2, Parent = row })
		end
	end
	set(prefix, amountText)
	return button, set
end

-- The round "X" close button used by windows.
function Kit.closeButton(onClick: () -> (), props: Props?): TextButton
	local button = Kit.button("", "ghost", onClick, props)
	local icon = Icons.close(UDim2.fromScale(0.42, 0.42))
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.Parent = button
	return button
end

-- Top inset in pixels taken by Roblox's own top-bar buttons.
function Kit.topbarHeight(): number
	local inset = GuiService.TopbarInset
	return math.max(inset.Max.Y, 36)
end

-- A full-screen frame padded clear of the Roblox top bar (see header).
function Kit.safeArea(gui: ScreenGui, extraTop: number?): Frame
	local area = Kit.new("Frame", {
		Name = "SafeArea",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = gui,
	}) :: Frame
	local gutter = UDim.new(0, Theme.Gutter)
	local padding = Kit.new("UIPadding", {
		PaddingLeft = gutter,
		PaddingRight = gutter,
		PaddingBottom = gutter,
		Parent = area,
	}) :: UIPadding
	local function apply()
		padding.PaddingTop = UDim.new(0, Kit.topbarHeight() + (extraTop or 8))
	end
	apply()
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(apply)
	return area
end

function Kit.clear(parent: Instance)
	for _, child in parent:GetChildren() do
		if not child:IsA("UIListLayout") and not child:IsA("UIGridLayout") and not child:IsA("UIPadding") and not child:IsA("UICorner") and not child:IsA("UIStroke") then
			child:Destroy()
		end
	end
end

function Kit.tween(instance: Instance, seconds: number, goal: { [string]: any }, style: Enum.EasingStyle?): Tween
	local tween = TweenService:Create(instance, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal)
	tween:Play()
	return tween
end

function Kit.screenGui(name: string, displayOrder: number?): ScreenGui
	local player = game:GetService("Players").LocalPlayer
	local gui = Kit.new("ScreenGui", {
		Name = name,
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = displayOrder or 1,
		Parent = player:WaitForChild("PlayerGui"),
	}) :: ScreenGui
	return gui
end

return Kit
