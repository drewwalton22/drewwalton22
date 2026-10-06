--!strict
--[[
	CasesScreen.luau  (Client/Lobby)

	Loot cases (mockup panels 4, 5 and 6).

	  1. Pick a case on the left (the drop-rate table is on the right), pick 1/3/5/10,
	     press OPEN.
	  2. OpenCases goes to the server, which charges, rolls and grants everything. The
	     reply lists the real drops.
	  3. A roulette row per drop spins and decelerates onto the real item (decoration:
	     the outcome was decided on the server before the first frame). SKIP ALL jumps
	     straight to the results.
	  4. Results: the items, EQUIP for new ones, SELL ALL (spare copies only, at the
	     rarity sell values) and OPEN ANOTHER.

	LAYOUT: the three columns are proportional (26% / 46% / 28%), so the quantity
	buttons and the description always fit the window, whatever the screen size.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.GolfRivals.Shared
local CaseDatabase = require(Shared.CaseDatabase)
local CasesView = require(Shared.CasesView)
local Format = require(Shared.Format)
local ItemDatabase = require(Shared.ItemDatabase)
local Rarity = require(Shared.Rarity)
local Remotes = require(Shared.Remotes)

local ClientState = require(script.Parent.Parent.ClientState)
local ItemCard = require(script.Parent.Parent.UI.ItemCard)
local Kit = require(script.Parent.Parent.UI.Kit)
local Theme = require(script.Parent.Parent.UI.Theme)
local Toast = require(script.Parent.Parent.UI.Toast)
local ModalHost = require(script.Parent.ModalHost)
local Reasons = require(script.Parent.Reasons)

local CasesScreen = {}

local C = Theme.Colors

local STRIP_LENGTH = 42
local FINAL_INDEX = 35
local CARD_WIDTH = 104

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

-- A compact card for the roulette strip.
local function miniCard(itemId: string, height: number): Frame
	local item = ItemDatabase.get(itemId)
	local color = if item then rgb(Rarity.Info[item.Rarity].Color) else C.Stroke
	local frame = Kit.new("Frame", { Size = UDim2.fromOffset(CARD_WIDTH - 6, height), BackgroundColor3 = C.PanelDark, BorderSizePixel = 0 }, {
		Kit.corner(8),
		Kit.stroke(color, 2),
	}) :: Frame
	Kit.new("Frame", { Size = UDim2.new(1, 0, 0, 5), BackgroundColor3 = color, BorderSizePixel = 0, Parent = frame })
	Kit.label(if item then ItemCard.glyphFor(item.Slot) else "?", { Size = UDim2.new(1, 0, 0.5, 0), Position = UDim2.fromScale(0, 0.1), TextSize = math.clamp(height * 0.4, 18, 44), TextXAlignment = Enum.TextXAlignment.Center, Parent = frame })
	Kit.label(if item then item.Name else "", { Size = UDim2.new(1, -8, 0, 20), Position = UDim2.new(0, 4, 1, -24), TextSize = 11, TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd, Parent = frame })
	return frame
end

CasesScreen.factory = {
	Title = "CASES",
	create = function(content: Frame, _host: ModalHost.Host): ModalHost.ScreenApi
		local selected = CaseDatabase.Order[1]
		local quantity = 1
		local busy = false
		local activeTweens: { Tween } = {}

		-- ---- main view --------------------------------------------------------------------------
		local main = Kit.new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = content }) :: Frame
		local caseColumn = Kit.new("ScrollingFrame", {
			Size = UDim2.new(0.26, 0, 1, 0), BackgroundTransparency = 1, BorderSizePixel = 0, CanvasSize = UDim2.new(0, 0, 0, 0),
			AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 4, Parent = main,
		}, { Kit.list(Enum.FillDirection.Vertical, 10), Kit.padding(2) }) :: ScrollingFrame
		local center = Kit.panel({ Size = UDim2.new(0.46, -24, 1, 0), Position = UDim2.new(0.26, 12, 0, 0), Parent = main })
		local oddsPanel = Kit.panel({ Size = UDim2.new(0.28, 0, 1, 0), Position = UDim2.fromScale(0.72, 0), Parent = main })

		local crate = Kit.new("Frame", { Size = UDim2.fromOffset(170, 140), Position = UDim2.new(0.5, -85, 0, 18), BackgroundColor3 = C.Gold, BorderSizePixel = 0, Parent = center }, {
			Kit.corner(18),
			Kit.new("UIGradient", { Color = ColorSequence.new(Color3.fromRGB(255, 214, 90), Color3.fromRGB(190, 120, 20)), Rotation = 90 }),
		}) :: Frame
		Kit.label("📦", { Size = UDim2.fromScale(1, 1), TextSize = 84, TextXAlignment = Enum.TextXAlignment.Center, Parent = crate })
		local caseName = Kit.label("", { Size = UDim2.new(1, -20, 0, 32), Position = UDim2.fromOffset(10, 166), TextSize = 24, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.Gold, TextTruncate = Enum.TextTruncate.AtEnd, Parent = center })
		-- Room for three wrapped lines; long text shrinks rather than clipping.
		local caseDesc = Kit.label("", {
			Size = UDim2.new(1, -32, 0, 58), Position = UDim2.fromOffset(16, 200), TextSize = 14, TextColor3 = C.TextDim, TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Top, TextScaled = true, Font = Theme.Fonts.Body, Parent = center,
		})
		Kit.new("UITextSizeConstraint", { MaxTextSize = 15, MinTextSize = 10, Parent = caseDesc })
		local qtyRow = Kit.new("Frame", { Size = UDim2.new(1, -32, 0, 42), Position = UDim2.new(0, 16, 1, -118), BackgroundTransparency = 1, Parent = center }, {
			Kit.list(Enum.FillDirection.Horizontal, 8, { HorizontalAlignment = Enum.HorizontalAlignment.Center }),
		}) :: Frame
		local openButton, setOpenText = Kit.priceButton("OPEN CASE", "Coins", nil, "primary", nil, { Size = UDim2.new(1, -32, 0, 56), Position = UDim2.new(0, 16, 1, -68), TextSize = 20, Parent = center })

		Kit.label("DROP RATES", { Size = UDim2.new(1, -24, 0, 26), Position = UDim2.fromOffset(14, 10), TextSize = 16, TextColor3 = C.TextDim, Parent = oddsPanel })
		local oddsList = Kit.new("Frame", { Size = UDim2.new(1, -24, 1, -56), Position = UDim2.fromOffset(12, 44), BackgroundTransparency = 1, Parent = oddsPanel }, { Kit.list(Enum.FillDirection.Vertical, 8) }) :: Frame

		-- ---- overlays -------------------------------------------------------------------------------
		local layer = Kit.panel({ Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.Background, Visible = false, ZIndex = 10, Parent = content })

		local function clearLayer()
			for _, child in layer:GetChildren() do
				if child:IsA("GuiObject") then
					child:Destroy()
				end
			end
		end

		local function render()
			local profile = ClientState.get()
			if profile == nil then
				return
			end
			local cards = CasesView.cards(profile)
			Kit.clear(caseColumn)
			for index, card in cards do
				local isSelected = card.Id == selected
				local button = Kit.button("", if isSelected then "secondary" else "ghost", function()
					selected = card.Id
					render()
				end, { Size = UDim2.new(1, -6, 0, 86), LayoutOrder = index, Parent = caseColumn })
				Kit.label("📦", { Size = UDim2.fromOffset(52, 86), Position = UDim2.fromOffset(6, 0), TextSize = 34, TextXAlignment = Enum.TextXAlignment.Center, Parent = button })
				Kit.label(card.Name, { Size = UDim2.new(1, -66, 0, 40), Position = UDim2.fromOffset(60, 8), TextSize = 15, TextYAlignment = Enum.TextYAlignment.Top, Parent = button })
				Kit.amount("Coins", card.PriceText, { TextSize = 15, Position = UDim2.fromOffset(60, 54), Parent = button })
			end

			local current = CaseDatabase.Cases[selected]
			caseName.Text = string.upper(current.Name)
			caseDesc.Text = current.Description

			Kit.clear(oddsList)
			for _, odds in cards[table.find(CaseDatabase.Order, selected) :: number].Odds do
				local row = Kit.new("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, Parent = oddsList }) :: Frame
				Kit.new("Frame", { Size = UDim2.fromOffset(14, 14), Position = UDim2.fromOffset(4, 8), BackgroundColor3 = rgb(odds.Color), BorderSizePixel = 0, Parent = row }, { Kit.corner(7) })
				Kit.label(odds.Rarity, { Size = UDim2.new(1, -90, 1, 0), Position = UDim2.fromOffset(28, 0), TextSize = 16, TextColor3 = rgb(odds.Color), Font = Theme.Fonts.Bold, Parent = row })
				Kit.label(`{odds.Percent}%`, { Size = UDim2.fromOffset(60, 30), Position = UDim2.new(1, -60, 0, 0), TextSize = 16, TextXAlignment = Enum.TextXAlignment.Right, Parent = row })
			end

			Kit.clear(qtyRow)
			local maxAffordable = cards[table.find(CaseDatabase.Order, selected) :: number].MaxAffordable
			for _, n in CasesView.Quantities do
				Kit.button(`x{n}`, if n == quantity then "secondary" else "ghost", function()
					quantity = n
					render()
				end, { Size = UDim2.new(1 / #CasesView.Quantities, -8, 1, 0), TextSize = 17, TextTransparency = if n > maxAffordable then 0.5 else 0, LayoutOrder = n, Parent = qtyRow })
			end
			local total = CasesView.total(selected, quantity)
			local canOpen, why = CasesView.canOpen(profile, selected, quantity)
			if canOpen then
				setOpenText(`OPEN {if quantity > 1 then quantity .. " CASES" else "CASE"}`, Format.commas(total.Amount))
			else
				setOpenText(string.upper(why or "CAN'T OPEN"), nil)
			end
			openButton.BackgroundColor3 = if canOpen then C.Accent else C.PanelLight
		end

		-- ---- results ------------------------------------------------------------------------------------
		local function showResults(drops: { any })
			local profile = ClientState.get()
			if profile == nil then
				return
			end
			clearLayer()
			layer.Visible = true
			local results = CasesView.results(drops, profile)
			Kit.label("YOUR REWARDS", { Size = UDim2.new(1, 0, 0, 50), Position = UDim2.fromOffset(0, 8), TextSize = 32, Font = Theme.Fonts.Title, TextXAlignment = Enum.TextXAlignment.Center, Parent = layer })
			local grid = Kit.new("ScrollingFrame", {
				Size = UDim2.new(1, -40, 1, -150), Position = UDim2.fromOffset(20, 66), BackgroundTransparency = 1, BorderSizePixel = 0,
				CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 6, Parent = layer,
			}, { Kit.grid(UDim2.fromOffset(130, 196), 12, { HorizontalAlignment = Enum.HorizontalAlignment.Center }), Kit.padding(4) }) :: ScrollingFrame
			for index, card in results.Cards do
				local slot = Kit.new("Frame", { BackgroundTransparency = 1, LayoutOrder = index, Parent = grid }) :: Frame
				local item = ItemDatabase.get(card.ItemId)
				ItemCard.new({
					Name = card.Name, Color = card.Color, Subtitle = `{string.upper(card.Rarity)} · {card.SlotLabel}`,
					Primary = card.Primary, Secondary = card.Secondary, Glyph = if item then ItemCard.glyphFor(item.Slot) else "⭐",
					Badge = if card.IsNew then "NEW" else nil, Size = UDim2.fromOffset(124, 150),
				}).Parent = slot
				if card.IsNew then
					Kit.button("EQUIP", "secondary", function()
						local reply = Remotes.invoke("EquipItem", card.ItemId)
						if type(reply) == "table" and reply.ok then
							Toast.show(`Equipped {card.Name}`, "success")
						else
							Toast.show(Reasons.text(if type(reply) == "table" then reply.reason else nil), "error")
						end
					end, { Size = UDim2.fromOffset(124, 36), Position = UDim2.fromOffset(0, 156), TextSize = 14, Parent = slot })
				end
			end
			local sellButton, setSellText = Kit.priceButton(if results.SellValue > 0 then "SELL ALL" else "NOTHING TO SELL", "Coins", if results.SellValue > 0 then Format.commas(results.SellValue) else nil, "ghost", nil, {
				Size = UDim2.fromOffset(280, 52), Position = UDim2.new(0.5, -294, 1, -68), TextSize = 18, Parent = layer,
			})
			sellButton.Activated:Connect(function()
				if results.SellValue <= 0 then
					return
				end
				local reply = Remotes.invoke("SellItems", results.SellIds)
				if type(reply) == "table" and reply.ok then
					Toast.show(`Sold for {Format.commas(reply.CoinsGained)} coins`, "success")
					setSellText("SOLD", nil)
					results.SellValue = 0
				else
					Toast.show(Reasons.text(if type(reply) == "table" then reply.reason else nil), "error")
				end
			end)
			Kit.button("OPEN ANOTHER", "primary", function()
				layer.Visible = false
				clearLayer()
				render()
			end, { Size = UDim2.fromOffset(280, 52), Position = UDim2.new(0.5, 14, 1, -68), TextSize = 18, Parent = layer })
		end

		-- ---- roulette ---------------------------------------------------------------------------------------
		local function showRoulette(drops: { any }, caseId: string)
			clearLayer()
			layer.Visible = true
			activeTweens = {}
			Kit.label(`OPENING {#drops} CASE{if #drops == 1 then "" else "S"}...`, { Size = UDim2.new(1, -200, 0, 44), Position = UDim2.fromOffset(20, 6), TextSize = 26, Font = Theme.Fonts.Title, Parent = layer })
			local finished = false
			local function finish()
				if finished then
					return
				end
				finished = true
				for _, tween in activeTweens do
					tween:Cancel()
				end
				showResults(drops)
			end
			Kit.button("SKIP ALL", "ghost", finish, { Size = UDim2.fromOffset(150, 38), Position = UDim2.new(1, -170, 0, 8), TextSize = 15, ZIndex = 12, Parent = layer })

			local rowHeight = math.clamp(math.floor(430 / #drops), 56, 130)
			local holder = Kit.new("Frame", { Size = UDim2.new(1, -40, 1, -70), Position = UDim2.fromOffset(20, 56), BackgroundTransparency = 1, Parent = layer }, {
				Kit.list(Enum.FillDirection.Vertical, 6),
			}) :: Frame
			RunService.RenderStepped:Wait() -- let the layout size the rows before measuring

			local remaining = #drops
			for index, drop in drops do
				local row = Kit.new("Frame", { Size = UDim2.new(1, 0, 0, rowHeight), BackgroundColor3 = C.PanelDark, BorderSizePixel = 0, ClipsDescendants = true, LayoutOrder = index, Parent = holder }, { Kit.corner(8) }) :: Frame
				local strip = Kit.new("Frame", { Size = UDim2.fromOffset(CARD_WIDTH * STRIP_LENGTH, rowHeight), BackgroundTransparency = 1, Parent = row }) :: Frame
				local ids = CasesView.strip(caseId, drop.ItemId, STRIP_LENGTH, FINAL_INDEX, math.floor(os.clock() * 1000) + index * 7919)
				for position, id in ids do
					local card = miniCard(id, rowHeight - 8)
					card.Position = UDim2.fromOffset((position - 1) * CARD_WIDTH + 3, 4)
					card.Parent = strip
				end
				-- The marker the real item stops under.
				Kit.new("Frame", { Size = UDim2.new(0, 3, 1, 0), Position = UDim2.new(0.5, -1, 0, 0), BackgroundColor3 = C.Gold, BorderSizePixel = 0, ZIndex = 5, Parent = row })
				local rowWidth = math.max(row.AbsoluteSize.X, 600)
				local jitter = (math.random() - 0.5) * CARD_WIDTH * 0.5
				local target = -((FINAL_INDEX - 1) * CARD_WIDTH + CARD_WIDTH / 2 - rowWidth / 2 + jitter)
				local tween = game:GetService("TweenService"):Create(strip, TweenInfo.new(3.2 + index * 0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Position = UDim2.fromOffset(target, 0) })
				table.insert(activeTweens, tween)
				tween.Completed:Connect(function(state: Enum.PlaybackState)
					if state == Enum.PlaybackState.Completed then
						remaining -= 1
						if remaining == 0 then
							task.delay(0.7, finish)
						end
					end
				end)
				tween:Play()
			end
		end

		openButton.Activated:Connect(function()
			local profile = ClientState.get()
			if busy or profile == nil then
				return
			end
			local canOpen, why = CasesView.canOpen(profile, selected, quantity)
			if not canOpen then
				Toast.show(why or "Can't open that.", "error")
				return
			end
			busy = true
			local caseId = selected
			local reply = Remotes.invoke("OpenCases", caseId, quantity)
			busy = false
			if type(reply) == "table" and reply.ok and type(reply.Drops) == "table" then
				showRoulette(reply.Drops, caseId)
			else
				Toast.show(Reasons.text(if type(reply) == "table" then reply.reason else nil), "error")
			end
		end)

		return {
			refresh = function()
				if not layer.Visible then
					render()
				end
			end,
			onClose = function()
				for _, tween in activeTweens do
					tween:Cancel()
				end
				layer.Visible = false
				clearLayer()
			end,
		}
	end,
} :: ModalHost.Factory

return CasesScreen
