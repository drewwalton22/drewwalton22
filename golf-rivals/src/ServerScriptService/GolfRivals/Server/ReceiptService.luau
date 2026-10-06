--!strict
-- ROBLOX-ONLY: owns MarketplaceService.ProcessReceipt.
--[[
	ReceiptService.luau  (ServerScriptService.GolfRivals.Server)

	The game's ONE ProcessReceipt callback (Roblox allows exactly one). Features
	register a handler per Developer Product id:

	    ReceiptService.register(productId, function(player, data, receipt): boolean ... end)

	Roblox's rules for Developer Products are followed strictly:
	  * the player must be in the server with their profile loaded, otherwise
	    NotProcessedYet (Roblox retries later, e.g. when they rejoin)
	  * the handler grants idempotently (it records receipt.PurchaseId in the
	    profile, so a re-delivered receipt never grants twice)
	  * the profile is SAVED before PurchaseGranted is returned - a purchase is
	    never acknowledged while it only exists in memory
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Logger = require(Shared.Logger)
local ProfileTemplate = require(Shared.ProfileTemplate)
local ProfileService = require(script.Parent.ProfileService)

export type Handler = (player: Player, data: ProfileTemplate.ProfileData, receipt: any) -> boolean

local ReceiptService = {}

local handlers: { [number]: Handler } = {}

function ReceiptService.register(productId: number, handler: Handler)
	if productId > 0 then
		handlers[productId] = handler
	end
end

function ReceiptService.start()
	MarketplaceService.ProcessReceipt = function(receipt: any): Enum.ProductPurchaseDecision
		local handler = handlers[receipt.ProductId]
		if handler == nil then
			Logger.info("Receipts", `no handler for product {receipt.ProductId}`)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		local player = Players:GetPlayerByUserId(receipt.PlayerId)
		local data = if player then ProfileService.get(player) else nil
		if player == nil or data == nil then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		local ok, err = pcall(function()
			handler(player, data, receipt)
			return true
		end)
		if not ok then
			Logger.info("Receipts", `handler failed for {receipt.PurchaseId}: {tostring(err)}`)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		if not ProfileService.saveNow(player) then
			-- Granted in memory but not on disk yet: let Roblox retry; the handler is
			-- idempotent, so the retry won't double-grant.
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	Logger.info("Receipts", "Receipt processing ready.")
end

return ReceiptService
