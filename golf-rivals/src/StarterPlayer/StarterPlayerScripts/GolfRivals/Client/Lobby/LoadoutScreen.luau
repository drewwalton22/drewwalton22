--!strict
--[[
	LoadoutScreen.luau  (Client/Lobby)

	Club Loadout / Upgrade for the six-club bag.

	  top     six category tabs (Driver, Fairway Wood, Long Iron, Short Iron, Wedge,
	          Putter), each with the equipped club's OVR
	  left    the selected club: name, rarity, OVR, what the category is for, and the
	          three stats (POWER / ACCURACY / SPIN) with bars, levels and an UPGRADE
	          button showing the coin cost; below it the other clubs you own for the
	          category (EQUIP) and the ones you can buy (BUY)
	  right   skins for the category (owned ones equip on click, locked ones are
	          greyed out with a padlock)

	All widths are proportional, so nothing clips on small windows. Every button is a
	server request (UpgradeClub, BuyClub, EquipClub, EquipItem); the screen re-renders
	from the profile the server pushes back.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local ClubStats = require(Shared.ClubStats)
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

local STAT_BLURBS: { [string]: string } = {}
for _, info in ClubStats.StatInfo do
	STAT_BLURBS[info.Id] = info.Blurb
end

LoadoutScreen.factory = {
	Title = "CLUB LOADOUT",
	create = function(content: Frame, _host: ModalHost.Host): ModalHost.ScreenApi
		local selectedLabel = ClubStats.DRIVER

		-- ---- frame -------------------------------------------------------------------------------
		local tabs = Kit.new("Frame", { Size = UDim2.new(1, 0, 0, 62), BackgroundTransparency = 1, Parent = content }, {
			Kit.list(Enum.FillDirection.Horizontal, 8),
		}) :: Frame
		local left = Kit.new("ScrollingFrame", {
			Size = UDim2.new(0.58, -8, 1, -74), Position = UDim2.fromOffset(0, 74), BackgroundTransparency = 1, BorderSizePixel = 0,
			CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 5, Parent = content,
		}, { Kit.list(Enum.FillDirection.Vertical, 10), Kit.padding(2) }) :: ScrollingFrame
		local skinPanel = Kit.panel({ Size = UDim2.new(0.42, -8, 1, -74), Position = UDim2.new(0.58, 8, 0, 74), Parent = content })
		local skinTitle = Kit.label("SKINS", { Size = UDim2.new(1, -24, 0, 28), Position = UDim2.fromOffset(14, 8), TextSize = 16, TextColor3 = C.TextDim, Font = Theme.Fonts.Bold, Parent = skinPanel })
		local skinGrid = Kit.new("ScrollingFrame", {
			Size = UDim2.new(1, -16, 1, -48), Position = UDim2.fromOffset(8, 40), BackgroundTransparency = 1, BorderSizePixel = 0,
			CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 5, Parent = skinPanel,
		}, { Kit.grid(UDim2.new(0.5, -6, 0, 150), 8), Kit.padding(2) }) :: ScrollingFrame

		local function render()
			local profile = ClientState.get()
			if profile == nil then
				return
			end

			-- Category tabs ---------------------------------------------------------------------------
			Kit.clear(tabs)
			local rows = LoadoutView.slots(profile, selectedLabel)
			for index, row in rows do
				local tab = Kit.button("", if row.Selected then "secondary" else "ghost", function()
					selectedLabel = row.Label
					render()
				end, { Size = UDim2.new(1 / #rows, -7, 1, 0), LayoutOrder = index, Parent = tabs })
				Kit.label(string.upper(row.DisplayName), {
					Size = UDim2.new(1, -8, 0, 20), Position = UDim2.fromOffset(4, 8), TextSize = 13, Font = Theme.Fonts.Bold,
					TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd, Parent = tab,
				})
				Kit.label(`OVR {row.Ovr}`, {
					Size = UDim2.new(1, -8, 0, 22), Position = UDim2.fromOffset(4, 30), TextSize = 17, Font = Theme.Fonts.Title,
					TextColor3 = if row.Selected then C.Text else C.Gold, TextXAlignment = Enum.TextXAlignment.Center, Parent = tab,
				})
				-- Rarity strip along the bottom of the tab.
				Kit.new("Frame", { Size = UDim2.new(1, -20, 0, 3), Position = UDim2.new(0, 10, 1, -6), BackgroundColor3 = rarityColor(row.Rarity), BorderSizePixel = 0, Parent = tab }, { Kit.corner(2) })
			end

			-- Selected club ------------------------------------------------------------------------------
			Kit.clear(left)
			local clubId = profile.EquippedClubs[selectedLabel]
			local detail = if clubId then LoadoutView.detail(profile, clubId) else nil
			local category = ClubStats.get(selectedLabel)
			if detail == nil or category == nil then
				return
			end
			local head = Kit.panel({ Size = UDim2.new(1, -8, 0, 104), LayoutOrder = 1, Parent = left })
			Kit.label(detail.Name, { Size = UDim2.new(1, -140, 0, 32), Position = UDim2.fromOffset(16, 10), TextSize = 22, Font = Theme.Fonts.Title, TextTruncate = Enum.TextTruncate.AtEnd, Parent = head })
			Kit.label(`{detail.Brand}  ·  {string.upper(detail.Rarity)}  ·  {detail.LoftDeg}° loft`, { Size = UDim2.new(1, -140, 0, 20), Position = UDim2.fromOffset(16, 42), TextSize = 14, TextColor3 = rarityColor(detail.Rarity), Font = Theme.Fonts.Bold, Parent = head })
			Kit.label(`{category.Blurb}   Team OVR {LoadoutView.playerOvr(profile)}`, { Size = UDim2.new(1, -140, 0, 34), Position = UDim2.fromOffset(16, 64), TextSize = 13, TextColor3 = C.TextDim, Font = Theme.Fonts.Body, TextYAlignment = Enum.TextYAlignment.Top, Parent = head })
			local badge = Kit.new("Frame", { Size = UDim2.fromOffset(104, 80), Position = UDim2.new(1, -116, 0, 12), BackgroundColor3 = C.PanelDark, BorderSizePixel = 0, Parent = head }, { Kit.corner(12), Kit.stroke(C.Gold, 2) })
			Kit.label("OVR", { Size = UDim2.new(1, 0, 0, 22), Position = UDim2.fromOffset(0, 6), TextSize = 14, Font = Theme.Fonts.Bold, TextColor3 = C.TextDim, TextXAlignment = Enum.TextXAlignment.Center, Parent = badge })
			Kit.label(tostring(detail.Ovr), { Size = UDim2.new(1, 0, 0, 44), Position = UDim2.fromOffset(0, 28), TextSize = 40, Font = Theme.Fonts.Title, TextColor3 = C.Gold, TextXAlignment = Enum.TextXAlignment.Center, Parent = badge })

			local stats = Kit.panel({ Size = UDim2.new(1, -8, 0, 3 * 66 + 16), LayoutOrder = 2, Parent = left })
			for index, stat in detail.Stats do
				local row = Kit.new("Frame", { Size = UDim2.new(1, -24, 0, 58), Position = UDim2.fromOffset(12, 8 + (index - 1) * 66), BackgroundTransparency = 1, Parent = stats }) :: Frame
				Kit.label(string.upper(stat.Stat), { Size = UDim2.new(0.3, 0, 0, 22), Position = UDim2.fromOffset(4, 4), TextSize = 16, Font = Theme.Fonts.Title, Parent = row })
				Kit.label(STAT_BLURBS[stat.Stat] or "", { Size = UDim2.new(0.3, 0, 0, 30), Position = UDim2.fromOffset(4, 26), TextSize = 11, TextColor3 = C.TextDim, Font = Theme.Fonts.Body, TextYAlignment = Enum.TextYAlignment.Top, Parent = row })
				-- Bar: max reachable (faint) behind current (green), level underneath.
				local bar = Kit.new("Frame", { Size = UDim2.new(0.34, -12, 0, 14), Position = UDim2.new(0.3, 8, 0, 10), BackgroundColor3 = C.PanelDark, BorderSizePixel = 0, Parent = row }, { Kit.corner(7) }) :: Frame
				Kit.new("Frame", { Size = UDim2.fromScale(math.clamp(stat.MaxValue / 100, 0, 1), 1), BackgroundColor3 = C.PanelLight, BorderSizePixel = 0, Parent = bar }, { Kit.corner(7) })
				Kit.new("Frame", { Size = UDim2.fromScale(math.clamp(stat.Value / 100, 0, 1), 1), BackgroundColor3 = C.Accent, BorderSizePixel = 0, ZIndex = 2, Parent = bar }, { Kit.corner(7), Kit.gradient(C.Good, C.AccentDark) })
				Kit.label(`Level {stat.Level} / {stat.MaxLevel}`, { Size = UDim2.new(0.34, -12, 0, 18), Position = UDim2.new(0.3, 8, 0, 30), TextSize = 12, TextColor3 = C.TextDim, Font = Theme.Fonts.Body, Parent = row })
				Kit.label(tostring(stat.Value), { Size = UDim2.new(0.1, 0, 0, 40), Position = UDim2.new(0.64, 0, 0, 4), TextSize = 26, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center, Parent = row })
				local props = { Size = UDim2.new(0.26, 0, 0, 44), Position = UDim2.new(0.74, 0, 0, 4), TextSize = 14, Parent = row }
				if stat.CanUpgrade then
					Kit.priceButton("UPGRADE", "Coins", Format.commas(stat.UpgradeCost or 0), "primary", function()
						request("UpgradeClub", detail.ClubId, stat.Stat)
					end, props)
				else
					Kit.button(string.upper(stat.Reason or "MAXED"), "ghost", function()
						Toast.show(stat.Reason or "Can't upgrade that.", "error")
					end, props).TextWrapped = true
				end
			end

			-- Other clubs in this category --------------------------------------------------------------
			local owned = LoadoutView.ownedFor(profile, selectedLabel)
			local forSale = LoadoutView.shopFor(profile, selectedLabel)
			local order = 3
			Kit.label(`{string.upper(category.DisplayName)} OPTIONS`, { Size = UDim2.new(1, 0, 0, 24), TextSize = 14, TextColor3 = C.TextDim, Font = Theme.Fonts.Bold, LayoutOrder = order, Parent = left })
			local function optionRow(name: string, rarity: string, ovr: number): Frame
				order += 1
				local row = Kit.panel({ Size = UDim2.new(1, -8, 0, 52), LayoutOrder = order, Parent = left })
				Kit.label(name, { Size = UDim2.new(0.55, -14, 1, 0), Position = UDim2.fromOffset(14, 0), TextSize = 15, TextColor3 = rarityColor(rarity), Font = Theme.Fonts.Bold, TextTruncate = Enum.TextTruncate.AtEnd, Parent = row })
				Kit.label(`OVR {ovr}`, { Size = UDim2.new(0.15, 0, 1, 0), Position = UDim2.fromScale(0.55, 0), TextSize = 15, Font = Theme.Fonts.Title, TextColor3 = C.Gold, Parent = row })
				return row
			end
			for _, club in owned do
				local row = optionRow(club.Name, club.Rarity, club.Ovr)
				Kit.button(if club.Equipped then "EQUIPPED" else "EQUIP", if club.Equipped then "ghost" else "secondary", function()
					if not club.Equipped then
						request("EquipClub", club.ClubId)
					end
				end, { Size = UDim2.new(0.28, 0, 0, 36), Position = UDim2.new(0.71, 0, 0.5, -18), TextSize = 14, Parent = row })
			end
			for _, club in forSale do
				local row = optionRow(club.Name, club.Rarity, club.Ovr)
				Kit.priceButton("BUY", "Coins", Format.commas(club.Price), if club.CanAfford then "primary" else "ghost", function()
					if not club.CanAfford then
						Toast.show("Not enough coins.", "error")
						return
					end
					request("BuyClub", club.ClubId)
				end, { Size = UDim2.new(0.28, 0, 0, 36), Position = UDim2.new(0.71, 0, 0.5, -18), TextSize = 14, Parent = row })
			end

			-- Skins --------------------------------------------------------------------------------------------
			skinTitle.Text = `{string.upper(category.DisplayName)} SKINS`
			Kit.clear(skinGrid)
			for index, skin in LoadoutView.skinsFor(profile, category.Class) do
				ItemCard.new({
					Name = skin.Name, Color = skin.Color, Subtitle = string.upper(skin.Rarity), Primary = skin.Primary, Secondary = skin.Secondary,
					Glyph = ItemCard.glyphFor(category.Class), Locked = not skin.Owned, Selected = skin.Equipped,
					Footer = if skin.Equipped then "✔ EQUIPPED" elseif skin.Owned then "OWNED" else "LOCKED",
					FooterColor = if skin.Equipped then C.Good elseif skin.Owned then C.Text else C.TextDim,
					LayoutOrder = index,
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
