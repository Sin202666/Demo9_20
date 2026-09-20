--[[
	Module: DeviceType-Type
	Description: DeviceType 类型声明（完整使用说明见 ToolSystem/DeviceType.luau 文件头）
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-01
]]

local DeviceType = {}

--[[
	检测当前是否为移动设备（手机/平板）
	返回模块加载时缓存的标志，不随 PreferredInput 热切换更新
	@return boolean - 移动设备为 true，否则 false
]]
function DeviceType.IsMobile(): boolean
end

--[[
	检测当前是否为 PC 设备（键鼠为主）
	返回模块加载时缓存的标志；首选手柄时为 false
	@return boolean - PC 设备为 true，否则 false
]]
function DeviceType.IsPc(): boolean
end

--[[
	检测当前是否启用手柄输入
	每次实时读取 GamepadEnabled，可反映热插拔
	@return boolean - 已启用手柄输入为 true，否则 false
]]
function DeviceType.IsGamepad(): boolean
end

--[[
	IsGamepad 的历史别名（RP17 / 技能系统）
	新代码请调用 IsGamepad()
	@return boolean - 已启用手柄输入为 true，否则 false
]]
function DeviceType.IsGamePad(): boolean
end

return DeviceType
