--[[
	Module: DebugManager
	Description: 服务端调试编排——将 DEBUG_* Remote 校验后路由到 SystemBag / SystemRecord / SystemDataStore / SystemEmail
	Author: 林奥宇
	Created: 2026-01-29
	Last Modified: 2026-09-04

	功能：
	- DEBUG_BAG：Dev 服下背包增删清，路由 SystemBag
	- DEBUG_SPECIAL：Dev 服下覆盖统计记录 / 在线奖励加秒与重置
	- DEBUG_RESET：Dev 服下清档（SystemDataStore.Remove）并踢出；PlayerRemoving 见 PlayerManager 对 ResetPlayer 跳过存档
	- DEBUG_EMAIL：GM 白名单发运营邮件，路由 SystemEmail.GivePlrEmail（不受 Dev 开关限制）

	与相关模块：
	- 本 Manager 只做校验、限频与路由，不实现背包/邮件业务
	- 清档走 SystemDataStore 门面（无法用 SystemSave.ChangeStat 删除整档）；完整下沉 SystemSave 须单独方案（结构 §1.8）
	- 客户端同名 Manager 发 Remote；GM 面板走 GMEmail

	端侧约束：
	- 仅服务端脚本，由 InitGame 启动自动运行，无需 require / Init()
	- DEBUG_BAG / SPECIAL / RESET 仅 Dev；DEBUG_EMAIL 仅白名单
	- Remote 入站 skipRateLimit + skipCheatDetection（避免调试操作被当成作弊），本模块按 NetMsg 名手写 CheckRateLimit
	- 先限频再解析载荷，避免恶意刷非法包消耗后续校验

	示例：
		-- 客户端 DebugManager 发 DEBUG_BAG { msgType = EnumMgr.DebugBagOp.Add, itemID, itemCount }
		-- GMEmail InvokeServer(NetMsg.DEBUG_EMAIL, EnumMgr.GmEmailOp.Send, emailData)
]]

-- ============================================================================
-- 导入和依赖
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local SystemBag = Utils.SystemBag
local SystemRecord = Utils.SystemRecord
local SystemDataStore = Utils.SystemDataStore
local SystemEmail = Utils.SystemEmail
local SystemOnlineAward = Utils.SystemOnlineAward
local InsMgr = Utils.InsMgr
local RequestRateLimit = Utils.RequestRateLimit
local WorldUtil = Utils.WorldUtil
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local EnumMgr = Utils.EnumMgr
local Log = Utils.Log
local GmEmailWhitelist = Utils.GmEmailWhitelist

-- ============================================================================
-- 常量定义
-- ============================================================================

local PLAYER_STORE = SystemDataStore.STORE.Player

local REMOVE_STORE_OPTIONS = {
	maxTries = 1,
	retryIntervalSec = 0,
}

local SERVER_TYPE_DEV = "Dev"

local KICK_MSG_RESET = "重新进入"

local skipMiddleware = { skipRateLimit = true, skipCheatDetection = true }

-- ============================================================================
-- 内部辅助函数
-- ============================================================================

--[[
	判断当前环境是否允许调试功能（仅 Dev 服务器）
	@return boolean - 允许时 true
]]
local function _isDebugEnabled(): boolean
	return WorldUtil.GetServerType() == SERVER_TYPE_DEV
end

--[[
	校验 Remote 调用方玩家是否有效
	@param player any - Remote 传入的玩家对象
	@return Player? - 有效玩家；无效时 nil
]]
local function _validatePlayer(player: any): Player?
	if not player or not player:IsA("Player") then
		return nil
	end
	return player
end

--[[
	Dev 环境 + 玩家对象 + 频率限制。先限频再交给业务，避免非法包刷校验。
	@param player any - Remote 传入的玩家
	@param rateLimitKey string - RequestRateLimit 使用的消息名，与 NetMsg 对齐
	@return Player? - 通过时返回玩家；否则 nil
]]
local function _guardDebugRemote(player: any, rateLimitKey: string): Player?
	if not _isDebugEnabled() then
		return nil
	end
	local validPlayer = _validatePlayer(player)
	if not validPlayer then
		return nil
	end
	if not RequestRateLimit.CheckRateLimit(validPlayer, rateLimitKey) then
		return nil
	end
	return validPlayer
end

--[[
	处理物品添加
	@param player Player - 目标玩家
	@param itemID number - 物品 ID，须为正数
	@param itemCount number - 物品数量，须为正数
	@return nil
]]
local function _handleBagAdd(player: Player, itemID: number, itemCount: number)
	if type(itemCount) ~= "number" or itemCount <= 0 then
		Log.warn("DebugManager: 添加物品数量不合法", itemCount)
		return
	end
	local success, err = SystemBag.AddItems(player, { itemID }, { itemCount })
	if success then
		Log.print(string.format("DebugManager: 玩家 %s 添加物品 ID=%d 数量=%d", player.Name, itemID, itemCount))
	else
		Log.warn(string.format("DebugManager: 玩家 %s 添加物品失败 ID=%d 数量=%d err=%s", player.Name, itemID, itemCount, tostring(err)))
	end
