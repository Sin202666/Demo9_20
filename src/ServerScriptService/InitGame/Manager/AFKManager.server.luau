--[[
	Module: AFKManager
	Description: 挂机管理器（服务端），处理客户端 AFK 超时后的跨服传送
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-12

	功能：
	- 注册 NetMsg.AFK_MOVE 限频（60 秒内最多 1 次）
	- 校验玩家在线且未在传送中，调用 SystemTeleport 刷新会话
	- GameConfig.AFK.挂机重连复位 开启时：存活玩家经 TeleportData 捎带完整 CFrame；进服后由 PlayerManager 复位

	与 AFKManager.client / SystemTeleport / PlayerManager 关系：
	客户端 Idled 触发 AFK_MOVE；本模块路由至 SystemTeleport.TeleportWithRetry；
	复位坐标仅作 TeleportData 载荷，落地应用在 PlayerManager
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local SystemTeleport = Utils.SystemTeleport
local RequestRateLimit = Utils.RequestRateLimit
local SystemGameConfig = Utils.SystemGameConfig
local HumanModule = Utils.HumanModule
local EnumMgr = Utils.EnumMgr
local Log = Utils.Log

local PlayerInst = EnumMgr.PlayerInst
local PlayerAttr = EnumMgr.PlayerAttr

-- ============================================================================
-- 常量
-- ============================================================================

local AFK_RESTORE_KEY = "afkRestore"

-- ============================================================================
-- 限频配置
-- ============================================================================

RequestRateLimit.SetRateLimitConfig(NetMsg.AFK_MOVE, {
	maxRequests = 1,
	timeWindow = 60,
})

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	是否开启挂机重连位置复位
	@return boolean - true 表示开启
]]
local function _isAfkRestoreEnabled(): boolean
	return SystemGameConfig.GetValue({ "AFK", "挂机重连复位" }) == true
end

--[[
	将 CFrame 序列化为 TeleportData 可用的具名分量（避免 JSON 数组下标漂移）
	@param cf CFrame - 完整位姿
	@return {[string]: number} - 位置与旋转矩阵分量
]]
local function _cframeToComponents(cf: CFrame): { [string]: number }
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	return {
		x = x,
		y = y,
		z = z,
		r00 = r00,
		r01 = r01,
		r02 = r02,
		r10 = r10,
		r11 = r11,
		r12 = r12,
		r20 = r20,
		r21 = r21,
		r22 = r22,
	}
end

--[[
	采集挂机复位 TeleportOptions；死亡或无 HRP 时返回 nil（仍可无载荷传送）
	@param plr Player - 待传送玩家
	@return TeleportOptions? - 含 afkRestore 的选项；无法复位时为 nil
]]
local function _buildRestoreTeleportOptions(plr: Player): TeleportOptions?
	if plr:GetAttribute(PlayerAttr.Die) == true then
		Log.warn("AFK 复位跳过，玩家已死亡:", plr.Name)
		return nil
	end

	local rootPart = HumanModule.GetHumanoidRootPart(plr)
	if not rootPart then
		Log.warn("AFK 复位跳过，无 HumanoidRootPart:", plr.Name)
		return nil
	end

	local options = Instance.new("TeleportOptions")
	options:SetTeleportData({
		[AFK_RESTORE_KEY] = {
			placeId = game.PlaceId,
			cf = _cframeToComponents(rootPart.CFrame),
		},
	})
	return options
end

-- ============================================================================
-- Remote 注册
-- ============================================================================

NetWork.RegisterServerRemoteEvent(NetMsg.AFK_MOVE, function(plr: Player)
	if not plr or not plr.Parent then
		return
	end

	local isTeleport: BoolValue? = plr:FindFirstChild(PlayerInst.Teleporting) :: BoolValue?
	if isTeleport and isTeleport.Value then
		Log.warn("AFK 传送跳过，玩家已在传送中:", plr.Name)
		return
	end

	if SystemTeleport.IsPending(plr) then
		return
	end

	local teleportOptions: TeleportOptions? = nil
	if _isAfkRestoreEnabled() then
		teleportOptions = _buildRestoreTeleportOptions(plr)
	end

	SystemTeleport.TeleportWithRetry(game.PlaceId, { plr }, teleportOptions)
end)
