--[[
	Module: SystemBUFF
	Description: 玩家 BUFF 增删、倒计时与 Player 实例镜像
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31

	功能：
	- AddBUFF：添加或叠加 BUFF（addTime 单位为分钟；负数表示永久）
	- UpdateBuff：每秒扣减限时 BUFF（由 UpdateModule 驱动）
	- UpdateBuffValue：将存档 buff 同步到 Player.BUFF 文件夹
	- Init：玩家入服时初始化 BUFF 实例镜像并缓存 Folder / 房间号 Value

	与 SystemServerBuff 区别：本模块管玩家个人 BUFF；SystemServerBuff 管 workspace 全局加成。

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SystemBUFF = Utils.SystemBUFF

	示例：
		SystemBUFF.AddBUFF(player, 101, 10)  -- 添加 10 分钟 BUFF 101
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Players = Utils.Players
local Log = Utils.Log
local PlayerData = Utils.PlayerData
local CfgFind = Utils.CfgFind
local UpdateModule = Utils.UpdateModule
local EnumMgr = Utils.EnumMgr

-- ========================================
-- 模块定义
-- ========================================
local SystemBUFF = {}

type BuffStackEntry = { xN: number, BuffTime: number }
type BuffEntry = number | BuffStackEntry
type BuffMap = { [string]: BuffEntry }

-- ========================================
-- 常量定义
-- ========================================
local BUFF_CFG_NAME = "buffdataConf"
local BUFF_STAT_KEY = "buff"
local BUFF_FOLDER_NAME = EnumMgr.PlayerInst.BuffFolder
local ROOM_ID_VALUE_NAME = EnumMgr.PlayerInst.RoomId

local FREE_TIME_BUFF_ID = 601
local PAID_TIME_BUFF_ID = 602

local ERROR_INVALID_PARAM = "INVALID_PARAM"
local ERROR_NO_DATA = "NO_DATA"
local ERROR_CFG_NOT_FOUND = "CFG_NOT_FOUND"
local ERROR_SAVE_FAILED = "SAVE_FAILED"

-- ========================================
-- 私有状态（入服缓存 Instance，离场清理）
-- ========================================
local _buffFolderByPlayer: { [Player]: Folder } = {}
local _roomIdByPlayer: { [Player]: NumberValue } = {}

-- ========================================
-- 私有函数
-- ========================================

--[[
	读取配表叠加上限；缺省或非数字视为不可叠加（1）。

	@param cfgBuff table - buffdataConf 行；读取 isOver
	@return number - 最大层数；<=1 表示不可叠加
]]
local function _getMaxStack(cfgBuff: any): number
	local maxLayer = tonumber(cfgBuff.isOver)
	if type(maxLayer) ~= "number" then
		return 1
	end
	return maxLayer
end

--[[
	离场时丢掉该玩家的 Folder / 房间号缓存。

	@param plr Player - 离开的玩家
]]
local function _clearPlayerCache(plr: Player)
	_buffFolderByPlayer[plr] = nil
	_roomIdByPlayer[plr] = nil
end

--[[
	取玩家「当前房间号」NumberValue（命中后缓存；未创建时不报错）。

	@param plr Player - 目标玩家
	@return NumberValue? - 已存在的房间号 Value；尚未创建则为 nil
]]
local function _getRoomIdValue(plr: Player): NumberValue?
	local cached = _roomIdByPlayer[plr]
	if cached and cached.Parent then
		return cached
	end
	local inst: Instance? = plr:FindFirstChild(ROOM_ID_VALUE_NAME)
	if inst and inst:IsA("NumberValue") then
		_roomIdByPlayer[plr] = inst
		return inst
	end
	_roomIdByPlayer[plr] = nil
	return nil
end

--[[
	检查玩家是否在副本战斗中

	@param plr Player - 目标玩家
	@return boolean - true 表示当前房间号非 0；无 Value 时视为不在战斗
]]
local function _isPlayerInFight(plr: Player): boolean
	local nowRoomID = _getRoomIdValue(plr)
	if nowRoomID then
		return nowRoomID.Value ~= 0
	end
	return false
end

--[[
	扣减单条 BUFF 剩余时间

	@param buffData BuffMap - 玩家 buff 存档表，键为 string BUFF ID，值为秒数或 { xN, BuffTime }
	@param buffID string - BUFF ID 字符串键
	@param dt number - 时间增量（秒）
	@return boolean - 是否发生了数值变更
]]
local function _updateBuffEntry(buffData: BuffMap, buffID: string, dt: number): boolean
	local buffValue = buffData[buffID]
	if type(buffValue) == "number" then
		if buffValue < 0 then
			return false
		end
		local lessTime = buffValue - dt
		buffData[buffID] = if lessTime <= 0 then 0 else lessTime
		return true
	end
	if type(buffValue) == "table" and type(buffValue.BuffTime) == "number" then
		if buffValue.BuffTime < 0 then
			return false
		end
		local lessTime = buffValue.BuffTime - dt
		buffValue.BuffTime = if lessTime <= 0 then 0 else lessTime
		return true
	end
	return false
end

--[[
	获取或创建玩家的 BUFF 文件夹（命中后缓存）。

	@param plr Player - 目标玩家
	@return Folder - Player 下名为 EnumMgr.PlayerInst.BuffFolder 的 Folder
]]
local function _getBuffFolder(plr: Player): Folder
	local cached = _buffFolderByPlayer[plr]
	if cached and cached.Parent then
		return cached
	end

	local buffFolder: Instance? = plr:FindFirstChild(BUFF_FOLDER_NAME)
	if not buffFolder or not buffFolder:IsA("Folder") then
		local newFolder = Instance.new("Folder")
		newFolder.Name = BUFF_FOLDER_NAME
		newFolder.Parent = plr
		_buffFolderByPlayer[plr] = newFolder
		return newFolder
	end
	_buffFolderByPlayer[plr] = buffFolder
	return buffFolder
end

--[[
	将单条 BUFF 写入 Player 实例镜像

	@param plr Player - 目标玩家
	@param valueName string - BUFF ID 字符串，对应 NumberValue.Name
	@param valueData BuffEntry - 数字剩余秒数，或 { xN: number, BuffTime: number } 可叠加结构
	@return NumberValue - 写入后的 NumberValue 实例
]]
local function _setBuffValue(plr: Player, valueName: string, valueData: BuffEntry): NumberValue
	local buffFolder: Folder = _getBuffFolder(plr)
	local buffValue: Instance? = buffFolder:FindFirstChild(valueName)

	if not buffValue or not buffValue:IsA("NumberValue") then
		local newValue = Instance.new("NumberValue")
		newValue.Name = valueName
		newValue.Parent = buffFolder
		buffValue = newValue
	end

	local numberValue = buffValue :: NumberValue
	if type(valueData) == "number" then
		numberValue.Value = valueData
	elseif type(valueData) == "table" and valueData.BuffTime then
		numberValue.Value = valueData.BuffTime
	end

	return numberValue
end

--[[
	清理已到期 BUFF 条目

	@param buffData BuffMap - 玩家 buff 存档表，键为 string BUFF ID
	@return boolean - 是否删除了至少一条
]]
local function _removeExpiredBuffs(buffData: BuffMap): boolean
	local isChange = false
	for buffID, buffValue in pairs(buffData) do
		if type(buffValue) == "number" and buffValue == 0 then
			buffData[buffID] = nil
			isChange = true
		elseif type(buffValue) == "table" and buffValue.BuffTime == 0 then
			buffData[buffID] = nil
			isChange = true
		end
	end
	return isChange
end

--[[
	读取玩家 buff 存档表（经 GetPlrDataByKey；内部仍会拷贝会话快照）。

	@param plr Player - 目标玩家
	@return BuffMap? - buff 表；未加载或字段不是 table 时为 nil
]]
local function _getBuffData(plr: Player): BuffMap?
	local buffData = PlayerData.GetPlrDataByKey(plr, BUFF_STAT_KEY)
	if type(buffData) ~= "table" then
		return nil
	end
	return buffData :: BuffMap
end

--[[
	把 buff 表写回存档；失败只打日志。

	@param plr Player - 目标玩家
	@param buffData BuffMap - 已修改的 buff 表（副本）
	@param context string - 日志上下文（AddBUFF / UpdateBuff）
	@return boolean, string? - 成功 true；失败 false 与 ChangeStat errorCode
]]
local function _saveBuffData(plr: Player, buffData: BuffMap, context: string): (boolean, string?)
	local saveOk, saveErr = PlayerData.ChangePlrData(plr, BUFF_STAT_KEY, buffData)
	if saveOk then
		return true
	end
	Log.warn("SystemBUFF 写入 buff 失败", context, plr.UserId, saveErr)
	return false, saveErr or ERROR_SAVE_FAILED
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	更新所有在线玩家的 BUFF 倒计时

	@param dt number - 时间增量（秒），由 UpdateModule 传入
	@return nil
]]
function SystemBUFF.UpdateBuff(dt: number)
	for _, plr in Players:GetPlayers() do
		local isInFight = _isPlayerInFight(plr)

		local buffData = _getBuffData(plr)
		if not buffData then
			continue
		end

		local isChange = false

		for buffID, _ in pairs(buffData) do
			if buffID ~= tostring(FREE_TIME_BUFF_ID) and buffID ~= tostring(PAID_TIME_BUFF_ID) then
				if _updateBuffEntry(buffData, buffID, dt) then
					isChange = true
				end
			end
		end

		-- 战斗中优先消耗免费时间，再消耗付费时间
		if isInFight then
			local freeTimeBuffID = tostring(FREE_TIME_BUFF_ID)
			local paidTimeBuffID = tostring(PAID_TIME_BUFF_ID)

			local freeTime = buffData[freeTimeBuffID]
			if freeTime and tonumber(freeTime) and tonumber(freeTime) > 0 then
				if _updateBuffEntry(buffData, freeTimeBuffID, dt) then
					isChange = true
				end
			else
				local paidTime = buffData[paidTimeBuffID]
				if paidTime and tonumber(paidTime) and tonumber(paidTime) > 0 then
					if _updateBuffEntry(buffData, paidTimeBuffID, dt) then
						isChange = true
					end
				end
			end
		end

		if _removeExpiredBuffs(buffData) then
			isChange = true
		end

		if isChange then
			local saveOk = _saveBuffData(plr, buffData, "UpdateBuff")
			if saveOk then
				SystemBUFF.UpdateBuffValue(plr)
			end
		end
	end
