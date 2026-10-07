--!strict
--[[
	ShopScreen.luau  (Client/Lobby)

	The daily rotating Skin Shop (mockup panel 3). Offers come from the server
	(GetShop); ShopView turns them into cards for the selected tab. Club skins have an
	extra class filter on the left. Buying calls BuyShopItem, then the shop is fetched
	again so the card flips to "OWNED".
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Format = require(Shared.Format)
local ItemDatabase = require(Shared.ItemDatabase)
local Remotes = require(Shared.Remotes)
local ShopView = require(Shared.ShopView)

local ClientState = require(script.Parent.Parent.ClientState)
local ItemCard = require(script.Parent.Parent.UI.ItemCard)
local Kit = require(script.Parent.Parent.UI.Kit)
local Theme = require(script.Parent.Parent.UI.Theme)
local Toast = require(script.Parent.Parent.UI.Toast)
local ModalHost = require(script.Parent.ModalHost)
local Reasons = require(script.Parent.Reasons)

local ShopScreen = {}

local C = Theme.Colors

ShopScreen.factory = {
	Title = "DAILY SHOP",
	create = function(content: Frame, _host: ModalHost.Host): ModalHost.ScreenApi
		local tab = "ClubSkin"
		local filter = "All"
		local offers: { ShopView.Offer } = {}
		local endsAt = 0
		local isOpen = false

		-- ---- chrome ---------------------------------------------------------------------
		local tabRow = Kit.new("Frame", { Size = UDim2.new(1, 0, 0, 44), BackgroundTransparency = 1, Parent = content }, {
			Kit.list(Enum.FillDirection.Horizontal, 8),
		}) :: Frame
		local filterColumn = Kit.new("Frame", { Size = UDim2.new(0, 170, 1, -100), Position = UDim2.fromOffset(0, 56), BackgroundTransparency = 1, Parent = content }, {
			Kit.list(Enum.FillDirection.Vertical, 6),
		}) :: Frame
		local grid = Kit.new("ScrollingFrame", {
			Size = UDim2.new(1, -184, 1, -100), Position = UDim2.fromOffset(184, 56), BackgroundTransparency = 1, BorderSizePixel = 0,
			CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 6, Parent = content,
		}, { Kit.grid(UDim2.fromOffset(132, 164), 12), Kit.padding(4) }) :: ScrollingFrame
		local footer = Kit.label("", { Size = UDim2.new(1, 0, 0, 30), Position = UDim2.new(0, 0, 1, -34), TextSize = 16, TextColor3 = C.Gold, Font = Theme.Fonts.Bold, Parent = content })

		local render: () -> ()

		local function buy(card: ShopView.Card)
			if card.Purchased then
				return
			end
			if not card.CanAfford then
				Toast.show(`You need {card.AmountText} {if card.Currency == "Gems" then "gems" else "coins"}.`, "error")
				return
			end
			local reply = Remotes.invoke("BuyShopItem", card.ItemId)
			if type(reply) == "table" and reply.ok then
				Toast.show(`Purchased {card.Name}!`, "success")
			else
				Toast.show(Reasons.text(if type(reply) == "table" then reply.reason else nil), "error")
			end
			local fresh = Remotes.invoke("GetShop")
			if type(fresh) == "table" and fresh.ok then
				offers, endsAt = fresh.Offers, fresh.EndsAt
			end
			render()
		end

		render = function()
			local profile = ClientState.get()
			if profile == nil then
				return
			end
			-- Tabs
			Kit.clear(tabRow)
			local counts = ShopView.tabCounts(offers)
			for index, entry in ShopView.Tabs do
				Kit.button(`{entry.Label}  ({counts[entry.Id] or 0})`, if entry.Id == tab then "secondary" else "ghost", function()
					tab = entry.Id
					render()
				end, { Size = UDim2.fromOffset(150, 40), TextSize = 13, LayoutOrder = index, Parent = tabRow })
			end
			-- Class filter (club skins only)
			Kit.clear(filterColumn)
			filterColumn.Visible = tab == "ClubSkin"
			grid.Size = if tab == "ClubSkin" then UDim2.new(1, -184, 1, -100) else UDim2.new(1, 0, 1, -100)
			grid.Position = if tab == "ClubSkin" then UDim2.fromOffset(184, 56) else UDim2.fromOffset(0, 56)
			for index, entry in ShopView.ClassFilters do
				Kit.button(entry.Label, if entry.Id == filter then "primary" else "ghost", function()
					filter = entry.Id
					render()
				end, { Size = UDim2.new(1, 0, 0, 40), TextSize = 14, LayoutOrder = index, Parent = filterColumn })
			end
			-- Cards
			Kit.clear(grid)
			local cards = ShopView.cards(offers, profile, tab, filter)
			if #cards == 0 then
				Kit.label("Nothing in this category today. Check back tomorrow!", { Size = UDim2.new(1, 0, 0, 40), TextColor3 = C.TextDim, Parent = grid })
			end
			for index, card in cards do
				local item = ItemDatabase.get(card.ItemId)
				ItemCard.new({
					Name = card.Name,
					Color = card.Color,
					Subtitle = `{string.upper(card.Rarity)} · {card.SlotLabel}`,
					Primary = card.Primary,
					Secondary = card.Secondary,
					Glyph = if item then ItemCard.glyphFor(item.Slot) else "⭐",
					ItemId = card.ItemId,
					Footer = if card.Purchased then "✔ OWNED TODAY" else nil,
					FooterPrice = if card.Purchased then nil else { Currency = card.Currency :: string, Text = card.AmountText },
					FooterColor = if card.Purchased then C.Good elseif card.CanAfford then (if card.Currency == "Gems" then C.Gem else C.Gold) else C.Poor,
					Badge = if card.OwnedCount > 0 and not card.Purchased then `x{card.OwnedCount}` else nil,
					LayoutOrder = index,
					OnClick = function()
						buy(card)
					end,
				}).Parent = grid
			end
		end

		local function fetch()
			local reply = Remotes.invoke("GetShop")
			if type(reply) == "table" and reply.ok then
				offers, endsAt = reply.Offers, reply.EndsAt
			end
			render()
		end

		return {
			refresh = render,
			onOpen = function()
				isOpen = true
				task.spawn(fetch)
				task.spawn(function()
					while isOpen do
						footer.Text = `{ShopView.countdown(endsAt, os.time())}   ·   a new selection every day`
						if endsAt > 0 and os.time() >= endsAt then
							fetch() -- the shop just rotated
						end
						task.wait(1)
					end
				end)
			end,
			onClose = function()
				isOpen = false
			end,
		}
	end,
} :: ModalHost.Factory

return ShopScreen
