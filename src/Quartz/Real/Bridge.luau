--!strict

-- Tooling bridge in a Studio playtest: a GeodeVein folder in ServerStorage with a Request
-- BindableFunction and a Telemetry BindableEvent, where plugins in the server DataModel find
-- it. Never created outside Studio

local Types = require("../Types")

local FOLDER = "GeodeVein"

local RealBridge = {}

function RealBridge.new(serverStorage: Instance, runService: RunService): Types.ToolingBridge
	return {
		isAvailable = function(_self: Types.ToolingBridge): boolean
			return runService:IsStudio() and runService:IsServer()
		end,
		open = function(
			_self: Types.ToolingBridge,
			attributes: { [string]: string | number },
			handler: Types.BridgeHandler
		): Types.BridgeConnection
			local existing = serverStorage:FindFirstChild(FOLDER)
			if existing then
				existing:Destroy()
			end
			local folder = Instance.new("Folder")
			folder.Name = FOLDER
			for name, value in attributes do
				folder:SetAttribute(name, value)
			end
			local request = Instance.new("BindableFunction")
			request.Name = "Request"
			request.OnInvoke = handler
			request.Parent = folder
			local telemetry = Instance.new("BindableEvent")
			telemetry.Name = "Telemetry"
			telemetry.Parent = folder
			folder.Parent = serverStorage
			return {
				publish = function(_connection: Types.BridgeConnection, message: unknown)
					telemetry:Fire(message)
				end,
				close = function(_connection: Types.BridgeConnection)
					folder:Destroy()
				end,
			}
		end,
	}
end

return RealBridge
