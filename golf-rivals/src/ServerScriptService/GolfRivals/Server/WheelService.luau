--!strict
-- ROBLOX-ONLY: binds remotes, the 3D lobby wheel and Developer Product receipts.
-- The spin rules (cooldown, weights, rewards, purchases) are the pure, tested
-- WheelRules module.
--[[
	WheelService.luau  (ServerScriptService.GolfRivals.Server)

	The daily wheelspin.

	  GetWheel()      -> the player's wheel state (free spin ready / time left /
	                     bought spins)
	  SpinWheel()     -> the SERVER rolls (weighted, Random), grants the reward into
	                     the profile, saves soon, and replies with the segment and the
	                     angle the wheel stops at; the client animates to it
	  BuyWheelSpin()  -> one extra spin for Config.Wheel.GemSpinPrice gems
	  Robux           -> Developer Product Config.Wheel.RobuxProductId, granted
	                     through ReceiptService (idempotent per PurchaseId)

	The last FREE spin time lives in the profile (Wheel.LastFreeSpinAt), which
	ProfileService saves to the DataStore - the 24 h cooldown survives server hops.

	THE 3D WHEEL: after each spin the lobby wheel (workspace.Lobby.DailyWheel) gets
	attributes SpinFrom / SpinTo / SpinStart / SpinDuration / SpinBy; every client
	animates it locally (smooth, no network jitter), so everyone in the lobby sees
	the wheel spin.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.GolfRivals.Shared
local Config = require(Shared.Config)
local Logger = require(Shared.Logger)
local ProfileTemplate = require(Shared.ProfileTemplate)
local Remotes = require(Shared.Remotes)
local WheelRules = require(Shared.WheelRules)
local ProfileService = require(script.Parent.ProfileService)
local ReceiptService = require(script.Parent.ReceiptService)

local WheelService = {}

WheelService.SPIN_SECONDS = 5

local random = Random.new()
local spinning: { [Player]: boolean } = {}

local function push(player: Player, data: ProfileTemplate.ProfileData)
	local view = ProfileTemplate.clientView(data)
	ProfileService.notify(player, { Coins = view.Coins, Gems = view.Gems, OwnedItems = view.OwnedItems, Wheel = view.Wheel, Stats = view.Stats })
	ProfileService.saveSoon(player)
end

local function wheelPart(): BasePart?
	local lobby = workspace:FindFirstChild("Lobby")
	local part = if lobby then lobby:FindFirstChild("DailyWheel") else nil
	return if part and part:IsA("BasePart") then part else nil
end

-- Start the shared 3D wheel animation toward `angle`.
local function spinLobbyWheel(angle: number, player: Player)
	local part = wheelPart()
	if part == nil then
		return
	end
	local from = part:GetAttribute("SpinTo")
	part:SetAttribute("SpinFrom", if type(from) == "number" then from % 360 else 0)
	part:SetAttribute("SpinTo", angle)
	part:SetAttribute("SpinStart", workspace:GetServerTimeNow())
	part:SetAttribute("SpinDuration", WheelService.SPIN_SECONDS)
	part:SetAttribute("SpinBy", player.DisplayName)
end

function WheelService.start()
	Remotes.onInvoke("GetWheel", function(player: Player): any
		local data = ProfileService.get(player)
		if data == nil then
			return { ok = false, reason = "not_loaded" }
		end
		return { ok = true, State = WheelRules.state(data, os.time()) }
	end)

	Remotes.onInvoke("SpinWheel", function(player: Player): any
		local data = ProfileService.get(player)
		if data == nil then
			return { ok = false, reason = "not_loaded" }
		end
		if spinning[player] then
			return { ok = false, reason = "already_spinning" }
		end
		local result, why = WheelRules.spin(data, os.time(), function(): number
			return random:NextNumber()
		end)
		if result == nil then
			return { ok = false, reason = why, State = WheelRules.state(data, os.time()) }
		end
		push(player, data)
		-- Lock out a second spin until this one has finished animating.
		spinning[player] = true
		task.delay(WheelService.SPIN_SECONDS, function()
			spinning[player] = nil
		end)
		local angle = WheelRules.restingAngle(result.SegmentIndex, random:NextInteger(5, 7), random:NextNumber() * 2 - 1)
		spinLobbyWheel(angle, player)
		Logger.info("Wheel", `{player.Name} spun {result.SegmentId} ({if result.UsedFree then "free" else "bought"})`)
		return {
			ok = true,
			SegmentIndex = result.SegmentIndex,
			Reward = result.Reward,
			UsedFree = result.UsedFree,
			Angle = angle,
			Duration = WheelService.SPIN_SECONDS,
			State = WheelRules.state(data, os.time()),
		}
	end)

	Remotes.onInvoke("BuyWheelSpin", function(player: Player): any
		local data = ProfileService.get(player)
		if data == nil then
			return { ok = false, reason = "not_loaded" }
		end
		local ok, why = WheelRules.buyWithGems(data)
		if not ok then
			return { ok = false, reason = why }
		end
		push(player, data)
		return { ok = true, State = WheelRules.state(data, os.time()) }
	end)

	ReceiptService.register(Config.Wheel.RobuxProductId, function(player: Player, data: ProfileTemplate.ProfileData, receipt: any): boolean
		local granted = WheelRules.grantPurchase(data, tostring(receipt.PurchaseId))
		if granted then
			push(player, data)
			Remotes.fireClient("Notify", player, "Thanks! Extra wheel spin added.", "success")
		end
		return granted
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		spinning[player] = nil
	end)
	Logger.info("Wheel", "Daily wheel ready.")
end

return WheelService
