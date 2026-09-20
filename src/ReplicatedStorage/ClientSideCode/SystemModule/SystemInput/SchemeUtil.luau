--[[
	Module: SystemInput.SchemeUtil
	Description: PreferredInput / UserInputType → SystemInput Scheme 映射
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-08-27
]]

local Constants = require(script.Parent.Constants)

local SchemeUtil = {}

--[[
	由 PreferredInput 推断活跃 Scheme
	@param preferred Enum.PreferredInput - UIS.PreferredInput
	@return string - KeyboardMouse / Gamepad / Touch
]]
function SchemeUtil.FromPreferredInput(preferred: Enum.PreferredInput): string
	if preferred == Enum.PreferredInput.Touch then
		return Constants.Scheme.Touch
	end
	if preferred == Enum.PreferredInput.Gamepad then
		return Constants.Scheme.Gamepad
	end
	return Constants.Scheme.KeyboardMouse
end

--[[
	由本次 InputObject 推断 Scheme（用于按键解析前同步活跃设备）
	@param input InputObject - UIS 输入对象
	@return string - KeyboardMouse / Gamepad / Touch
]]
function SchemeUtil.FromInputObject(input: InputObject): string
	local inputType = input.UserInputType
	if inputType == Enum.UserInputType.Touch then
		return Constants.Scheme.Touch
	end
	local name = inputType.Name
	if string.sub(name, 1, 7) == "Gamepad" then
		return Constants.Scheme.Gamepad
	end
	return Constants.Scheme.KeyboardMouse
end

--[[
	是否为合法 Scheme 名
	@param scheme string - 候选
	@return boolean - 合法为 true
]]
function SchemeUtil.IsValid(scheme: string): boolean
	return scheme == Constants.Scheme.KeyboardMouse
		or scheme == Constants.Scheme.Gamepad
		or scheme == Constants.Scheme.Touch
end

return SchemeUtil