end

--[[
	处理物品减少
	@param player Player - 目标玩家
	@param itemID number - 物品 ID，须为正数
	@param itemCount number - 物品数量，须为正数
	@return nil
]]
local function _handleBagRemove(player: Player, itemID: number, itemCount: number)
	if type(itemCount) ~= "number" or itemCount <= 0 then
		Log.warn("DebugManager: 减少物品数量不合法", itemCount)
		return
	end
	local success, err = SystemBag.RemoveItem(player, { itemID }, { itemCount })
	if success then
		Log.print(string.format("DebugManager: 玩家 %s 减少物品 ID=%d 数量=%d", player.Name, itemID, itemCount))
	else
		Log.warn(string.format("DebugManager: 玩家 %s 减少物品失败 ID=%d 数量=%d err=%s", player.Name, itemID, itemCount, tostring(err)))
	end
end

--[[
	处理物品清空
	@param player Player - 目标玩家
	@param itemID number - 物品 ID，须为正数
	@return nil
]]
local function _handleBagClear(player: Player, itemID: number)
	local success, err = SystemBag.RemoveAllItem(player, itemID)
	if success then
		Log.print(string.format("DebugManager: 玩家 %s 清空物品 ID=%d", player.Name, itemID))
	else
		Log.warn(string.format("DebugManager: 玩家 %s 清空物品失败 ID=%d err=%s", player.Name, itemID, tostring(err)))
	end
end

local _bagOperationHandlers = {
	[EnumMgr.DebugBagOp.Add] = _handleBagAdd,
	[EnumMgr.DebugBagOp.Remove] = _handleBagRemove,
	[EnumMgr.DebugBagOp.Clear] = _handleBagClear,
}

--[[
	处理物品操作（添加、减少、清空）
	@param player Player - 目标玩家
	@param msgData any - 消息数据，字段：msgType(number DebugBagOp)、itemID(number)、itemCount(number?)
	@return nil
]]
local function _handleBagOperation(player: Player, msgData: any)
	if type(msgData) ~= "table" then
		Log.warn("DebugManager: HandleBagOperation msgData 类型不合法", msgData)
		return
	end

	local msgType = msgData.msgType
	local itemID = msgData.itemID
	local itemCount = msgData.itemCount

	if type(itemID) ~= "number" or itemID <= 0 then
		Log.warn("DebugManager: HandleBagOperation 物品ID不合法", itemID)
		return
	end

	local handler = _bagOperationHandlers[msgType]
	if not handler then
		Log.warn("DebugManager: HandleBagOperation 未知的操作类型", msgType)
		return
	end

	handler(player, itemID, itemCount)
end

--[[
	覆盖玩家统计记录
	@param player Player - 目标玩家
	@param data any - 客户端以数组发送：data[1] 记录名称，data[2] 记录值（可 tonumber）
	@return nil
]]
local function _handleCoverRecord(player: Player, data: any)
	local recordName = data[1]
	local recordValue = data[2]

	if type(recordName) ~= "string" or recordName == "" then
		Log.warn("DebugManager: HandleSpecialOperation 记录名称不合法", recordName)
		return
	end

	local value = tonumber(recordValue)
	if not value then
		Log.warn("DebugManager: HandleSpecialOperation 记录值不合法", recordValue)
		return
	end

	local success, err = SystemRecord.RecordCover(player, recordName, value)
	if success then
		Log.print(string.format("DebugManager: 玩家 %s 修改记录 %s = %d", player.Name, recordName, value))
	else
		Log.warn(string.format("DebugManager: 玩家 %s 修改记录失败 %s = %d err=%s", player.Name, recordName, value, tostring(err)))
	end
end

local _specialOperationHandlers = {
	[EnumMgr.DebugSpecialOp.CoverRecord] = _handleCoverRecord,
	[EnumMgr.DebugSpecialOp.AddOnlineSeconds] = function(player: Player, data: any)
		local sec = tonumber(data[1])
		if not sec then
			Log.warn("DebugManager: 增加在线时长秒数不合法", data[1])
			return
		end
		local ok = SystemOnlineAward.AddOnlineSeconds(player, sec)
		if ok then
			Log.print("DebugManager: 增加在线时长", player.Name, sec)
		else
			Log.warn("DebugManager: 增加在线时长失败", player.Name, sec)
		end
	end,
	[EnumMgr.DebugSpecialOp.ResetOnlineAward] = function(player: Player, _data: any)
		SystemOnlineAward.ResetOnlineAward(player)
		Log.print("DebugManager: 重置在线奖励", player.Name)
	end,
}

