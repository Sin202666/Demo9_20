--[[
	Module: CharacterTouch
	Description: 角色触摸交互；根据场景部件 Attribute 触发本地 UI 开关
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31

	功能：
	- touchNode Attribute `openUI`：进入区域打开 UI，离开且不再接触时关闭
	- 通过 NetMsg.SHOW_LOCAL_UI Bindable 通知 UIManager（本脚本不读写 PlayerGui）

	部件 Attribute：
	- openUI string - UI 名称（非 string 或空串则忽略）
	- openUIData any? - 传给 UI 的附加数据

	与相关模块：
	- 显隐只经 UIManager；本脚本维护触摸打开集合，避免跨层读 ScreenGui.Visible

	加载方式：
	角色生成时由引擎启动；无需业务侧 require。
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local LocalPlayer = Utils.LocalPlayer
local InsMgr = Utils.InsMgr
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork

local Character: Model = script.Parent.Parent
local HumanoidRootPart: Part = Character:WaitForChild("HumanoidRootPart") :: Part

-- ========================================
-- 常量
-- ========================================
local OPEN_UI_VALUE_NAME = "openUI"
local OPEN_UI_ATTR = "openUI"
local OPEN_UI_DATA_ATTR = "openUIData"

-- ========================================
-- 私有变量
-- ========================================
local _openedByTouch: { [string]: boolean } = {}
local _overlapParams = OverlapParams.new()
_overlapParams.FilterType = Enum.RaycastFilterType.Include

local _touchedConn: RBXScriptConnection? = nil
local _touchEndedConn: RBXScriptConnection? = nil
local _ancestryConn: RBXScriptConnection? = nil

-- ========================================
-- 私有函数
-- ========================================

--[[
	检查两个部件是否仍在接触

	@param part1 BasePart - 触发区域部件
	@param part2 BasePart - 角色 HumanoidRootPart
	@return boolean - 是否仍在接触
]]
local function _isStillTouch(part1: BasePart, part2: BasePart): boolean
	_overlapParams.FilterDescendantsInstances = { part2 }
	local touchParts = workspace:GetPartsInPart(part1, _overlapParams)
	for _, part in touchParts do
		if part == part2 then
			return true
		end
	end

	-- GetPartsInPart 可能受 CanQuery 影响；GetTouchingParts 作碰撞回退
	touchParts = part1:GetTouchingParts()
	for _, part in touchParts do
		if part == part2 then
			return true
		end
	end

	return false
end

--[[
	从部件读取 openUI 名称

	@param touchNode BasePart - 被触摸部件
	@return string? - 合法 UI 名；缺失或非 string 时为 nil
]]
local function _readOpenUiName(touchNode: BasePart): string?
	local uiName = touchNode:GetAttribute(OPEN_UI_ATTR)
	if type(uiName) ~= "string" or uiName == "" then
		return nil
	end
	return uiName
end

--[[
	角色离树时断开触摸连接并清空触摸打开集合
]]
local function _cleanup()
	if _touchedConn then
		_touchedConn:Disconnect()
		_touchedConn = nil
	end
	if _touchEndedConn then
		_touchEndedConn:Disconnect()
		_touchEndedConn = nil
	end
	if _ancestryConn then
		_ancestryConn:Disconnect()
		_ancestryConn = nil
	end
	table.clear(_openedByTouch)
end

-- ========================================
-- 事件绑定
-- ========================================
_touchedConn = HumanoidRootPart.Touched:Connect(function(touchNode: BasePart)
	if not touchNode then
		return
	end

	local uiName = _readOpenUiName(touchNode)
	if not uiName then
		return
	end

	if _openedByTouch[uiName] then
		return
	end

	local openUIData = touchNode:GetAttribute(OPEN_UI_DATA_ATTR)
	_openedByTouch[uiName] = true

	local openUIValue: StringValue = InsMgr.GetIns(OPEN_UI_VALUE_NAME, "StringValue", LocalPlayer) :: StringValue
	openUIValue.Value = uiName

	NetWork.FireBindable(NetMsg.SHOW_LOCAL_UI, uiName, openUIData, true)
end)

_touchEndedConn = HumanoidRootPart.TouchEnded:Connect(function(touchNode: BasePart)
	if not touchNode then
		return
	end

	if _isStillTouch(touchNode, HumanoidRootPart) then
		return
	end

	local uiName = _readOpenUiName(touchNode)
	if not uiName then
		return
	end

	if not _openedByTouch[uiName] then
		return
	end
	_openedByTouch[uiName] = nil

	local openUIValue: StringValue = InsMgr.GetIns(OPEN_UI_VALUE_NAME, "StringValue", LocalPlayer) :: StringValue
	openUIValue.Value = ""

	NetWork.FireBindable(NetMsg.SHOW_LOCAL_UI, uiName, nil, false)
end)

_ancestryConn = Character.AncestryChanged:Connect(function(_child: Instance, parent: Instance?)
	if parent == nil then
		_cleanup()
	end
end)