end

--[[
	添加或叠加 BUFF

	@param plr Player - 目标玩家；须在线且已加载存档
	@param buffID string | number - buffdataConf 配置 ID
	@param addTime number - 添加时长（分钟）；内部 ×60 转秒；负数表示永久
	@return boolean, string? - 成功 true；失败 false 与 UPPER_SNAKE errorCode
]]
function SystemBUFF.AddBUFF(plr: Player, buffID: string | number, addTime: number): (boolean, string?)
	local addTimeSeconds = tonumber(addTime)
	if not addTimeSeconds then
		return false, ERROR_INVALID_PARAM
	end
	addTimeSeconds = addTimeSeconds * 60

	buffID = tostring(buffID)

	local buffData = _getBuffData(plr)
	if not buffData then
		return false, ERROR_NO_DATA
	end

	local numBuffID = tonumber(buffID)
	if not numBuffID then
		return false, ERROR_INVALID_PARAM
	end

	local cfgBuff = CfgFind.GetCfgByNameAndID(BUFF_CFG_NAME, numBuffID)
	if not cfgBuff then
		return false, ERROR_CFG_NOT_FOUND
	end

	local maxStack = _getMaxStack(cfgBuff)
	local thisBuff = buffData[buffID]

	if not thisBuff then
		if maxStack > 1 then
			buffData[buffID] = {
				xN = 1,
				BuffTime = addTimeSeconds,
			}
		else
			buffData[buffID] = addTimeSeconds
		end
	else
		if maxStack > 1 then
			if type(thisBuff) == "table" and thisBuff.xN then
				local currentLayer = thisBuff.xN
				local newLayer = math.min(currentLayer + 1, maxStack)

				buffData[buffID] = {
					xN = newLayer,
					BuffTime = addTimeSeconds,
				}
			else
				return false, ERROR_INVALID_PARAM
			end
		else
			if addTimeSeconds < 0 then
				buffData[buffID] = -1
			elseif type(thisBuff) == "number" then
				buffData[buffID] = thisBuff + addTimeSeconds
			else
				return false, ERROR_INVALID_PARAM
			end
		end
	end

	local saveOk, saveErr = _saveBuffData(plr, buffData, "AddBUFF")
	if not saveOk then
		return false, saveErr
	end
	SystemBUFF.UpdateBuffValue(plr)

	return true
