--!strict
--[[
	AssetLoader.luau  (Client/UI)

	Shows an uploaded image when there is one, and a drawn fallback when there
	isn't - so a missing, placeholder or moderated asset id can never leave a blank
	square or a broken screen.

	    AssetLoader.image("CoinIcon", UDim2.fromOffset(24, 24), function(size)
	        return Icons.coin(size)          -- drawn with frames / a Color3
	    end)

	  1. Assets.image(name) == nil (placeholder)  -> the fallback, immediately.
	  2. A real id                                -> an ImageLabel, plus a background
	     ContentProvider:PreloadAsync check; if the asset fails to load, the
	     ImageLabel is swapped for the fallback in place (same size/position/parent).
]]

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Assets = require(ReplicatedStorage.GolfRivals.Shared.Assets)

local AssetLoader = {}

-- Ids already known to fail this session (don't retry them on every screen build).
local failed: { [string]: boolean } = {}

function AssetLoader.image(name: string, size: UDim2, fallback: (size: UDim2) -> GuiObject): GuiObject
	local id = Assets.image(name)
	if id == nil or failed[id] then
		return fallback(size)
	end
	local assetId = id :: string
	local label = Instance.new("ImageLabel")
	label.Name = name
	label.Size = size
	label.BackgroundTransparency = 1
	label.ScaleType = Enum.ScaleType.Fit
	label.Image = assetId

	task.spawn(function()
		local ok = true
		local success = pcall(function()
			ContentProvider:PreloadAsync({ label }, function(_contentId: string, status: Enum.AssetFetchStatus)
				if status ~= Enum.AssetFetchStatus.Success then
					ok = false
				end
			end)
			return true
		end)
		if success and ok then
			return
		end
		failed[assetId] = true
		-- Swap in the fallback where the image was.
		local replacement = fallback(label.Size)
		replacement.Position = label.Position
		replacement.AnchorPoint = label.AnchorPoint
		replacement.LayoutOrder = label.LayoutOrder
		replacement.ZIndex = label.ZIndex
		replacement.Parent = label.Parent
		label:Destroy()
	end)
	return label
end

return AssetLoader
