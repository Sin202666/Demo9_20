--[[
	Module: ScreenHost
	Description: 无 EmitParent 的 ImageLabel 发射器用的惰性单例 ScreenGui
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- get：首次创建并挂到 GuiHost 容器；已存在且仍有 Parent 则复用
	- destroy：销毁单例（pcall Destroy）
	- exists：是否仍挂在树上

	模块关系：
	- 宿主解析走 GuiHost.resolveContainer；服务端 host=nil 时 get 返回 nil，调用方跳过
	- ImageEmit 在无 EmitParent 时把 ImageLabel 挂到本 ScreenGui
	- DisplayOrder=-10，低于默认插件 UI（0）

	加载方式：
		local ScreenHost = require(script.Parent.ScreenHost)

	使用示例：
		local gui = ScreenHost.get()
		if gui then label.Parent = gui end
]]

local GuiHost = require(script.Parent.GuiHost)

local ScreenHost = {}
local _gui = nil

--[[
	取得（或惰性创建）PartIclesScreenHost 单例。

	@return ScreenGui? - 可用的 ScreenGui；服务端或 GuiHost 无容器时 nil
]]
function ScreenHost.get()
	if _gui and _gui.Parent then return _gui end
	local host = GuiHost.resolveContainer()
	if not host then return nil end  -- server context: caller skips
	_gui = Instance.new("ScreenGui")
	_gui.Name = "PartIclesScreenHost"
	_gui.Archivable = false
	_gui.DisplayOrder = -10 -- below plugin UI (default 0)
	_gui.ResetOnSpawn = false
	_gui.IgnoreGuiInset = true
	_gui.Parent = host
	return _gui
end

--[[
	销毁单例 ScreenGui 并清空缓存。已销毁或不存在时无操作。
]]
function ScreenHost.destroy()
	if _gui then pcall(_gui.Destroy, _gui); _gui = nil end
end

--[[
	查询单例是否仍挂在有效父级下。

	@return boolean - true 表示 _gui 存在且 Parent 非 nil
]]
function ScreenHost.exists() return _gui and _gui.Parent ~= nil end

return ScreenHost
