--[[
	Module: Backpack
	Description: 背包 UI 入口（Core 渲染 + Drag/Lock；常驻栏由 InitBackpack 薄启动）
	Author: 林奥宇
	Created: 2026-09-04
	Last Modified: 2026-09-04

	功能：
	- init(main)：转发 Core.init
	- 不写存档、不改 PlayerData

	加载：
		local Backpack = require(...GuiScripts.ModuleScript.Backpack)
		Backpack.init(main)
]]

local Core = require(script.Core)

local Backpack = {}

--[[
	初始化 Main.Backpack

	@param main Frame - ScreenGui.Main
	@return boolean - 成功为 true
]]
function Backpack.init(main: Frame): boolean
	return Core.init(main)
end

return Backpack
