--[[
	Module: RedPoint.client
	Description: 监听 CollectionService Tag「RedPoint」的 UI 组件，按 Attribute「RedPoint」业务键显隐红点
	Author: 林奥宇
	Created: 2026-09-04
	Last Modified: 2026-09-04

	功能：
	- Tag = RedPoint；Attribute RedPoint 标识业务，如「在线奖励」
	- 在线奖励：只读服务端镜像 NumberValue「在线奖励红点」（Value>0）；GameConfig「在线奖励.启用」= false 时恒隐藏
	- 支持实例动态增删与 Attribute 变更；未知业务键保持隐藏
	- 显示时播放 UIanima.RedPointAnim 旋转提醒动画；隐藏时停止并回正

	约定：
	- 目标实例为 GuiObject 时直接改 Visible；否则改其全部 GuiObject 后代
	- 扩展新业务：在 RED_POINT_KEY 增加常量，并实现 _evaluators 对应项

	示例（Studio）：
	- ImageLabel 打 Tag RedPoint，Attribute RedPoint = "在线奖励"
]]

local CollectionService = game:GetService("CollectionService")

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local GetData = Utils.GetData
local LocalPlayer = Utils.LocalPlayer
local UIanima = Utils.UIanima
local SystemGameConfig = Utils.SystemGameConfig

local TAG_RED_POINT = "RedPoint"
local ATTR_RED_POINT = "RedPoint"

local RED_POINT_KEY_ONLINE = "在线奖励"
local SERVER_RED_POINT_ONLINE = "在线奖励红点"

local _onlineRedValue: NumberValue = GetData.WaitRedPointValue(LocalPlayer, SERVER_RED_POINT_ONLINE)

local _trackedKeyByInstance: { [Instance]: string } = {}
local _instancesByKey: { [string]: { [Instance]: boolean } } = {}
local _instanceConns: { [Instance]: { RBXScriptConnection } } = {}

--[[
	在线奖励红点：功能开启且只读服务端 NumberValue>0
	@return boolean - 可显示为 true
]]
local function _canShowOnlineAwardRedPoint(): boolean
	if SystemGameConfig.GetValue({ "在线奖励", "启用" }) == false then
		return false
	end
	return _onlineRedValue.Value > 0
end

local _evaluators: { [string]: () -> boolean } = {
	[RED_POINT_KEY_ONLINE] = _canShowOnlineAwardRedPoint,
}

--[[
	设置单个 GuiObject 可见性并播放/停止红点动画
	@param gui GuiObject - 目标
	@param visible boolean - 是否显示
	@return nil
]]
local function _applyGuiVisible(gui: GuiObject, visible: boolean)
	local wasVisible = gui.Visible
	gui.Visible = visible
	if visible and not wasVisible then
		UIanima.RedPointAnim(gui)
	elseif not visible and wasVisible then
		UIanima.StopRedPointAnim(gui)
	end
end

--[[
	设置实例及其 Gui 后代的可见性
	@param instance Instance - 打点实例
	@param visible boolean - 是否显示
	@return nil
]]
local function _setInstanceVisible(instance: Instance, visible: boolean)
	if instance:IsA("GuiObject") then
		_applyGuiVisible(instance, visible)
		return
	end
	for _, desc in instance:GetDescendants() do
		if desc:IsA("GuiObject") then
			_applyGuiVisible(desc, visible)
		end
	end
end

--[[
	按业务键刷新已跟踪实例
	@param key string - Attribute 业务键
	@return nil
]]
local function _refreshKey(key: string)
	local evaluator = _evaluators[key]
	local visible = if evaluator then evaluator() else false
	local set = _instancesByKey[key]
	if not set then
		return
	end
	for inst in set do
		_setInstanceVisible(inst, visible)
	end
end

--[[
	取消跟踪实例并断开连接
	@param instance Instance - 打点实例
	@return nil
]]
local function _untrack(instance: Instance)
	local oldKey = _trackedKeyByInstance[instance]
	if oldKey then
		local set = _instancesByKey[oldKey]
		if set then
			set[instance] = nil
		end
		_trackedKeyByInstance[instance] = nil
	end
	local conns = _instanceConns[instance]
	if conns then
		for _, conn in conns do
			conn:Disconnect()
		end
		_instanceConns[instance] = nil
	end
end

--[[
	跟踪实例并立即按当前键刷新
	@param instance Instance - 打点实例
	@return nil
]]
local function _track(instance: Instance)
	_untrack(instance)
	local key = instance:GetAttribute(ATTR_RED_POINT)
	if type(key) ~= "string" or key == "" then
		_setInstanceVisible(instance, false)
		return
	end
	_trackedKeyByInstance[instance] = key
	local set = _instancesByKey[key]
	if not set then
		set = {}
		_instancesByKey[key] = set
	end
	set[instance] = true
	_instanceConns[instance] = {
		instance:GetAttributeChangedSignal(ATTR_RED_POINT):Connect(function()
			_track(instance)
		end),
	}
	_refreshKey(key)
end

_onlineRedValue.Changed:Connect(function()
	_refreshKey(RED_POINT_KEY_ONLINE)
end)

CollectionService:GetInstanceAddedSignal(TAG_RED_POINT):Connect(_track)
CollectionService:GetInstanceRemovedSignal(TAG_RED_POINT):Connect(function(instance: Instance)
	_untrack(instance)
end)

for _, inst in CollectionService:GetTagged(TAG_RED_POINT) do
	_track(inst)
end
