--[[
	Module: DebugManager
	Description: 客户端调试编排，绑定 DebugSystem UI 回调并通过 NetWork 发 Remote
	Author: 林奥宇
	Created: 2026-01-29
	Last Modified: 2026-09-22

	功能：
	- Dev / Studio 环境下加载调试 UI（DebugSystem）
	- 背包增删清、记录修改、数据初始化等操作发 Remote 至服务端
	- 短视频启用时注册「短视频界面」按钮，开关 2D 播放界面
	- 自动战斗启用时注册「自动战斗」/「中止自动战斗」按钮

	与相关模块：
	- DebugSystem：UI 与输入；本 Manager 只绑回调、发 Remote
	- 服务端同名 Manager：校验后路由 SystemBag / SystemRecord / SystemDataStore
	- ShortVideoFeature：可选，配置「短视频.启用」不为 false 时注册按钮

	端侧约束：
	- Official 非 Studio 客户端直接 return，不加载 DebugSystem
	- 动态按钮 Name / Param 名为翻译键字面量（与 LocalizationTable 对齐）
	- 绑回调与 AddButton 之后调用 DebugSystem.CreateUI（UI 不再在 require 时自建）
	- msgType / 特殊操作名与 EnumMgr.DebugBagOp / DebugSpecialOp 对齐

	加载：StarterPlayerScripts 启动脚本，无需 require / Init()

	依赖：ReplicatedStorage.ClientSideCode.GuiScripts.ModuleScript.DebugSystem
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local WorldUtil = Utils.WorldUtil
local RunService = Utils.RunService
local SystemGameConfig = Utils.SystemGameConfig
local ReplicatedStorage = Utils.ReplicatedStorage
local EnumMgr = Utils.EnumMgr
local Log = Utils.Log

local SERVER_TYPE_DEV = "Dev"
local SHORT_VIDEO_WAIT_SEC = 10

if WorldUtil.GetServerType() ~= SERVER_TYPE_DEV and not RunService:IsStudio() then
	return
end

-- ============================================================================
-- 模块引用（仅 Dev / Studio）
-- ============================================================================

local guiScripts = ReplicatedStorage.ClientSideCode.GuiScripts.ModuleScript
local DebugSystem = require(guiScripts.DebugSystem)

-- ============================================================================
-- 动态按钮
-- ============================================================================

local COVER_RECORD_OP = EnumMgr.DebugSpecialOp.CoverRecord
local ADD_ONLINE_SECONDS_OP = EnumMgr.DebugSpecialOp.AddOnlineSeconds
local RESET_ONLINE_AWARD_OP = EnumMgr.DebugSpecialOp.ResetOnlineAward

local InitButtonVt = {
	{
		{ Name = "修改记录", Param1Name = "记录名称", Param2Name = "修改值" },
		function()
			NetWork.FireServer(NetMsg.DEBUG_SPECIAL, COVER_RECORD_OP, {
				DebugSystem.GetButtonParam1("修改记录"),
				DebugSystem.GetButtonParam2("修改记录"),
			})
		end,
	},
	{
		{ Name = "增加在线时长", Param1Name = "秒数" },
		function()
			NetWork.FireServer(NetMsg.DEBUG_SPECIAL, ADD_ONLINE_SECONDS_OP, {
				DebugSystem.GetButtonParam1("增加在线时长"),
			})
		end,
	},
	{
		{ Name = "重置在线奖励" },
		function()
			NetWork.FireServer(NetMsg.DEBUG_SPECIAL, RESET_ONLINE_AWARD_OP, {})
		end,
	},
	{
		{ Name = "初始化角色数据" },
		function()
			NetWork.FireServer(NetMsg.DEBUG_RESET)
		end,
	},
}

if SystemGameConfig.GetValue({ "自动战斗", "启用" }) ~= false then
	local SystemAutoBattle = Utils.SystemAutoBattle
	table.insert(InitButtonVt, {
		{ Name = "自动战斗" },
		function()
			SystemAutoBattle.RequestStart()
		end,
	})
	table.insert(InitButtonVt, {
		{ Name = "中止自动战斗" },
		function()
			SystemAutoBattle.RequestAbort()
		end,
	})
end

if SystemGameConfig.GetValue({ "短视频", "启用" }) ~= false then
	local shortVideoFolder = ReplicatedStorage:FindFirstChild("ShortVideoFeature")
	if not shortVideoFolder then
		shortVideoFolder = ReplicatedStorage:WaitForChild("ShortVideoFeature", SHORT_VIDEO_WAIT_SEC)
	end
	if shortVideoFolder then
		local ShortVideoFeature = require(shortVideoFolder)
		table.insert(InitButtonVt, {
			{ Name = "短视频界面" },
			function()
				if ShortVideoFeature.IsOpen() then
					ShortVideoFeature.Close("debug")
				else
					ShortVideoFeature.Open({
						displayMode = "screen",
						lockCharacter = false,
						exitOnCameraDisturb = false,
					})
				end
			end,
		})
	else
		Log.warn("DebugManager: ShortVideoFeature 未找到，跳过短视频调试按钮")
	end
end

-- ============================================================================
-- 背包按钮回调
-- ============================================================================

DebugSystem.OnAddClick(function()
	local msgData = {
		msgType = EnumMgr.DebugBagOp.Add,
		itemID = tonumber(DebugSystem.GetID()),
		itemCount = tonumber(DebugSystem.GetAmount()),
	}
	NetWork.FireServer(NetMsg.DEBUG_BAG, msgData)
end)

DebugSystem.OnReduceClick(function()
	local msgData = {
		msgType = EnumMgr.DebugBagOp.Remove,
		itemID = tonumber(DebugSystem.GetID()),
		itemCount = tonumber(DebugSystem.GetAmount()),
	}
	NetWork.FireServer(NetMsg.DEBUG_BAG, msgData)
end)

DebugSystem.OnClearClick(function()
	local msgData = {
		msgType = EnumMgr.DebugBagOp.Clear,
		itemID = tonumber(DebugSystem.GetID()),
	}
	NetWork.FireServer(NetMsg.DEBUG_BAG, msgData)
end)

for _, funcInfo in ipairs(InitButtonVt) do
	DebugSystem.AddButton(funcInfo[1], funcInfo[2])
end
DebugSystem.CreateUI()
