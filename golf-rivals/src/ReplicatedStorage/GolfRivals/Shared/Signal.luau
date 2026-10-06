--!strict
--[[
	Signal.luau  (ReplicatedStorage.GolfRivals.Shared)

	A tiny event: connect(callback) returns a connection with disconnect(); fire(...)
	calls every connected callback. Callbacks may disconnect themselves (or others)
	while firing; a failing callback never stops the rest.
]]

export type Connection = {
	disconnect: () -> (),
}

export type Signal = {
	connect: (callback: (...any) -> ()) -> Connection,
	fire: (...any) -> (),
	count: () -> number,
}

local Signal = {}

function Signal.new(): Signal
	local callbacks: { [number]: (...any) -> () } = {}
	local nextId = 0

	local function connect(callback: (...any) -> ()): Connection
		nextId += 1
		local id = nextId
		callbacks[id] = callback
		return {
			disconnect = function()
				callbacks[id] = nil
			end,
		}
	end

	local function fire(...: any)
		-- Snapshot first so connect/disconnect during a fire is safe.
		local snapshot: { (...any) -> () } = {}
		local ids: { number } = {}
		for id in callbacks do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id in ids do
			table.insert(snapshot, callbacks[id])
		end
		local args = table.pack(...)
		for _, callback in snapshot do
			pcall(function()
				callback(table.unpack(args, 1, args.n))
				return true
			end)
		end
	end

	local function count(): number
		local n = 0
		for _ in callbacks do
			n += 1
		end
		return n
	end

	return { connect = connect, fire = fire, count = count }
end

return Signal
