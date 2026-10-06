--!strict
--[[
	Logger.luau  (ReplicatedStorage.GolfRivals.Shared)

	Consistent console output: "[GolfRivals][Scope] message".
	Every system announces what it is starting/doing through this module so the
	Output window reads like a build log while you follow along.
]]

local Logger = {}

-- Flip to false before shipping to silence routine info logs.
Logger.Enabled = true

function Logger.info(scope: string, message: string)
	if Logger.Enabled then
		print(string.format("[GolfRivals][%s] %s", scope, message))
	end
end

return Logger
