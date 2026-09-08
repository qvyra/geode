--!strict

-- Remote events live in a GeodeRemotes folder under ReplicatedStorage. The server makes
-- them on first use and clients wait, so a game that never replicates has none

local Types = require("../Types")

local FOLDER = "GeodeRemotes"

local RealRemotes = {}

local function folderOn(replicatedStorage: Instance): Instance
	local folder = replicatedStorage:FindFirstChild(FOLDER)
	if folder == nil then
		local created = Instance.new("Folder")
		created.Name = FOLDER
		created.Parent = replicatedStorage
		folder = created
	end
	return folder :: Instance
end

--[=[
	The server's end of the remote called `name`, created if it doesn't exist yet
]=]
function RealRemotes.server(
	replicatedStorage: Instance,
	playersService: Players,
	name: string
): Types.ServerRemote
	local folder = folderOn(replicatedStorage)
	local event = folder:FindFirstChild(name) :: RemoteEvent?
	if event == nil then
		local created = Instance.new("RemoteEvent")
		created.Name = name
		created.Parent = folder
		event = created
	end
	local remote = event :: RemoteEvent
	return {
		fire = function(_self: Types.ServerRemote, userId: number, ...: any)
			local player = playersService:GetPlayerByUserId(userId)
			if player then
				remote:FireClient(player, ...)
			end
		end,
		onEvent = function(_self: Types.ServerRemote, handler: (userId: number, ...any) -> ())
			local connection = remote.OnServerEvent:Connect(function(player: Player, ...: any)
				handler(player.UserId, ...)
			end)
			return {
				disconnect = function(_connection: Types.Connection)
					connection:Disconnect()
				end,
			}
		end,
	}
end

--[=[
	The client's end of the remote called `name`. Yields until the server creates it
]=]
function RealRemotes.client(replicatedStorage: Instance, name: string): Types.ClientRemote
	local remote = replicatedStorage:WaitForChild(FOLDER):WaitForChild(name) :: RemoteEvent
	return {
		fire = function(_self: Types.ClientRemote, ...: any)
			remote:FireServer(...)
		end,
		onEvent = function(_self: Types.ClientRemote, handler: (...any) -> ())
			local connection = remote.OnClientEvent:Connect(handler)
			return {
				disconnect = function(_connection: Types.Connection)
					connection:Disconnect()
				end,
			}
		end,
	}
end

return RealRemotes
