--!strict
--[[
	Kit.luau  (Client/UI)

	Small helpers for building UI in code, so screens read as a description of what
	they contain rather than pages of Instance.new boilerplate.

	    Kit.new("Frame", { Size = UDim2.fromScale(1, 1) }, { child1, child2 })

	Property tables are applied with plain assignment (an unknown property name is a
	loud error, which is what we want), `Parent` is applied last so a screen is never
	shown half-built, and children can be passed in the third argument.
]]

local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)

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

-- A rounded panel with the standard border.
function Kit.panel(props: Props?, children: { any }?): Frame
	local merged: Props = { BackgroundColor3 = Theme.Colors.Panel, BorderSizePixel = 0 }
	if props then
		for k, v in props do
			merged[k] = v
		end
	end
	local frame = Kit.new("Frame", merged, children) :: Frame
	Kit.corner().Parent = frame
	Kit.stroke().Parent = frame
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

-- A button that calls onClick when pressed. `variant` picks the colour:
-- "primary" (green), "secondary" (blue), "ghost" (dark), "danger" (red).
function Kit.button(text: string, variant: string?, onClick: (() -> ())?, props: Props?): TextButton
	local colors = {
		primary = Theme.Colors.Accent,
		secondary = Theme.Colors.Blue,
		ghost = Theme.Colors.PanelLight,
		danger = Theme.Colors.Danger,
	}
	local base = colors[variant or "primary"] or Theme.Colors.Accent
	local merged: Props = {
		Text = text,
		AutoButtonColor = true,
		BackgroundColor3 = base,
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
	Kit.corner(8).Parent = button
	if onClick then
		button.Activated:Connect(onClick)
	end
	return button
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
