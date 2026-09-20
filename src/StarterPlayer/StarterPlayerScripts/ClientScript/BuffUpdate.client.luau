--[[
	Module: BuffUpdate
	Description: 客户端 BUFF 栏 UI 同步，读取 Player.BUFF 与 workspace 服务器 BUFF 镜像并刷新 Main.BUFF 显示
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31

	功能：
	- 每秒刷新玩家 BUFF 格子（buffdataConf.isShow == 1）
	- 601/602 免费/付费时间 BUFF 合并为单格显示
	- 同步 workspace.服务器BUFF 全服加成图标与倒计时

	依赖：
	- Player.BUFF NumberValue 树（SystemBUFF.UpdateBuffValue 写入，只读）
	- workspace.服务器BUFF（SystemServerBuff.Refresh 写入，只读）
	- AssetPaths.GetCatalog("BUFF") 模板：BUFF格子、服务器BUFF格子
	- TranslationHelper.SetRawText：倒计时 / 倍数为已拼好展示串，不参与查表

	约定：
	- 本文件为 StarterPlayerScripts LocalScript，启动即轮询；无 Init() / 模块表
	- 不写存档、不结算奖励、不改 BUFF 权威数据
	- UpdateModule.Register 仅服务端生效，本脚本用 task.spawn + task.wait 每秒刷新

	加载方式：
		本脚本由 StarterPlayer 自动运行，无需 require
]]

-- ========================================
-- 服务引用
-- ========================================
-- Workspace 未纳入 UtilsSystem，与仓内其它模块一致走 GetService
local Workspace = game:GetService("Workspace")

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local AssetPaths = Utils.AssetPaths
local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr
local LocalPlayer = Utils.LocalPlayer
local Log = Utils.Log
local MathMgr = Utils.MathMgr
local TimeTransfer = Utils.TimeTransfer
local TranslationHelper = Utils.TranslationHelper

-- ========================================
-- 常量
-- ========================================
local BUFF_CFG_NAME = "buffdataConf"
local BUFF_CATALOG_NAME = "BUFF"
local BUFF_FOLDER_NAME = EnumMgr.PlayerInst.BuffFolder
local SERVER_BUFF_FOLDER_NAME = "服务器BUFF"
local SERVER_BUFF_UI_PREFIX = "服务器"
local BUFF_ITEM_NAME = "BUFF格子"
local SERVER_BUFF_ITEM_NAME = "服务器BUFF格子"
local UPDATE_INTERVAL_SEC = 1
local INFINITY_SYMBOL = "∞"
local MULTIPLIER_PREFIX = "x"
local LUCKY_ADD_DIVISOR = 10
local OTHER_ADD_PERCENT = 0.01
local TIME_TEXT_NAME = "timeText"
local ICON_NAME = "Icon"
local MULTIPLIER_LABEL_NAME = "倍数"

local FREE_TIME_BUFF_ID = 601
local PAID_TIME_BUFF_ID = 602
local SPECIAL_BUFF_IDS: { [number]: boolean } = table.freeze({
	[FREE_TIME_BUFF_ID] = true,
	[PAID_TIME_BUFF_ID] = true,
})

local SERVER_BUFF_ICON_MAP: { [string]: string } = table.freeze({
	Power = "rbxassetid://13109835010",
	Gold = "rbxassetid://13109834493",
	Lucky = "rbxassetid://13109835110",
	DMG = "rbxassetid://13120983840",
})

-- ========================================
-- 私有变量
-- ========================================
local _playerGui: PlayerGui = LocalPlayer:WaitForChild("PlayerGui", math.huge) :: PlayerGui
local _screenGui: ScreenGui = _playerGui:WaitForChild("ScreenGui", math.huge) :: ScreenGui

local _buffCatalog: Folder? = AssetPaths.GetCatalog(BUFF_CATALOG_NAME)
if not _buffCatalog then
	Log.warn("[BuffUpdate] BUFF catalog not found")
	return
end

local _buffItemTemplate: Frame = _buffCatalog:WaitForChild(BUFF_ITEM_NAME, math.huge) :: Frame
local _serverBuffItemTemplate: Frame = _buffCatalog:WaitForChild(SERVER_BUFF_ITEM_NAME, math.huge) :: Frame

