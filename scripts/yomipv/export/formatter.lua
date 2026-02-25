--[[ Template formatter                             ]]
--[[ Variable substitution and template processing. ]]

local Formatter = {}

-- Create new formatter instance
function Formatter.new(config)
	local obj = {
		config = config,
	}
	setmetatable(obj, Formatter)
	Formatter.__index = Formatter
	return obj
end

-- Substitute variables in template string
function Formatter.substitute(_, template, variables)
	if not template or template == "" then
		return ""
	end

	local result = template

	if variables then
		for key, value in pairs(variables) do
			local pattern1 = "%%{" .. key .. "}"
			local pattern2 = "{" .. key .. "}"
			result = result:gsub(pattern1, tostring(value))
			result = result:gsub(pattern2, tostring(value))
		end
	end

	return result
end

return Formatter
