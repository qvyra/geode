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
			local mine: { Instance } = {}
			local skipped: { Types.LeaderstatSkip } = {}
			local adopted: { string } = {}
			for _, stat in stats do
				local existing = if made then nil else folder:FindFirstChild(stat.name)
				if existing and existing.ClassName == stat.kind then
					-- the game's own value, written to but never destroyed
					values[stat.name] = existing
					table.insert(adopted, stat.name)
				elseif existing then
					table.insert(
						skipped,
						{ name = stat.name, kind = stat.kind, found = existing.ClassName }
					)
				else
					-- the kind is one of three class names, which Instance.new's overloads can't
					-- see
					local value: Instance = (Instance.new :: any)(stat.kind)
					value.Name = stat.name
					value.Parent = folder
					values[stat.name] = value
					table.insert(mine, value)
				end
			end
			-- a folder made here goes in once its values are there
			folder.Parent = owner
			return {
				skipped = skipped,
				adopted = adopted,
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
					for _, instance in mine do
						instance:Destroy()
					end
					-- the game may have put values of its own in the folder since
					if made and #folder:GetChildren() == 0 then
						folder:Destroy()
					end
					table.clear(values)
					table.clear(mine)
				end,
			}
		end,
	}
end

return RealLeaderstats
