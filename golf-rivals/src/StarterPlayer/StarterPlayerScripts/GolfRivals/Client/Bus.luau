--!strict
--[[
	Bus.luau  (Client)

	App-level events that connect the lobby, the match view and the driving range
	without any of them requiring the others:

	  MatchEntered  a match started (hide the lobby UI, take over the camera)
	  MatchExited   the player left the match screen (show the lobby again)
	  OpenScreen    ask the lobby to open a screen by name ("Shop", "Cases", ...)
	  QueueStarted / QueueEnded / Queued   ranked-queue state shared by the Play screen and the HUD
	  RangeEntered / RangeExited           the player took / gave back a driving-range bay
	                                       (the lobby HUD hides while hitting balls)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage.GolfRivals.Shared.Signal)

local Bus = {
	MatchEntered = Signal.new(),
	MatchExited = Signal.new(),
	OpenScreen = Signal.new(),
	QueueStarted = Signal.new(), -- fires (leagueId: string) after the server accepts QueueRanked
	QueueEnded = Signal.new(), -- fires when the queue is cancelled or a match starts
	Queued = false, -- true while this player is in a ranked queue
	RangeEntered = Signal.new(),
	RangeExited = Signal.new(),
}

return Bus
