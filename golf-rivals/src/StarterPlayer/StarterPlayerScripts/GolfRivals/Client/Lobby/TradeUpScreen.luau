--!strict
--[[
	TradeUpScreen.luau  (Client/Lobby)

	Trade-Up Contract (mockup panel 7): put 5 items of one rarity into the contract and
	receive 1 item of the next rarity up. The left side lists what you can trade (spare
	copies only; Mythical can't go higher). Clicking adds to the contract, clicking a
	filled slot removes it. TradeUpView mirrors the server's rules so bad picks are
	refused instantly; the server re-checks everything when you press TRADE UP.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Config = require(Shared.Config)
local ItemDatabase = require(Shared.ItemDatabase)
local Rarity = require(Shared.Rarity)
local Remotes = require(Shared.Remotes)
local ShopView = require(Shared.ShopView)
local TradeUpView = require(Shared.TradeUpView)

local ClientState = require(script.Parent.Parent.ClientState)
local ItemCard = require(script.Parent.Parent.UI.ItemCard)
local Kit = require(script.Parent.Parent.UI.Kit)
local Theme = require(script.Parent.Parent.UI.Theme)
local Toast = require(script.Parent.Parent.UI.Toast)
local ModalHost = require(script.Parent.ModalHost)
local Reasons = require(script.Parent.Reasons)

local TradeUpScreen = {}

local C = Theme.Colors

TradeUpScreen.factory = {
	Title = "TRADE-UP CONTRACT",
	create = function(content: Frame, _host: ModalHost.Host): ModalHost.ScreenApi
		local selection: { string } = {}
		local busy = false

		Kit.label("YOUR ITEMS", { Size = UDim2.new(0.5, -10, 0, 24), TextSize = 14, TextColor3 = C.TextDim, Font = Theme.Fonts.Bold, Parent = content })
		local inventory = Kit.new("ScrollingFrame", {
			Size = UDim2.new(0.5, -10, 1, -30), Position = UDim2.fromOffset(0, 28), BackgroundTransparency = 1, BorderSizePixel = 0,
			CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 6, Parent = content,
		}, { Kit.grid(UDim2.fromOffset(124, 150), 10), Kit.padding(2) }) :: ScrollingFrame

		local right = Kit.panel({ Size = UDim2.new(0.5, -10, 1, 0), Position = UDim2.new(0.5, 10, 0, 0), Parent = content })
		Kit.label(`CONTRACT  ·  {Config.TradeUp.InputCount} ITEMS OF ONE RARITY`, { Size = UDim2.new(1, -20, 0, 26), Position = UDim2.fromOffset(14, 10), TextSize = 14, TextColor3 = C.TextDim, Font = Theme.Fonts.Bold, Parent = right })
		-- Five slots always fit one row (proportional cells), so the result card
		-- below never covers slot 5 on narrow windows.
		local slots = Kit.new("Frame", { Size = UDim2.new(1, -20, 0, 128), Position = UDim2.fromOffset(10, 42), BackgroundTransparency = 1, Parent = right }, {
			Kit.grid(UDim2.new(1 / Config.TradeUp.InputCount, -6, 0, 124), 6, { HorizontalAlignment = Enum.HorizontalAlignment.Center }),
		}) :: Frame
		local resultArea = Kit.new("Frame", { Size = UDim2.new(1, -20, 0, 166), Position = UDim2.fromOffset(10, 178), BackgroundTransparency = 1, Parent = right }) :: Frame
		local message = Kit.label("", { Size = UDim2.new(1, -24, 0, 44), Position = UDim2.new(0, 12, 1, -130), TextSize = 16, TextXAlignment = Enum.TextXAlignment.Center, Parent = right })
		local tradeButton = Kit.button("TRADE UP", "primary", nil, { Size = UDim2.new(1, -40, 0, 56), Position = UDim2.new(0, 20, 1, -72), TextSize = 22, Parent = right })

		local render: () -> ()

		local function showReward(reward: any)
			local item = ItemDatabase.get(reward.ItemId)
			if item == nil then
				return
			end
			local overlay = Kit.panel({ Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.Background, ZIndex = 10, Parent = content })
			Kit.label("YOU RECEIVED", { Size = UDim2.new(1, 0, 0, 50), Position = UDim2.fromOffset(0, 40), TextSize = 32, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 11, Parent = overlay })
			local card = ItemCard.new({
				Name = item.Name, Color = Rarity.Info[item.Rarity].Color, Subtitle = `{string.upper(item.Rarity)} · {ShopView.slotLabel(item)}`,
				Primary = item.Visual.Primary, Secondary = item.Visual.Secondary, Glyph = ItemCard.glyphFor(item.Slot),
				Badge = if reward.IsNew then "NEW" else nil, Size = UDim2.fromOffset(190, 240),
			})
			card.Position = UDim2.new(0.5, -95, 0, 110)
			card.ZIndex = 11
			card.Parent = overlay
			Kit.button("AWESOME", "primary", function()
				overlay:Destroy()
				render()
			end, { Size = UDim2.fromOffset(240, 52), Position = UDim2.new(0.5, -120, 1, -90), TextSize = 20, ZIndex = 12, Parent = overlay })
		end

		render = function()
			local profile = ClientState.get()
			if profile == nil then
				return
			end
			-- Drop selected copies that are no longer spare (e.g. equipped meanwhile).
			local cleaned: { string } = {}
			for _, id in selection do
				if TradeUpView.canAdd(profile, cleaned, id) then
					table.insert(cleaned, id)
				end
			end
			selection = cleaned

			Kit.clear(inventory)
			local entries = TradeUpView.inventory(profile, selection)
			if #entries == 0 then
				Kit.label("You have no spare items to trade yet. Open cases or visit the shop!", { Size = UDim2.new(1, 0, 0, 50), TextColor3 = C.TextDim, Parent = inventory })
			end
			for index, entry in entries do
				local available = entry.Spare - entry.Selected
				ItemCard.new({
					Name = entry.Name, Color = entry.Color, Subtitle = `{string.upper(entry.Rarity)} · {entry.SlotLabel}`, Primary = entry.Primary, Secondary = entry.Secondary,
					Glyph = ItemCard.glyphFor((ItemDatabase.get(entry.ItemId) :: ItemDatabase.Item).Slot),
					Badge = `x{available}`, Locked = available <= 0, Size = UDim2.fromOffset(124, 150), LayoutOrder = index,
					OnClick = function()
						local ok, why = TradeUpView.canAdd(profile, selection, entry.ItemId)
						if ok then
							selection = TradeUpView.add(profile, selection, entry.ItemId)
							render()
						else
							Toast.show(why or "Can't add that.", "error")
						end
					end,
				}).Parent = inventory
			end

			Kit.clear(slots)
			for index = 1, Config.TradeUp.InputCount do
				local id = selection[index]
				local item = if id then ItemDatabase.get(id) else nil
				if item then
					ItemCard.new({
						Name = item.Name, Color = Rarity.Info[item.Rarity].Color, Primary = item.Visual.Primary, Secondary = item.Visual.Secondary,
						Glyph = ItemCard.glyphFor(item.Slot), LayoutOrder = index,
						OnClick = function()
							selection = TradeUpView.remove(selection, index)
							render()
						end,
					}).Parent = slots
				else
					local empty = Kit.panel({ BackgroundColor3 = C.PanelDark, LayoutOrder = index, Parent = slots })
					Kit.label(tostring(index), { Size = UDim2.fromScale(1, 1), TextSize = 30, TextColor3 = C.Stroke, TextXAlignment = Enum.TextXAlignment.Center, Parent = empty })
				end
			end

			local state = TradeUpView.state(selection)
			Kit.clear(resultArea)
			local nextColor = if state.NextRarity then Rarity.Info[state.NextRarity].Color else { 90, 100, 130 }
			local preview = ItemCard.new({
				Name = "???", Color = nextColor, Subtitle = if state.NextRarity then string.upper(state.NextRarity) else "RESULT", Glyph = "❓",
				Size = UDim2.fromOffset(120, 150),
			})
			preview.Position = UDim2.new(0.5, -60, 0, 8)
			preview.Parent = resultArea
			message.Text = state.Message
			message.TextColor3 = if state.Valid then C.Good else C.TextDim
			tradeButton.BackgroundColor3 = if state.Valid then C.Accent else C.PanelLight
			tradeButton.Text = if state.Valid then "TRADE UP" else `ADD {state.Needed - state.Count} MORE`
			tradeButton.TextWrapped = true
		end

		tradeButton.Activated:Connect(function()
			if busy or not TradeUpView.state(selection).Valid then
				return
			end
			busy = true
			local reply = Remotes.invoke("TradeUp", selection)
			busy = false
			if type(reply) == "table" and reply.ok and type(reply.Reward) == "table" then
				selection = {}
				showReward(reply.Reward)
			else
				Toast.show(Reasons.text(if type(reply) == "table" then reply.reason else nil), "error")
			end
			render()
		end)

		return {
			refresh = render,
			onClose = function()
				selection = {}
			end,
		}
	end,
} :: ModalHost.Factory

return TradeUpScreen