local _mainFrame: Frame = _screenGui:WaitForChild("Main", math.huge) :: Frame
local _buffFrame: Frame = _mainFrame:WaitForChild("BUFF", math.huge) :: Frame

local _buffdataConf = CfgFind.GetCfgByName(BUFF_CFG_NAME)
if not _buffdataConf then
	Log.warn("[BuffUpdate] buffdataConf 缺失")
	return
end

-- ========================================
-- 私有函数
-- ========================================

--[[
	设置单条玩家 BUFF 格子图标与剩余时间
	@param buffName string - BUFF ID 字符串，对应 NumberValue.Name
	@param lessTime number - 剩余秒数；-1 表示永久
	@return nil - 配置缺失或模板无效时静默 return
]]
local function _setBuffValue(buffName: string, lessTime: number)
	local existingItem: Instance? = _buffFrame:FindFirstChild(buffName)
	local buffItem: Frame? = nil

	if existingItem and existingItem:IsA("Frame") then
		buffItem = existingItem :: Frame
	else
		local buffID = tonumber(buffName)
		if not buffID then
			return
		end

		local cfg = _buffdataConf[buffID]
		if not cfg then
			return
		end

		local clonedItem = _buffItemTemplate:Clone()
		if not clonedItem:IsA("Frame") then
			return
		end

		buffItem = clonedItem :: Frame
		buffItem.Parent = _buffFrame
		buffItem.Name = buffName

		local icon: Instance? = buffItem:FindFirstChild(ICON_NAME)
		if icon and icon:IsA("ImageLabel") then
			icon.Image = "rbxassetid://" .. cfg.Icon
		end
	end

	if not buffItem then
		return
	end

	local timeText: Instance? = buffItem:FindFirstChild(TIME_TEXT_NAME)
	if timeText and timeText:IsA("TextLabel") then
		if lessTime >= 0 then
			TranslationHelper.SetRawText(timeText, TimeTransfer.FormatTime(lessTime))
		else
			TranslationHelper.SetRawText(timeText, INFINITY_SYMBOL)
		end
	end
end

--[[
	设置单条服务器 BUFF 格子图标、倍数与剩余时间
	@param buffName string - 服务器 BUFF 类型名（Power/Gold/Lucky/DMG）
	@param add number - 加成数值
	@param lessTime number - 剩余秒数
	@return nil - 未知类型或模板无效时静默 return
]]
local function _setServerBuffValue(buffName: string, add: number, lessTime: number)
	local serverBuffName = SERVER_BUFF_UI_PREFIX .. buffName .. add
	local existingItem: Instance? = _buffFrame:FindFirstChild(serverBuffName)
	local buffItem: Frame? = nil

	if existingItem and existingItem:IsA("Frame") then
		buffItem = existingItem :: Frame
	else
		local buffImg = SERVER_BUFF_ICON_MAP[buffName]
		if not buffImg then
			return
		end

		local clonedItem = _serverBuffItemTemplate:Clone()
		if not clonedItem:IsA("Frame") then
			return
		end

		buffItem = clonedItem :: Frame
		buffItem.Parent = _buffFrame
		buffItem.Name = serverBuffName

		local icon: Instance? = buffItem:FindFirstChild(ICON_NAME)
		if icon and icon:IsA("ImageLabel") then
			icon.Image = buffImg
		end

		local powerAdd: Instance? = buffItem:FindFirstChild(MULTIPLIER_LABEL_NAME)
		if powerAdd and powerAdd:IsA("TextLabel") then
			local multiplier = if buffName == "Lucky"
				then 1 + (add / LUCKY_ADD_DIVISOR)
				else 1 + (add * OTHER_ADD_PERCENT)
			TranslationHelper.SetRawText(powerAdd, MULTIPLIER_PREFIX .. MathMgr.getNumStr(multiplier))
		end
	end

	if not buffItem then
		return
	end

	local timeText: Instance? = buffItem:FindFirstChild(TIME_TEXT_NAME)
	if timeText and timeText:IsA("TextLabel") then
		TranslationHelper.SetRawText(timeText, TimeTransfer.FormatTime(lessTime))
	end
