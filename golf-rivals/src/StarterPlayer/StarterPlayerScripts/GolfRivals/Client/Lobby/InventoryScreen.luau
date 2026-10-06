--!strict
--[[
	InventoryScreen.luau  (Client/Lobby)

	The cosmetics INVENTORY: everything you own, by tab, with a live 3D preview and
	EQUIP.

	  tabs     BALLS · TRAILS · HOLE FX · SWINGS · STANCES · EMOTES · CLUBS
	  grid     owned items (ItemCard; equipped one ticked, duplicates show "xN")
	  preview  a ViewportFrame with the real thing, built by the same CosmeticBuilder
	           the match uses: the ball skin (mesh / material / glow), the trail's
	           colours on a ball, the club model for the selected category (mesh,
	           template from ReplicatedStorage.GolfRivalsAssets.Clubs, or the
	           procedural head); animations show where they play and whether an
	           AnimationId is set in CosmeticsData
	  EQUIP    EquipItem(itemId) - the server checks ownership; the profile patch
	           re-renders the screen

	Equipped looks are what other players see too: the match reads everyone's
	EquippedItems and dresses their ball, trail, club and swing from CosmeticsData.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.GolfRivals.Shared
local CosmeticsData = require(Shared.CosmeticsData)
local ItemDatabase = require(Shared.ItemDatabase)
local Rarity = require(Shared.Rarity)
local Remotes = require(Shared.Remotes)

local ClientState = require(script.Parent.Parent.ClientState)
local CosmeticBuilder = require(script.Parent.Parent.Golf.CosmeticBuilder)
local ItemCard = require(script.Parent.Parent.UI.ItemCard)
local Kit = require(script.Parent.Parent.UI.Kit)
local Theme = require(script.Parent.Parent.UI.Theme)
local Toast = require(script.Parent.Parent.UI.Toast)
local ModalHost = require(script.Parent.ModalHost)
local Reasons = require(script.Parent.Reasons)

local InventoryScreen = {}

local C = Theme.Colors

type Tab = { Label: string, Slots: { string } }

local TABS: { Tab } = {
	{ Label = "BALLS", Slots = { "BallModel" } },
	{ Label = "TRAILS", Slots = { "BallTrail" } },
	{ Label = "HOLE FX", Slots = { "HoleEffect" } },
	{ Label = "SWINGS", Slots = { "Swing" } },
	{ Label = "STANCES", Slots = { "Stance" } },
	{ Label = "EMOTES", Slots = { "Emote" } },
	{ Label = "CLUBS", Slots = { "Driver", "FairwayWood", "LongIron", "ShortIron", "Wedge", "Putter" } },
}

local ANIMATION_NOTES: { [string]: string } = {
	Swing = "Plays on your golfer for every full swing (the club impact launches the ball).",
	Stance = "Your golfer's address pose while lining up a shot.",
	Emote = "Your victory celebration on the podium.",
}

local function rarityRank(id: string): number
	local info = (Rarity.Info :: any)[id]
	return if info and type(info.Tier) == "number" then info.Tier else 0
end

-- Owned items for a tab, best rarity first.
local function ownedFor(tab: Tab, owned: { [string]: number }): { ItemDatabase.Item }
	local wanted: { [string]: boolean } = {}
	for _, slot in tab.Slots do
		wanted[slot] = true
	end
	local items: { ItemDatabase.Item } = {}
	for itemId, count in owned do
		local item = ItemDatabase.get(itemId)
		if item and count > 0 and wanted[item.Slot] then
			table.insert(items, item)
		end
	end
	table.sort(items, function(a: ItemDatabase.Item, b: ItemDatabase.Item): boolean
		if a.Slot ~= b.Slot then
			return a.Slot < b.Slot
		end
		local ra, rb = rarityRank(a.Rarity), rarityRank(b.Rarity)
		if ra ~= rb then
			return ra > rb
		end
		return a.Name < b.Name
	end)
	return items
end

InventoryScreen.factory = {
	Title = "INVENTORY",
	create = function(content: Frame, _host: ModalHost.Host): ModalHost.ScreenApi
		local tabIndex = 1
		local selectedId: string? = nil
		local isOpen = false

		local tabRow = Kit.new("Frame", { Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1, Parent = content }, {
			Kit.list(Enum.FillDirection.Horizontal, 6),
		}) :: Frame
		local grid = Kit.new("ScrollingFrame", {
			Size = UDim2.new(0.62, -8, 1, -52), Position = UDim2.fromOffset(0, 52), BackgroundTransparency = 1, BorderSizePixel = 0,
			AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), ScrollBarThickness = 6, Parent = content,
		}, { Kit.grid(UDim2.fromOffset(120, 150), 10), Kit.padding(4) }) :: ScrollingFrame

		-- ---- preview panel (right) -----------------------------------------------------------------
		local panel = Kit.panel({ Size = UDim2.new(0.38, 0, 1, -52), Position = UDim2.new(0.62, 0, 0, 52), Parent = content })
		local viewport = Kit.new("ViewportFrame", {
			Size = UDim2.new(1, -20, 0.55, 0), Position = UDim2.fromOffset(10, 10), BackgroundColor3 = C.PanelDark, BorderSizePixel = 0,
			Ambient = Color3.fromRGB(150, 150, 170), LightColor = Color3.new(1, 1, 1), LightDirection = Vector3.new(-1, -1, -0.6), Parent = panel,
		}, { Kit.corner(10) }) :: ViewportFrame
		local camera = Instance.new("Camera")
		camera.FieldOfView = 40
		camera.Parent = viewport
		viewport.CurrentCamera = camera
		local nameLabel = Kit.label("", { Size = UDim2.new(1, -20, 0, 28), Position = UDim2.new(0, 10, 0.55, 18), TextSize = 22, Font = Theme.Fonts.Title, TextTruncate = Enum.TextTruncate.AtEnd, Parent = panel })
		local infoLabel = Kit.label("", {
			Size = UDim2.new(1, -20, 0.45, -120), Position = UDim2.new(0, 10, 0.55, 48), TextSize = 14, TextColor3 = C.TextDim, TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top, Parent = panel,
		})
		local equipButton = Kit.button("EQUIP", "primary", nil, { Size = UDim2.new(1, -20, 0, 46), Position = UDim2.new(0, 10, 1, -56), TextSize = 18, Parent = panel })

		local previewModel: Instance? = nil
		local spinAngle = 0.0
		local previewRadius = 3.0
		local spinConnection: RBXScriptConnection? = nil

		local function setPreview(model: Instance?, radius: number)
			if previewModel then
				previewModel:Destroy()
			end
			previewModel = model
			previewRadius = radius
			if model then
				model.Parent = viewport
			end
		end

		local function ballPart(look: CosmeticsData.BallLook): Part
			local ball = Instance.new("Part")
			ball.Shape = Enum.PartType.Ball
			ball.Size = Vector3.new(2, 2, 2)
			ball.Anchored = true
			ball.CFrame = CFrame.new()
			CosmeticBuilder.dressBall(ball, look)
			return ball
		end

		local function preview(item: ItemDatabase.Item?)
			if item == nil then
				setPreview(nil, 3)
				nameLabel.Text = "Nothing here yet"
				infoLabel.Text = "Win cosmetics from Cases, the Daily Shop, Trade-Ups and the Daily Wheel."
				equipButton.Visible = false
				return
			end
			nameLabel.Text = item.Name
			nameLabel.TextColor3 = Theme.rarity(item.Rarity)
			local lines = { `{string.upper(item.Rarity)} · {item.Slot}`, item.Description }
			if item.Slot == "BallModel" then
				setPreview(ballPart(CosmeticsData.ball(item.Id)), 2.4)
			elseif item.Slot == "BallTrail" then
				local look = CosmeticsData.trail(item.Id)
				local model = Instance.new("Model")
				local head = ballPart(CosmeticsData.ball(nil))
				head.Parent = model
				-- A comet of fading spheres in the trail's gradient (trails don't render in viewports).
				for i = 1, 7 do
					local t = i / 7
					local puff = Instance.new("Part")
					puff.Shape = Enum.PartType.Ball
					puff.Anchored = true
					puff.Material = Enum.Material.Neon
					puff.Color = Theme.rgb(look.Color):Lerp(Theme.rgb(look.Color2), t)
					puff.Transparency = 0.15 + t * 0.7
					local size = 1.8 * (1 - t * 0.75)
					puff.Size = Vector3.new(size, size, size)
					puff.CFrame = CFrame.new(-t * 6, 0, 0)
					puff.Parent = model
				end
				setPreview(model, 4.5)
				table.insert(lines, `Style: {look.Style}`)
			elseif item.Slot == "HoleEffect" then
				local look = CosmeticsData.holeEffect(item.Id)
				local model = Instance.new("Model")
				for i = 1, 12 do
					local angle = i / 12 * math.pi * 2
					local spark = Instance.new("Part")
					spark.Anchored = true
					spark.Material = Enum.Material.Neon
					spark.Color = Theme.rgb(look.Color):Lerp(Color3.new(1, 1, 1), (i % 3) * 0.25)
					spark.Size = Vector3.new(0.4, 0.4, 0.4)
					spark.CFrame = CFrame.new(math.cos(angle) * 2.2, math.sin(angle) * 2.2, 0) * CFrame.Angles(angle, angle, 0)
					spark.Parent = model
				end
				setPreview(model, 3.4)
				table.insert(lines, `Effect: {look.Style} · {look.Count} particles`)
			elseif ANIMATION_NOTES[item.Slot] then
				local look = CosmeticsData.animation(item.Id)
				setPreview(nil, 3)
				table.insert(lines, ANIMATION_NOTES[item.Slot])
				table.insert(lines, if look.AnimationId ~= "" then "Custom animation" else `Procedural "{look.Pose}" pose (no AnimationId set yet)`)
			else
				local class = item.Slot
				local model = CosmeticBuilder.club(CosmeticsData.club(item.Id, class), class == "Putter")
				local _, size = model:GetBoundingBox()
				model:PivotTo(CFrame.Angles(0, 0, math.rad(90)))
				local cf = model:GetBoundingBox()
				model:PivotTo(model:GetPivot() - cf.Position)
				setPreview(model, math.max(size.X, size.Y, size.Z) * 0.75)
			end
			infoLabel.Text = table.concat(lines, "\n")
			local profile = ClientState.get()
			local equipped = profile ~= nil and profile.EquippedItems[item.Slot] == item.Id
			equipButton.Visible = true
			equipButton.Text = if equipped then "✔ EQUIPPED" else "EQUIP"
			equipButton.AutoButtonColor = not equipped
		end

		local function render()
			local profile = ClientState.get()
			Kit.clear(tabRow)
			for index, tab in TABS do
				Kit.button(tab.Label, if index == tabIndex then "secondary" else "ghost", function()
					tabIndex = index
					selectedId = nil
					render()
				end, { Size = UDim2.fromOffset(104, 38), TextSize = 13, LayoutOrder = index, Parent = tabRow })
			end
			Kit.clear(grid)
			if profile == nil then
				preview(nil)
				return
			end
			local items = ownedFor(TABS[tabIndex], profile.OwnedItems)
			local selected: ItemDatabase.Item? = nil
			for index, item in items do
				if selectedId == nil then
					selectedId = item.Id
				end
				local isEquipped = profile.EquippedItems[item.Slot] == item.Id
				local count = profile.OwnedItems[item.Id] or 0
				if item.Id == selectedId then
					selected = item
				end
				ItemCard.new({
					Name = item.Name,
					Color = Rarity.Info[item.Rarity].Color,
					Subtitle = if #TABS[tabIndex].Slots > 1 then string.upper(item.Slot) else string.upper(item.Rarity),
					Primary = item.Visual.Primary,
					Secondary = item.Visual.Secondary,
					Glyph = ItemCard.glyphFor(item.Slot),
					Selected = item.Id == selectedId,
					Badge = if count > 1 then `x{count}` else nil,
					Footer = if isEquipped then "✔ EQUIPPED" else "OWNED",
					FooterColor = if isEquipped then C.Good else C.Text,
					LayoutOrder = index,
					OnClick = function()
						selectedId = item.Id
						render()
					end,
				}).Parent = grid
			end
			preview(selected)
		end

		equipButton.Activated:Connect(function()
			local id = selectedId
			local profile = ClientState.get()
			local item = ItemDatabase.get(id)
			if id == nil or item == nil or profile == nil or profile.EquippedItems[item.Slot] == id then
				return
			end
			local reply = Remotes.invoke("EquipItem", id)
			if type(reply) == "table" and reply.ok then
				Toast.show(`Equipped {item.Name}.`, "success")
			else
				Toast.show(Reasons.text(if type(reply) == "table" then reply.reason else nil), "error")
			end
		end)

		return {
			refresh = render,
			onOpen = function()
				isOpen = true
				if spinConnection == nil then
					spinConnection = RunService.RenderStepped:Connect(function(dt: number)
						if not isOpen then
							return
						end
						spinAngle += dt * 0.8
						local r = previewRadius * 2.6
						camera.CFrame = CFrame.lookAt(Vector3.new(math.sin(spinAngle) * r, r * 0.35, math.cos(spinAngle) * r), Vector3.zero)
					end)
				end
			end,
			onClose = function()
				isOpen = false
				local connection = spinConnection
				if connection then
					connection:Disconnect()
					spinConnection = nil
				end
			end,
		}
	end,
} :: ModalHost.Factory

return InventoryScreen