end

--[[
	将存档 buff 同步到 Player.BUFF 实例树

	@param plr Player - 目标玩家
	@return nil - 无存档或 buff 字段缺失时提前返回
]]
function SystemBUFF.UpdateBuffValue(plr: Player)
	local buffData = _getBuffData(plr)
	if not buffData then
		return
	end

	for buffID, buffValue in pairs(buffData) do
		_setBuffValue(plr, buffID, buffValue)
	end

	local buffFolder: Folder = _getBuffFolder(plr)
	for _, child in pairs(buffFolder:GetChildren()) do
		if child:IsA("NumberValue") and not buffData[child.Name] then
			child:Destroy()
		end
	end
end

--[[
	玩家入服时初始化 BUFF 实例镜像并尝试缓存房间号 Value。

	@param plr Player - 目标玩家
	@return nil
]]
function SystemBUFF.Init(plr: Player)
	SystemBUFF.UpdateBuffValue(plr)
	_getRoomIdValue(plr)
end

-- ========================================
-- 定时任务与离场清理
-- ========================================
Players.PlayerRemoving:Connect(function(plr: Player)
	_clearPlayerCache(plr)
end)

UpdateModule.Register(UpdateModule.INTERVAL.SEC, function(elapsed: number)
	SystemBUFF.UpdateBuff(elapsed)
end, { spawn = true })

return SystemBUFF
