--!strict
--[[
	Bus.luau  (Client)

	App-level events that connect the lobby and the match view without either
	requiring the other:

	  MatchEntered  a match started (hide the lobby UI, take over the camera)
	  MatchExited   the player left the match screen (show the lobby again)
	  OpenScreen    ask the lobby to open a screen by name ("Shop", "Cases", ...)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage.GolfRivals.Shared.Signal)

local Bus = {
	MatchEntered = Signal.new(),
	MatchExited = Signal.new(),
	OpenScreen = Signal.new(),
}

return Bus
