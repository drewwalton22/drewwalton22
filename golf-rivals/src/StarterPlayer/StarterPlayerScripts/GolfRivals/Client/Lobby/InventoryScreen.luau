--!strict
--[[
	InventoryScreen.luau  (Client/Lobby)

	The cosmetics INVENTORY: everything you own, by tab, with a live 3D preview and
	EQUIP.

	  tabs     BALLS · TRAILS · HOLE FX · SWINGS · STANCES · EMOTES · CLUBS
	  grid     owned items (ItemCard; equipped one ticked, duplicates show "xN")
	  preview  a ViewportFrame with the real thing, built by ItemPreview with the same CosmeticBuilder
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

local Shared = ReplicatedStorage.GolfRivals.Shared
local CosmeticsData = require(Shared.CosmeticsData)
local ItemDatabase = require(Shared.ItemDatabase)
local Rarity = require(Shared.Rarity)
local Remotes = require(Shared.Remotes)

local ClientState = require(script.Parent.Parent.ClientState)
local ItemCard = require(script.Parent.Parent.UI.ItemCard)
local ItemPreview = require(script.Parent.Parent.UI.ItemPreview)
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

		local tabRow = Kit.new("Frame", { Size = UDim2.new(1, 0, 0, 40), BackgroundTransparency = 1, Parent = content }, {
			Kit.list(Enum.FillDirection.Horizontal, 6),
		}) :: Frame
		local grid = Kit.new("ScrollingFrame", {
			Size = UDim2.new(0.62, -8, 1, -52), Position = UDim2.fromOffset(0, 52), BackgroundTransparency = 1, BorderSizePixel = 0,
			AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), ScrollBarThickness = 6, Parent = content,
		}, { Kit.grid(UDim2.fromOffset(120, 150), 10), Kit.padding(4) }) :: ScrollingFrame

		-- ---- preview panel (right) -----------------------------------------------------------------
		local panel = Kit.panel({ Size = UDim2.new(0.38, 0, 1, -52), Position = UDim2.new(0.62, 0, 0, 52), Parent = content })
		-- The 3D preview (ItemPreview: the same code-built model the game uses).
		local viewport = Kit.new("Frame", {
			Size = UDim2.new(1, -20, 0.55, 0), Position = UDim2.fromOffset(10, 10), BackgroundColor3 = C.PanelDark, BorderSizePixel = 0, ClipsDescendants = true, Parent = panel,
		}, { Kit.corner(10) }) :: Frame
		local glyph = Kit.label("", { Size = UDim2.fromScale(1, 1), TextSize = 64, TextXAlignment = Enum.TextXAlignment.Center, Parent = viewport })
		local nameLabel = Kit.label("", { Size = UDim2.new(1, -20, 0, 28), Position = UDim2.new(0, 10, 0.55, 18), TextSize = 22, Font = Theme.Fonts.Title, TextTruncate = Enum.TextTruncate.AtEnd, Parent = panel })
		local infoLabel = Kit.label("", {
			Size = UDim2.new(1, -20, 0.45, -120), Position = UDim2.new(0, 10, 0.55, 48), TextSize = 14, TextColor3 = C.TextDim, TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top, Parent = panel,
		})
		local equipButton = Kit.button("EQUIP", "primary", nil, { Size = UDim2.new(1, -20, 0, 46), Position = UDim2.new(0, 10, 1, -56), TextSize = 18, Parent = panel })

		local function setPreview(item: ItemDatabase.Item?)
			for _, child in viewport:GetChildren() do
				if child:IsA("ViewportFrame") then
					child:Destroy()
				end
			end
			glyph.Text = ""
			if item then
				if ItemPreview.attach(viewport, item.Id, { Speed = 0.7 }) == nil then
					glyph.Text = ItemCard.glyphFor(item.Slot) -- animations: no model
				end
			end
		end

		local function preview(item: ItemDatabase.Item?)
			if item == nil then
				setPreview(nil)
				nameLabel.Text = "Nothing here yet"
				infoLabel.Text = "Win cosmetics from Cases, the Daily Shop, Trade-Ups and the Daily Wheel."
				equipButton.Visible = false
				return
			end
			nameLabel.Text = item.Name
			nameLabel.TextColor3 = Theme.rarity(item.Rarity)
			local lines = { `{string.upper(item.Rarity)} · {item.Slot}`, item.Description }
			setPreview(item)
			if item.Slot == "BallTrail" then
				table.insert(lines, `Style: {CosmeticsData.trail(item.Id).Style}`)
			elseif item.Slot == "HoleEffect" then
				local look = CosmeticsData.holeEffect(item.Id)
				table.insert(lines, `Effect: {look.Style} · {look.Count} particles`)
			elseif ANIMATION_NOTES[item.Slot] then
				table.insert(lines, ANIMATION_NOTES[item.Slot])
				table.insert(lines, CosmeticsData.animation(item.Id).Source)
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
					ItemId = item.Id,
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
		}
	end,
} :: ModalHost.Factory

return InventoryScreen
