--[[
	Module: LocoStyleSets-Type
	Description: Utils.LocoStyleSets 类型桩（IDE 补全）
]]

local module = {}

module.DEFAULT_STYLE_ID = "Default"
module.SLOT_ORDER = {} :: { string }

--[[
	@param styleId string - 风格 ID
	@return boolean
]]
function module.HasStyle(styleId: string): boolean
	return false
end

--[[
	@param styleId string - 风格 ID
	@param slot string - 槽名
	@return string?
]]
function module.ResolveAnimName(styleId: string, slot: string): string?
	return nil
end

--[[
	@param styleId string - 风格 ID
	@return { string }
]]
function module.ListAnimNamesForStyle(styleId: string): { string }
	return {}
end

--[[
	@return { [string]: string }
]]
function module.GetDefaultSlotAnims(): { [string]: string }
	return {}
end

return module