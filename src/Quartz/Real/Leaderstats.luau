--!strict

-- Leaderstats the way the player list reads them: a Folder named "leaderstats" under the
-- Player, holding IntValue, NumberValue and StringValue children

local Types = require("../Types")

local RealLeaderstats = {}

-- TODO(verify): the player list is taken to show the values in the order they're parented,
-- which is why attach parents them in the order it gets them. Roblox doesn't document it
function RealLeaderstats.new(): Types.Leaderstats
	return {
		attach = function(
			_self: Types.Leaderstats,
			player: unknown,
			stats: { Types.LeaderstatSpec }
		): Types.LeaderstatValues
			local owner = player :: Instance
			local found = owner:FindFirstChild("leaderstats")
			local made = found == nil
			local folder: Instance = if found then found else Instance.new("Folder")
			folder.Name = "leaderstats"
			local values: { [string]: Instance } = {}
			for _, stat in stats do
				-- the kind is one of three class names, which Instance.new's overloads can't see
				local value: Instance = (Instance.new :: any)(stat.kind)
				value.Name = stat.name
				value.Parent = folder
				values[stat.name] = value
			end
			-- a folder made here goes in once its values are there
			folder.Parent = owner
			return {
				set = function(
					_values: Types.LeaderstatValues,
					name: string,
					value: number | string
				)
					local instance = values[name]
					if instance then
						(instance :: any).Value = value
					end
				end,
				destroy = function(_values: Types.LeaderstatValues)
					if made then
						folder:Destroy()
					else
						for _, instance in values do
							instance:Destroy()
						end
					end
					table.clear(values)
				end,
			}
		end,
	}
end

return RealLeaderstats