end

--[[
	移除 BUFF 栏中已无数据源的 UI 格子
	@param buffFolder Folder - player.BUFF 文件夹
	@return nil - 无返回值
]]
local function _cleanupRemovedBuffUi(buffFolder: Folder)
	local existingNames: { [string]: boolean } = {}
	local hasSpecial = false
	for _, buffValue in pairs(buffFolder:GetChildren()) do
		if buffValue:IsA("NumberValue") then
			existingNames[buffValue.Name] = true
			local buffID = tonumber(buffValue.Name)
			if buffID and SPECIAL_BUFF_IDS[buffID] then
				hasSpecial = true
			end
		end
	end

	for _, child in pairs(_buffFrame:GetChildren()) do
		if not child:IsA("Frame") then
			continue
		end

		local buffID = tonumber(child.Name)
		if not buffID then
			continue
		end

		local shouldRemove = existingNames[child.Name] ~= true
		if shouldRemove and SPECIAL_BUFF_IDS[buffID] and hasSpecial then
			shouldRemove = false
		end

		if shouldRemove then
			child:Destroy()
		end
	end
end

--[[
	同步玩家 BUFF 与服务器 BUFF 到 UI
	@param player Player - 本地玩家
	@return nil - 无返回值
]]
local function _updateBuff(player: Player)
	local buffFolder: Instance? = player:FindFirstChild(BUFF_FOLDER_NAME)
	if buffFolder and buffFolder:IsA("Folder") then
		local buffFolderTyped = buffFolder :: Folder
		local mergedSpecialTime = 0

		for _, buffValue in pairs(buffFolderTyped:GetChildren()) do
			if not buffValue:IsA("NumberValue") then
				continue
			end

			local buffID = tonumber(buffValue.Name)
			if not buffID then
				continue
			end

			local cfgBuff = _buffdataConf[buffID]
			if cfgBuff and cfgBuff.isShow == 1 then
				if SPECIAL_BUFF_IDS[buffID] then
					mergedSpecialTime = mergedSpecialTime + buffValue.Value
				else
					_setBuffValue(buffValue.Name, buffValue.Value)
				end
			end
		end

		if mergedSpecialTime > 0 then
			_setBuffValue(tostring(FREE_TIME_BUFF_ID), mergedSpecialTime)
		end

		_cleanupRemovedBuffUi(buffFolderTyped)
	end

	local serverBuffFolder: Instance? = Workspace:FindFirstChild(SERVER_BUFF_FOLDER_NAME)
	if not serverBuffFolder or not serverBuffFolder:IsA("Folder") then
		return
	end

	local serverTime = Workspace:GetServerTimeNow()
	for _, buffValue in pairs((serverBuffFolder :: Folder):GetChildren()) do
		if not buffValue:IsA("NumberValue") then
			continue
		end

		local numberValue = buffValue :: NumberValue
		local endTimeValue: Instance? = numberValue:FindFirstChild("EndTime")
		local startTimeValue: Instance? = numberValue:FindFirstChild("StartTime")
		if not endTimeValue or not endTimeValue:IsA("NumberValue") then
			continue
		end
		if not startTimeValue or not startTimeValue:IsA("NumberValue") then
			continue
		end

		local endTime = (endTimeValue :: NumberValue).Value
		local startTime = (startTimeValue :: NumberValue).Value
		if serverTime < startTime then
			continue
		end

		local lessTime = endTime - serverTime
		if lessTime > 0 then
			_setServerBuffValue(numberValue.Name, numberValue.Value, lessTime)
		else
			local serverBuffName = SERVER_BUFF_UI_PREFIX .. numberValue.Name .. numberValue.Value
			local expiredItem: Instance? = _buffFrame:FindFirstChild(serverBuffName)
			if expiredItem then
				expiredItem:Destroy()
			end
		end
	end
end

-- ========================================
-- 初始化
-- ========================================
_updateBuff(LocalPlayer)

task.spawn(function()
	while task.wait(UPDATE_INTERVAL_SEC) do
		_updateBuff(LocalPlayer)
	end
end)
