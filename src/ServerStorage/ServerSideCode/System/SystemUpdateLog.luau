--[[
	Module: SystemUpdateLog
	Description: 玩家更新公告已读状态读写；入服时未读最新公告则弹出 NewsMail_Full
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-01

	功能：
	- Init(plr)：玩家入服后，若 updatelogConf 中 UpdateTime 最大的一条未读，则打开 NewsMail_Full
	- ReadUpdateLog(plr, updateId)：校验配置后标记指定条目已读；成功 true，失败 false + EnumMgr.UpdateLogErr
	- RegisterNetWork：注册 UPDATE_LOG_READ RemoteEvent（幂等），并配置 RequestRateLimit

	数据：
	- 存档 UpdateLog：{ [string updateId]: { IsRead: 0|1 } }；经 PlayerData.ChangePlrData 整表回写
	- 必须整表回写（键为 "UpdateLog"）：NewsMail_Full 按 string key 听增量，路径写入会丢刷新
	- 已读判定：entry.IsRead == 1（常量 IS_READ）

	调用关系：
	- PlayerManager 存档加载完成后调用 Init(plr)
	- UpdateManager 预加载本模块，使 RegisterNetWork 早于客户端 Fire
	- 客户端公告 UI 为 NewsMail_Full（邮件 Tab 已隐藏），经 NetWork.FireServer(UPDATE_LOG_READ, id)
	- 本模块只写已读存档并 FireClient SHOW_LOCAL_UI，不直接操作 UI Instance

	加载方式（仅服务端）：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SystemUpdateLog = Utils.SystemUpdateLog

	示例：
		SystemUpdateLog.Init(player)
		local ok, err = SystemUpdateLog.ReadUpdateLog(player, 1)
		if not ok then
			-- err 为 EnumMgr.UpdateLogErr.*
		end
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Log = Utils.Log
local Copy = Utils.Copy
local PlayerData = Utils.PlayerData
local CfgFind = Utils.CfgFind
local EnumMgr = Utils.EnumMgr
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local RequestRateLimit = Utils.RequestRateLimit

-- ========================================
-- 模块定义
-- ========================================
local SystemUpdateLog = {}

-- ========================================
-- 常量定义
-- ========================================
local CFG_NAME = "updatelogConf"
local SAVE_KEY_UPDATE_LOG = "UpdateLog"
-- Place 中公告弹窗 Frame / GuiScripts 模块名（邮件 Tab 已隐藏）
local UI_NAME_UPDATE = "NewsMail_Full"
-- 入服后稍等，避免客户端 UIManager 尚未注册 SHOW_LOCAL_UI 时丢包
local POPUP_DELAY_SEC = 2
local IS_READ = 1
local RATE_LIMIT_MAX_REQUESTS = 10
local RATE_LIMIT_WINDOW_SEC = 2

local UpdateLogErr = EnumMgr.UpdateLogErr

-- ========================================
-- 私有变量
-- ========================================
local _netRegistered = false

-- ========================================
-- 私有函数
-- ========================================

--[[
	校验玩家是否仍在线且有效

	@param plr Player? - 待校验玩家
	@return boolean - true 表示玩家有效
]]
local function _validatePlayer(plr: Player?): boolean
	return plr ~= nil and plr:IsA("Player") and plr.Parent ~= nil
end

--[[
	取 updatelogConf 中 UpdateTime 最大的条目 ID

	@return number? - 最新公告配置 ID；无配置时为 nil
]]
local function _getLatestUpdateId(): number?
	local updateLogConf = CfgFind.GetCfgByName(CFG_NAME)
	if type(updateLogConf) ~= "table" then
		return nil
	end

	local latestId: number? = nil
	local latestTime = 0

	for id, cfg in pairs(updateLogConf) do
		if type(id) == "number" and type(cfg) == "table" then
			local updateTime = cfg.UpdateTime
			if type(updateTime) == "number" and updateTime > latestTime then
				latestTime = updateTime
				latestId = id
			end
		end
	end

	return latestId
end

--[[
	判断玩家是否已读指定公告

	@param plr Player - 玩家对象
	@param updateId number - updatelogConf 索引
	@return boolean - true 表示已读
]]
local function _isUpdateRead(plr: Player, updateId: number): boolean
	local updateLog = PlayerData.GetPlrDataByKey(plr, SAVE_KEY_UPDATE_LOG)
	if type(updateLog) ~= "table" then
		return false
	end

	local entry = updateLog[tostring(updateId)]
	return type(entry) == "table" and entry.IsRead == IS_READ
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	玩家入服：最新更新公告未读则弹出公告界面

	@param plr Player - 刚完成存档加载的玩家
	@return nil - 无返回值
]]
function SystemUpdateLog.Init(plr: Player)
	if not _validatePlayer(plr) then
		return
	end

	local latestId = _getLatestUpdateId()
	if not latestId then
		return
	end

	if _isUpdateRead(plr, latestId) then
		return
	end

	task.delay(POPUP_DELAY_SEC, function()
		if not _validatePlayer(plr) then
			return
		end
		if _isUpdateRead(plr, latestId) then
			return
		end
		NetWork.FireClient(plr, NetMsg.SHOW_LOCAL_UI, UI_NAME_UPDATE, nil, true, true)
	end)
