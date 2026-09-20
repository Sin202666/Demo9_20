--[[
	Module: SystemBagToolbar-Type
	Description: SystemBagToolbar 类型声明（实现见 ServerSideCode/System/SystemBagToolbar.luau）
	Author: 林奥宇
	Created: 2026-09-04
	Last Modified: 2026-09-04
]]

local SystemBagToolbar = {}

export type BackpackDragZone = {
	zone: string,
	equipSlot: number?,
	onlyID: number?,
}

--[[
	背包 UI 开关（GameConfig「背包UI.启用」；缺键视为开）
	@return boolean - true 表示启用
]]
function SystemBagToolbar.IsEnabled(): boolean
end

--[[
	处理拖拽落点（栏内互换 / 卸下 / 装备）
	@param plr Player - 玩家对象
	@param from BackpackDragZone - 起点
	@param to BackpackDragZone - 落点
	@return boolean - 成功 true
	@return string? - 失败为 INVALID_PARAM / NOT_FOUND / SetEquip 错误码
]]
function SystemBagToolbar.ApplyBackpackDrag(plr: Player, from: BackpackDragZone, to: BackpackDragZone): (boolean, string?)
end

--[[
	启动注册拖拽 Remote 与限频（幂等；PlayerManager 调用；关闭时不注册）
	@return nil - 无返回值
]]
function SystemBagToolbar.Init(): ()
end

--[[
	兼容旧调用：转发 Init
	@return nil - 无返回值
]]
function SystemBagToolbar.RegisterNetWork(): ()
end

return SystemBagToolbar
