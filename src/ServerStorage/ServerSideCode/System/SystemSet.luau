--[[
	Module: SystemSet
	Description: 玩家游戏设置（Setting）服务端权威读写与 NumberValue 镜像
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31

	功能：
	- Init(plr)：按 settingConf 创建 player.Setting 下 NumberValue，再叠存档
	- UpdateValue(plr)：将存档 Setting 写入同名 NumberValue
	- ChangeSet(plr, setName, setValue)：校验 → 按 range 钳制 → 写存档 → 刷镜像
	- RegisterNetWork：注册 SETTING_CHANGE RemoteFunction，并配置 RequestRateLimit

	存档：
	- 字段 Setting：{ [ShowName: string]: number }；经 PlayerData.ChangePlrData → SystemSave.ChangeStat
	- 镜像 Folder 名 EnumMgr.PlayerInst.SettingFolder（"Setting"），与存档键同名
	- BGM/EFFECT 旧档 0~1 缩放迁移见 SystemSave/FixData.luau，禁止写在本模块 Init

	校验：
	- setName 必须是 settingConf.ShowName 字面量；setValue 须能 tonumber 且非 NaN/Inf
	- 有 range={min,max} 的项：整数区间先四舍五入再 clamp；无 range 的项（EquipTitle/Code）只校验为数字
	- 修改类成功 true，失败 false + EnumMgr.SetErr；Remote 只回传 boolean，不回传错误码

	视觉：
	- 本模块只写存档与 NumberValue。仓内无 SystemArmor / SystemHumanRace；
	  HideSelfHat / HideSelfRobe / HideRace 的外观由后续表现模块读 NumberValue，禁止在此伪造写口

	调用关系：
	- PlayerManager 入服链调用 Init(plr)
	- UpdateManager 预加载本模块，使 RegisterNetWork 早于客户端 Invoke
	- Setting UI / TopBarManager 经 NetWork.InvokeServer(SETTING_CHANGE, showName, value)
	- 客户端 SettingManager 监听 BGM/EFFECT NumberValue 调节音效组音量

	加载方式（仅服务端）：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SystemSet = Utils.SystemSet

	示例：
		SystemSet.Init(player)
		local ok, err = SystemSet.ChangeSet(player, "BGM", 80)
		if not ok then
			-- err 为 EnumMgr.SetErr.*
		end
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Log = Utils.Log
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local PlayerData = Utils.PlayerData
local CfgFind = Utils.CfgFind
local InsMgr = Utils.InsMgr
local EnumMgr = Utils.EnumMgr
local RequestRateLimit = Utils.RequestRateLimit

-- ========================================
-- 模块定义
-- ========================================
local SystemSet = {}

-- ========================================
-- 常量定义
-- ========================================
local SETTING_CFG_NAME = "settingConf"
local SAVE_KEY = "Setting"
local CLASS_FOLDER = "Folder"
local CLASS_NUMBER_VALUE = "NumberValue"
local RATE_LIMIT_MAX_REQUESTS = 10
local RATE_LIMIT_WINDOW_SEC = 2

local SetErr = EnumMgr.SetErr
local SETTING_FOLDER = EnumMgr.PlayerInst.SettingFolder

-- ========================================
-- 私有变量
-- ========================================
local _rowByShowName: { [string]: any } = {}
local _netRegistered = false

-- ========================================
-- 私有函数
-- ========================================

--[[
	按 ShowName 建 settingConf 索引；配置缺失时打日志并保持空表
	@return nil - 无返回值
]]
local function _indexSettingConf()
	table.clear(_rowByShowName)
	local cfg = CfgFind.GetCfgByName(SETTING_CFG_NAME)
	if type(cfg) ~= "table" then
		Log.warn("SystemSet: settingConf 缺失")
		return
	end
	for _, row in pairs(cfg) do
		if type(row) == "table" and type(row.ShowName) == "string" then
			_rowByShowName[row.ShowName] = row
		end
	end
end

--[[
	校验玩家对象是否在线且有效
	@param plr Player? - 待校验玩家
	@return boolean - 有效为 true
]]
local function _validatePlayer(plr: Player?): boolean
	return plr ~= nil and plr:IsA("Player") and plr.Parent ~= nil
end

--[[
	按 settingConf.range 钳制设置值；整数区间先四舍五入
	@param row table - settingConf 行，字段 range?: {min: number, max: number}
	@param raw number - 已通过 tonumber 的原始值
	@return number - 钳制后的值；无合法 range 时原样返回
]]
local function _clampSettingValue(row: any, raw: number): number
	local range = row.range
	if type(range) ~= "table" then
		return raw
	end
	local lo = range[1]
	local hi = range[2]
	if type(lo) ~= "number" or type(hi) ~= "number" then
		return raw
	end
	local numValue = raw
	if lo == math.floor(lo) and hi == math.floor(hi) then
		numValue = math.floor(numValue + 0.5)
	end
	return math.clamp(numValue, lo, hi)
end

--[[
	数值是否为有限实数（排除 NaN / Inf）
	@param n number - 待检查值
	@return boolean - 有限实数为 true
]]
local function _isFiniteNumber(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

--[[
	获取或创建 player 下的 Setting 文件夹
	@param plr Player - 目标玩家
	@return Folder - Setting 文件夹实例
]]
local function _getFolder(plr: Player): Folder
	return InsMgr.GetIns(SETTING_FOLDER, CLASS_FOLDER, plr) :: Folder
end

-- ========================================
-- 公共 API
-- ========================================

--[[
	将存档 Setting 同步到 player.Setting 下同名 NumberValue
	@param plr Player - 目标玩家
	@return nil - 玩家无效或无存档时提前返回
]]
function SystemSet.UpdateValue(plr: Player)
	if not _validatePlayer(plr) then
		return
	end

	local settingData = PlayerData.GetPlrDataByKey(plr, SAVE_KEY)
	if type(settingData) ~= "table" then
		return
	end

	local folder = _getFolder(plr)
	for k, v in pairs(settingData) do
		if type(k) == "string" and type(v) == "number" then
			local set: Instance? = folder:FindFirstChild(k)
			if set and set:IsA("NumberValue") then
				(set :: NumberValue).Value = v
			end
		end
	end
end

--[[
	玩家入服时创建设置实例并应用存档值（结构补全，非版本迁移）
	@param plr Player - 刚完成数据加载的玩家
	@return nil - 玩家无效时提前返回
]]
function SystemSet.Init(plr: Player)
	if not _validatePlayer(plr) then
		return
	end

	local folder = _getFolder(plr)
	for showName, row in pairs(_rowByShowName) do
		local defaultVal = tonumber(row.set) or 0
		if not _isFiniteNumber(defaultVal) then
			defaultVal = 0
		end
		local set: NumberValue = InsMgr.GetIns(showName, CLASS_NUMBER_VALUE, folder) :: NumberValue
		set.Value = _clampSettingValue(row, defaultVal)
	end

	SystemSet.UpdateValue(plr)
end

--[[
	变更单项设置并写回存档（服务端权威：名称/数值/区间校验后再写）
	@param plr Player - 目标玩家
	@param setName string - settingConf.ShowName
	@param setValue number | string - 新设置值（Remote 可能传字符串）
	@return boolean - 变更成功为 true
	@return string? - 失败时为 EnumMgr.SetErr.*
]]
function SystemSet.ChangeSet(plr: Player, setName: string, setValue: number | string): (boolean, string?)
	if not _validatePlayer(plr) then
		return false, SetErr.InvalidPlayer
	end

	if type(setName) ~= "string" or setName == "" then
		return false, SetErr.InvalidName
	end

	local row = _rowByShowName[setName]
	if not row then
		return false, SetErr.InvalidName
	end

	local numValue = tonumber(setValue)
	if numValue == nil or not _isFiniteNumber(numValue) then
		return false, SetErr.InvalidValue
	end

	numValue = _clampSettingValue(row, numValue)

	local settingData = PlayerData.GetPlrDataByKey(plr, SAVE_KEY)
	if type(settingData) ~= "table" then
		return false, SetErr.NoData
	end

	local ok = PlayerData.ChangePlrData(plr, { SAVE_KEY, setName }, numValue)
	if ok ~= true then
		Log.warn("SystemSet: ChangePlrData 失败", plr.UserId, setName)
		return false, SetErr.SaveFailed
	end

	SystemSet.UpdateValue(plr)
	return true, nil
end

--[[
	注册设置相关 RemoteFunction（SETTING_CHANGE）并配置限频
	@return nil - 无返回值
]]
function SystemSet.RegisterNetWork()
	if _netRegistered then
		return
	end
	_netRegistered = true

	if RequestRateLimit and RequestRateLimit.SetRateLimitConfig then
		RequestRateLimit.SetRateLimitConfig(NetMsg.SETTING_CHANGE, {
			maxRequests = RATE_LIMIT_MAX_REQUESTS,
			timeWindow = RATE_LIMIT_WINDOW_SEC,
		})
	end

	NetWork.RegisterServerRemoteFunction(NetMsg.SETTING_CHANGE, function(player: Player, rawName: string, rawValue: number | string)
		if not _validatePlayer(player) then
			Log.warn("SystemSet: Remote 无效玩家")
			return false
		end
		local ok = SystemSet.ChangeSet(player, rawName, rawValue)
		return ok == true
	end)
end

_indexSettingConf()

-- ========================================
-- 模块加载时注册通信（ServerStorage，无需 IsServer）
-- ========================================
SystemSet.RegisterNetWork()

return SystemSet
