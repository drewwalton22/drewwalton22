--!strict
--[[
	LoadoutScreen.luau  (Client/Lobby)

	Club Loadout / Upgrade (mockup panel 2).

	  left    the 14-club bag; pick a slot
	  centre  that club: OVR, the three stats with upgrade buttons and costs, then the
	          other clubs you own for the slot (EQUIP) and ones you can buy (BUY)
	  right   skins for the club's class (owned ones equip on click, locked ones are
	          greyed out)

	Every button is a server request (UpgradeClub, BuyClub, EquipClub, EquipItem); the
	screen re-renders from the profile the server pushes back.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local ClubDatabase = require(Shared.ClubDatabase)
local Format = require(Shared.Format)
local LoadoutView = require(Shared.LoadoutView)
local Rarity = require(Shared.Rarity)
local Remotes = require(Shared.Remotes)

local ClientState = require(script.Parent.Parent.ClientState)
local ItemCard = require(script.Parent.Parent.UI.ItemCard)
local Kit = require(script.Parent.Parent.UI.Kit)
local Theme = require(script.Parent.Parent.UI.Theme)
local Toast = require(script.Parent.Parent.UI.Toast)
local ModalHost = require(script.Parent.ModalHost)
local Reasons = require(script.Parent.Reasons)

local LoadoutScreen = {}

local C = Theme.Colors

local function rarityColor(id: string): Color3
	local info = Rarity.Info[id :: any]
	return if info then Color3.fromRGB(info.Color[1], info.Color[2], info.Color[3]) else C.Stroke
end

local function request(remote: string, ...: any): boolean
	local reply = Remotes.invoke(remote, ...)
	if type(reply) == "table" and reply.ok then
		return true
	end
	Toast.show(Reasons.text(if type(reply) == "table" then reply.reason else nil), "error")
	return false
end

LoadoutScreen.factory = {
	Title = "🏌  CLUB LOADOUT",
	create = function(content: Frame, _host: ModalHost.Host): ModalHost.ScreenApi
		local selectedLabel = "D"

		local bag = Kit.new("ScrollingFrame", {
			Size = UDim2.new(0, 250, 1, 0), BackgroundTransparency = 1, BorderSizePixel = 0, CanvasSize = UDim2.new(0, 0, 0, 0),
			AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 5, Parent = content,
		}, { Kit.list(Enum.FillDirection.Vertical, 6), Kit.padding(2) }) :: ScrollingFrame
		local center = Kit.new("ScrollingFrame", {
			Size = UDim2.new(1, -600, 1, 0), Position = UDim2.fromOffset(262, 0), BackgroundTransparency = 1, BorderSizePixel = 0,
			CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 5, Parent = content,
		}, { Kit.list(Enum.FillDirection.Vertical, 10), Kit.padding(2) }) :: ScrollingFrame
		local skinPanel = Kit.panel({ Size = UDim2.new(0, 326, 1, 0), Position = UDim2.new(1, -326, 0, 0), Parent = content })
		local skinTitle = Kit.label("SKINS", { Size = UDim2.new(1, -20, 0, 28), Position = UDim2.fromOffset(12, 8), TextSize = 16, TextColor3 = C.TextDim, Font = Theme.Fonts.Bold, Parent = skinPanel })
		local skinGrid = Kit.new("ScrollingFrame", {
			Size = UDim2.new(1, -16, 1, -48), Position = UDim2.fromOffset(8, 40), BackgroundTransparency = 1, BorderSizePixel = 0,
			CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 5, Parent = skinPanel,
		}, { Kit.grid(UDim2.fromOffset(142, 150), 8), Kit.padding(2) }) :: ScrollingFrame

		local function render()
			local profile = ClientState.get()
			if profile == nil then
				return
			end

			-- Bag list ------------------------------------------------------------------------------
			Kit.clear(bag)
			local slotRows = LoadoutView.slots(profile, selectedLabel)
			for index, row in slotRows do
				local button = Kit.button("", if row.Selected then "secondary" else "ghost", function()
					selectedLabel = row.Label
					render()
				end, { Size = UDim2.new(1, -6, 0, 54), LayoutOrder = index, Parent = bag })
				Kit.label(row.Label, { Size = UDim2.fromOffset(44, 54), Position = UDim2.fromOffset(6, 0), TextSize = 16, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = rarityColor(row.Rarity), Parent = button })
				Kit.label(row.ClubName, { Size = UDim2.new(1, -112, 0, 26), Position = UDim2.fromOffset(52, 6), TextSize = 13, TextTruncate = Enum.TextTruncate.AtEnd, Parent = button })
				Kit.label(row.DisplayName, { Size = UDim2.new(1, -112, 0, 16), Position = UDim2.fromOffset(52, 32), TextSize = 11, TextColor3 = C.TextDim, Parent = button })
				Kit.label(tostring(row.Ovr), { Size = UDim2.fromOffset(46, 54), Position = UDim2.new(1, -52, 0, 0), TextSize = 22, Font = Theme.Fonts.Title, TextColor3 = C.Gold, TextXAlignment = Enum.TextXAlignment.Center, Parent = button })
			end

			-- Centre ------------------------------------------------------------------------------------
			Kit.clear(center)
			local clubId = profile.EquippedClubs[selectedLabel]
			local detail = if clubId then LoadoutView.detail(profile, clubId) else nil
			local slot = ClubDatabase.getSlot(selectedLabel)
			if detail == nil or slot == nil then
				return
			end
			local head = Kit.panel({ Size = UDim2.new(1, -8, 0, 92), LayoutOrder = 1, Parent = center })
			Kit.label(detail.Name, { Size = UDim2.new(1, -150, 0, 34), Position = UDim2.fromOffset(16, 10), TextSize = 24, Font = Theme.Fonts.Title, Parent = head })
			Kit.label(`{detail.Brand}  ·  {string.upper(detail.Rarity)}  ·  {detail.LoftDeg}° loft`, { Size = UDim2.new(1, -150, 0, 22), Position = UDim2.fromOffset(16, 46), TextSize = 14, TextColor3 = rarityColor(detail.Rarity), Font = Theme.Fonts.Bold, Parent = head })
			Kit.label(`TEAM OVR {LoadoutView.playerOvr(profile)}`, { Size = UDim2.new(1, -150, 0, 18), Position = UDim2.fromOffset(16, 68), TextSize = 12, TextColor3 = C.TextDim, Parent = head })
			Kit.label(`OVR\n{detail.Ovr}`, { Size = UDim2.fromOffset(110, 80), Position = UDim2.new(1, -124, 0, 6), TextSize = 30, Font = Theme.Fonts.Title, TextColor3 = C.Gold, TextXAlignment = Enum.TextXAlignment.Center, Parent = head })

			local stats = Kit.panel({ Size = UDim2.new(1, -8, 0, 188), LayoutOrder = 2, Parent = center })
			for index, stat in detail.Stats do
				local y = 12 + (index - 1) * 58
				Kit.label(string.upper(stat.Stat), { Size = UDim2.fromOffset(120, 22), Position = UDim2.fromOffset(16, y), TextSize = 14, Font = Theme.Fonts.Bold, Parent = stats })
				Kit.label(`Lv {stat.Level}/{stat.MaxLevel}`, { Size = UDim2.fromOffset(80, 18), Position = UDim2.fromOffset(16, y + 22), TextSize = 12, TextColor3 = C.TextDim, Parent = stats })
				local bar = Kit.new("Frame", { Size = UDim2.new(1, -330, 0, 16), Position = UDim2.fromOffset(130, y + 6), BackgroundColor3 = C.PanelDark, BorderSizePixel = 0, Parent = stats }, { Kit.corner(8) }) :: Frame
				Kit.new("Frame", { Size = UDim2.fromScale(math.clamp(stat.MaxValue / 100, 0, 1), 1), BackgroundColor3 = C.PanelLight, BorderSizePixel = 0, Parent = bar }, { Kit.corner(8) })
				Kit.new("Frame", { Size = UDim2.fromScale(math.clamp(stat.Value / 100, 0, 1), 1), BackgroundColor3 = C.Accent, BorderSizePixel = 0, ZIndex = 2, Parent = bar }, { Kit.corner(8) })
				Kit.label(tostring(stat.Value), { Size = UDim2.fromOffset(46, 28), Position = UDim2.new(1, -200, 0, y), TextSize = 22, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center, Parent = stats })
				local label = if stat.CanUpgrade then `UPGRADE  🪙 {Format.commas(stat.UpgradeCost or 0)}` else (stat.Reason or "—")
				Kit.button(label, if stat.CanUpgrade then "primary" else "ghost", function()
					if not stat.CanUpgrade then
						Toast.show(stat.Reason or "Can't upgrade that.", "error")
						return
					end
					request("UpgradeClub", detail.ClubId, stat.Stat)
				end, { Size = UDim2.fromOffset(140, 40), Position = UDim2.new(1, -148, 0, y + 2), TextSize = 12, Parent = stats })
			end

			-- Other clubs for this slot -----------------------------------------------------------------------
			local owned = LoadoutView.ownedFor(profile, selectedLabel)
			local forSale = LoadoutView.shopFor(profile, selectedLabel)
			local order = 3
			Kit.label(`{string.upper(slot.DisplayName)} OPTIONS`, { Size = UDim2.new(1, 0, 0, 24), TextSize = 14, TextColor3 = C.TextDim, Font = Theme.Fonts.Bold, LayoutOrder = order, Parent = center })
			for _, club in owned do
				order += 1
				local row = Kit.panel({ Size = UDim2.new(1, -8, 0, 48), LayoutOrder = order, Parent = center })
				Kit.label(club.Name, { Size = UDim2.new(1, -230, 1, 0), Position = UDim2.fromOffset(14, 0), TextSize = 15, TextColor3 = rarityColor(club.Rarity), Font = Theme.Fonts.Bold, TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
				Kit.label(`OVR {club.Ovr}`, { Size = UDim2.fromOffset(70, 48), Position = UDim2.new(1, -220, 0, 0), TextSize = 14, TextColor3 = C.Gold, Parent = row })
				Kit.button(if club.Equipped then "EQUIPPED" else "EQUIP", if club.Equipped then "ghost" else "secondary", function()
					if not club.Equipped then
						request("EquipClub", club.ClubId)
					end
				end, { Size = UDim2.fromOffset(110, 34), Position = UDim2.new(1, -120, 0.5, -17), TextSize = 13, Parent = row })
			end
			for _, club in forSale do
				order += 1
				local row = Kit.panel({ Size = UDim2.new(1, -8, 0, 48), LayoutOrder = order, Parent = center })
				Kit.label(club.Name, { Size = UDim2.new(1, -230, 1, 0), Position = UDim2.fromOffset(14, 0), TextSize = 15, TextColor3 = rarityColor(club.Rarity), Font = Theme.Fonts.Bold, TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
				Kit.label(`OVR {club.Ovr}`, { Size = UDim2.fromOffset(70, 48), Position = UDim2.new(1, -220, 0, 0), TextSize = 14, TextColor3 = C.Gold, Parent = row })
				Kit.button(`BUY  🪙 {Format.commas(club.Price)}`, if club.CanAfford then "primary" else "ghost", function()
					if not club.CanAfford then
						Toast.show("Not enough coins.", "error")
						return
					end
					request("BuyClub", club.ClubId)
				end, { Size = UDim2.fromOffset(110, 34), Position = UDim2.new(1, -120, 0.5, -17), TextSize = 12, Parent = row })
			end

			-- Skins ----------------------------------------------------------------------------------------------------
			skinTitle.Text = `{string.upper(slot.Class)} SKINS`
			Kit.clear(skinGrid)
			for index, skin in LoadoutView.skinsFor(profile, slot.Class) do
				ItemCard.new({
					Name = skin.Name, Color = skin.Color, Subtitle = string.upper(skin.Rarity), Primary = skin.Primary, Secondary = skin.Secondary,
					Glyph = ItemCard.glyphFor(slot.Class), Locked = not skin.Owned, Selected = skin.Equipped,
					Footer = if skin.Equipped then "✔ EQUIPPED" elseif skin.Owned then "OWNED" else "LOCKED",
					FooterColor = if skin.Equipped then C.Good elseif skin.Owned then C.Text else C.TextDim,
					Size = UDim2.fromOffset(142, 150), LayoutOrder = index,
					OnClick = function()
						if skin.Owned then
							if not skin.Equipped then
								request("EquipItem", skin.ItemId)
							end
						else
							Toast.show("Win this skin from a Case, the Daily Shop or a Trade-Up.", "info")
						end
					end,
				}).Parent = skinGrid
			end
		end

		return { refresh = render }
	end,
} :: ModalHost.Factory

return LoadoutScreen