end

--[[
	标记指定更新公告为已读（服务端权威：配置存在且未读才写档）

	@param plr Player - 玩家对象
	@param updateId number | string - updatelogConf 索引（number 或可 tonumber 的 string）
	@return boolean - true 表示本次标记成功
	@return string? - 失败时为 EnumMgr.UpdateLogErr.*
]]
function SystemUpdateLog.ReadUpdateLog(plr: Player, updateId: number | string): (boolean, string?)
	if not _validatePlayer(plr) then
		return false, UpdateLogErr.InvalidPlayer
	end

	local numericId = tonumber(updateId)
	if not numericId or numericId ~= numericId or numericId ~= math.floor(numericId) then
		return false, UpdateLogErr.InvalidId
	end

	local updateLogConf = CfgFind.GetCfgByName(CFG_NAME)
	if type(updateLogConf) ~= "table" or type(updateLogConf[numericId]) ~= "table" then
		return false, UpdateLogErr.UnknownId
	end

	local idStr = tostring(numericId)
	local rawLog = PlayerData.GetPlrDataByKey(plr, SAVE_KEY_UPDATE_LOG)
	-- 服务端 GetPlrDataByKey 返回会话活引用，先拷贝再改，避免 ChangeStat 失败留下脏写
	local updateLog = if type(rawLog) == "table" then Copy.deepCopy(rawLog) else {}

	local entry = updateLog[idStr]
	if type(entry) == "table" and entry.IsRead == IS_READ then
		return false, UpdateLogErr.AlreadyRead
	end

	updateLog[idStr] = { IsRead = IS_READ }
	local ok = PlayerData.ChangePlrData(plr, SAVE_KEY_UPDATE_LOG, updateLog)
	if ok ~= true then
		Log.warn("SystemUpdateLog: ChangePlrData 失败", plr.UserId, idStr)
		return false, UpdateLogErr.SaveFailed
	end
	return true, nil
end

--[[
	注册公告已读 RemoteEvent 并配置限频（幂等；须在模块加载时调用，避免客户端 Fire 早于 Init）

	@return nil - 无返回值
]]
function SystemUpdateLog.RegisterNetWork()
	if _netRegistered then
		return
	end
	_netRegistered = true

	if RequestRateLimit and RequestRateLimit.SetRateLimitConfig then
		RequestRateLimit.SetRateLimitConfig(NetMsg.UPDATE_LOG_READ, {
			maxRequests = RATE_LIMIT_MAX_REQUESTS,
			timeWindow = RATE_LIMIT_WINDOW_SEC,
		})
	end

	NetWork.RegisterServerRemoteEvent(NetMsg.UPDATE_LOG_READ, function(player: Player, updateId: number | string)
		if not _validatePlayer(player) then
			Log.warn("SystemUpdateLog: Remote 无效玩家")
			return
		end
		local ok, err = SystemUpdateLog.ReadUpdateLog(player, updateId)
		if not ok and err ~= UpdateLogErr.AlreadyRead then
			Log.warn("SystemUpdateLog: 已读失败", player.UserId, err)
		end
	end)
end

-- ========================================
-- 模块加载时注册通信（ServerStorage，无需 IsServer）
-- ========================================
SystemUpdateLog.RegisterNetWork()

return SystemUpdateLog
