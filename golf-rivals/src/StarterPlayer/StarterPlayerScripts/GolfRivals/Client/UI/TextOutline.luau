--!strict
--[[
	TextOutline.luau  (Client/UI)

	Gives EVERY piece of on-screen text the cartoon look: a thick dark outline.
	Instead of touching hundreds of labels, it watches PlayerGui and, a frame
	after any TextLabel / TextButton appears (so its final size and colours are
	set), adds a Contextual UIStroke sized to the text:

	    TextSize <= 12 -> 1.25 px,  <= 18 -> 1.75 px,  <= 26 -> 2.25 px,  bigger -> 3 px
	    (TextScaled text gets 2 px)

	Skipped: TextBoxes (typing fields), dark text (it sits on bright pills and
	reads better without), objects with the attribute NoOutline = true, and text
	that already has a Contextual UIStroke. An object that already has a BORDER
	UIStroke (a badge outline) gets Roblox's built-in text stroke instead, since
	one GuiObject shows only one UIStroke.
]]

local Players = game:GetService("Players")

local Theme = require(script.Parent.Theme)

local TextOutline = {}

local function thicknessFor(text: TextLabel | TextButton): number
	if text.TextScaled then
		return 2
	end
	local size = text.TextSize
	if size <= 12 then
		return 1.25
	elseif size <= 18 then
		return 1.75
	elseif size <= 26 then
		return 2.25
	end
	return 3
end

local function isDark(color: Color3): boolean
	return 0.299 * color.R + 0.587 * color.G + 0.114 * color.B < 0.32
end

function TextOutline.apply(object: Instance)
	if not (object:IsA("TextLabel") or object:IsA("TextButton")) then
		return
	end
	local text = object :: TextLabel
	if text:GetAttribute("NoOutline") == true or isDark(text.TextColor3) or text.TextTransparency >= 1 then
		return
	end
	for _, child in text:GetChildren() do
		if child:IsA("UIStroke") then
			if child.ApplyStrokeMode == Enum.ApplyStrokeMode.Border and text.TextStrokeTransparency >= 1 then
				text.TextStrokeColor3 = Theme.Colors.Stroke
				text.TextStrokeTransparency = 0
			end
			return
		end
	end
	local stroke = Instance.new("UIStroke")
	stroke.Name = "TextOutline"
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.Color = Theme.Colors.Stroke
	stroke.Thickness = thicknessFor(text)
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = text
	text.TextStrokeTransparency = 1 -- the UIStroke replaces the thin legacy stroke
end

function TextOutline.start()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	for _, descendant in playerGui:GetDescendants() do
		TextOutline.apply(descendant)
	end
	playerGui.DescendantAdded:Connect(function(descendant: Instance)
		if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
			task.defer(function()
				if descendant.Parent then
					TextOutline.apply(descendant)
				end
			end)
		end
	end)
end

return TextOutline