--[[
	处理特殊数据操作（修改记录等）
	@param player Player - 目标玩家
	@param operationType string - 操作类型，取值 EnumMgr.DebugSpecialOp
	@param data any - 操作数据；修改记录时为 { [1]=string, [2]=string|number }
	@return nil
]]
local function _handleSpecialOperation(player: Player, operationType: string, data: any)
	if type(data) ~= "table" then
		Log.warn("DebugManager: HandleSpecialOperation data 类型不合法", data)
		return
	end

	local handler = _specialOperationHandlers[operationType]
	if not handler then
		Log.warn("DebugManager: HandleSpecialOperation 未知的操作类型", operationType)
		return
	end

	handler(player, data)
end

--[[
	初始化玩家数据（清档并踢出重进）。Remove 失败时回滚 ResetPlayer，不踢人，以便离场仍走存档。
	@param player Player - 目标玩家
	@return nil
]]
local function _handleResetData(player: Player)
	local resetPlayer: BoolValue = InsMgr.GetIns(EnumMgr.PlayerInst.ResetPlayer, "BoolValue", player)
	resetPlayer.Value = true

	local playerKey = SystemDataStore.BuildPlayerKey(player.UserId)
	local ok, err = SystemDataStore.Remove(PLAYER_STORE, playerKey, REMOVE_STORE_OPTIONS)
	if not ok then
		resetPlayer.Value = false
		Log.warn("DebugManager: 清档 Remove 失败", playerKey, err)
		return
	end

	player:Kick(KICK_MSG_RESET)
end

--[[
	处理 GM 发邮件 RemoteFunction

	@param player Player - 调用方
	@param operationType string - 操作类型，当前支持 EnumMgr.GmEmailOp.Send
	@param emailData any - 邮件数据，须含 UserID/RewardID/RewardCount
	@return boolean | string - 成功 true；失败 false（第二值为 GmEmailErr）；已写入会补发为 QueuedGrantFailed；已同步但回滚失败为 SyncRevertFailed
	@return string? - 失败时的 GmEmailErr；成功或第一值已是错误码时为 nil
]]
local function _handleDebugEmail(player: Player, operationType: string, emailData: any): (boolean | string, string?)
	if not GmEmailWhitelist.IsAllowed(player.UserId) then
		return false, EnumMgr.GmEmailErr.NotWhitelisted
	end
	if operationType ~= EnumMgr.GmEmailOp.Send then
		return false, EnumMgr.GmEmailErr.UnknownOperation
	end
	if type(emailData) ~= "table" then
		return false, EnumMgr.GmEmailErr.InvalidEmailData
	end
	local ok, err = SystemEmail.GivePlrEmail(emailData)
	if not ok then
		return false, err or EnumMgr.GmEmailErr.SendFailed
	end
	Log.print(string.format(
		"DebugManager: 玩家 %s GM发邮件 -> UserID=%s",
		player.Name,
		tostring(emailData.UserID)
	))
	-- RemoteFunction 经 NetWork 只回传第一返回值，故把「已写入未入包 / 回滚失败」作为第一返回值
	if err == EnumMgr.GmEmailErr.QueuedGrantFailed or err == EnumMgr.GmEmailErr.SyncRevertFailed then
		return err
	end
	return true
end

-- ============================================================================
-- 通信注册
-- ============================================================================

NetWork.RegisterServerRemoteEvent(NetMsg.DEBUG_BAG, function(player: Player, msgData: any)
	local validPlayer = _guardDebugRemote(player, NetMsg.DEBUG_BAG)
	if not validPlayer then
		return
	end
	_handleBagOperation(validPlayer, msgData)
end, skipMiddleware)

NetWork.RegisterServerRemoteEvent(NetMsg.DEBUG_SPECIAL, function(player: Player, operationType: string, data: any)
	local validPlayer = _guardDebugRemote(player, NetMsg.DEBUG_SPECIAL)
	if not validPlayer then
		return
	end
	_handleSpecialOperation(validPlayer, operationType, data)
end, skipMiddleware)

NetWork.RegisterServerRemoteEvent(NetMsg.DEBUG_RESET, function(player: Player)
	local validPlayer = _guardDebugRemote(player, NetMsg.DEBUG_RESET)
	if not validPlayer then
		return
	end
	_handleResetData(validPlayer)
end, skipMiddleware)

NetWork.RegisterServerRemoteFunction(NetMsg.DEBUG_EMAIL, function(player: Player, operationType: string, emailData: any)
	local validPlayer = _validatePlayer(player)
	if not validPlayer then
		return false, EnumMgr.GmEmailErr.InvalidPlayer
	end
	if not RequestRateLimit.CheckRateLimit(validPlayer, NetMsg.DEBUG_EMAIL) then
		return false, EnumMgr.GmEmailErr.RateLimit
	end
	return _handleDebugEmail(validPlayer, operationType, emailData)
end, skipMiddleware)

Log.print("DebugManager: 调试管理器已初始化")
