--[[
	Module: SystemRedPoint
	Description: 玩家红点计数同步（Player 下 NumberValue 镜像 + RedPoint 存档字段）
	Author: 林奥宇
	Created: 2026-04-21
	Last Modified: 2026-09-04

	功能：
	- SetRedValue：设置指定红点计数（钳制为 ≥0 的整数）
	- AddRedValue：累加红点计数（默认 +1；结果钳制为 ≥0）
	- RemoveRedValue：清除红点（置 0）
	- UpdateRedPoint：按业务重算或从存档同步到镜像
	- GetRedPointNames：返回已注册红点名称列表（深拷贝）
	- Init(plr)：入服时为已注册红点创建 NumberValue 并恢复存档值

	约束：
	- 仅服务端；须玩家在线且已加载存档
	- 红点名必须是本模块注册名（见 GetRedPointNames）；未知名拒绝写入，避免污染存档
	- 先 PlayerData.ChangePlrData 成功，再写 NumberValue 镜像
	- 镜像 Folder 名走 EnumMgr.PlayerInst.RedPointFolder；UI 只读，不作为结算依据

	调用关系：
	- PlayerManager 入服时调用 Init(plr)
	- SystemDailyAward 直接 Add/Remove「签到红点」
	- SystemOnlineAward 在线进度变化时 SetRedValue（在线奖励红点）
	- SystemRecord 统计变更时调用 UpdateRedPoint（成就红点）

	加载方式（仅服务端）：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SystemRedPoint = Utils.SystemRedPoint

	示例：
		SystemRedPoint.Init(player)
		SystemRedPoint.SetRedValue(player, "签到红点", 1)
		local ok, err = SystemRedPoint.AddRedValue(player, "签到红点")
		if not ok then
			-- err 为 INVALID_PLAYER / NO_SAVE_DATA / UNKNOWN_RED_NAME / INVALID_VALUE / SAVE_FAILED
		end
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local PlayerData = Utils.PlayerData
local Copy = Utils.Copy
local Log = Utils.Log
local InsMgr = Utils.InsMgr
local EnumMgr = Utils.EnumMgr

-- ========================================
-- 模块定义
-- ========================================
local SystemRedPoint = {}

-- ========================================
-- 常量定义
-- ========================================
local STAT_RED_POINT = "RedPoint"
local FOLDER_NAME = EnumMgr.PlayerInst.RedPointFolder
local CLASS_FOLDER = "Folder"
local CLASS_NUMBER_VALUE = "NumberValue"

local RED_POINT_BAG = "背包红点"
local RED_POINT_SIGN = "签到红点"
local RED_POINT_ACHIEVE = "成就红点"
local RED_POINT_SHOP = "商城红点"
local RED_POINT_ONLINE = "在线奖励红点"

local RED_POINT_INIT_LIST: { string } = {
	RED_POINT_BAG,
	RED_POINT_SIGN,
	RED_POINT_ACHIEVE,
	RED_POINT_SHOP,
	RED_POINT_ONLINE,
}

local RED_POINT_NAME_SET: { [string]: boolean } = {
	[RED_POINT_BAG] = true,
	[RED_POINT_SIGN] = true,
	[RED_POINT_ACHIEVE] = true,
	[RED_POINT_SHOP] = true,
	[RED_POINT_ONLINE] = true,
}

local ERR_INVALID_PLAYER = "INVALID_PLAYER"
local ERR_NO_SAVE_DATA = "NO_SAVE_DATA"
local ERR_UNKNOWN_RED_NAME = "UNKNOWN_RED_NAME"
local ERR_INVALID_VALUE = "INVALID_VALUE"
local ERR_SAVE_FAILED = "SAVE_FAILED"

-- ========================================
-- 私有函数
-- ========================================

--[[
	校验玩家是否为在线 Player 实例。

	@param plr Player - 待校验玩家
	@return boolean - 有效且仍在 Players 中为 true
]]
local function _validatePlayer(plr: Player): boolean
	return plr ~= nil and plr:IsA("Player") and plr.Parent ~= nil
end

--[[
	红点名是否已在本模块注册。

	@param redName string - 待校验名称
	@return boolean - 已注册为 true
]]
local function _isKnownRedName(redName: string): boolean
	return type(redName) == "string" and RED_POINT_NAME_SET[redName] == true
end

--[[
	将计数规范为 ≥0 的整数；NaN / Inf / 非数字返回 nil。

	@param num any - 原始数值
	@return number? - 钳制后的计数；无法规范时为 nil
]]
local function _normalizeCount(num: any): number?
	if type(num) ~= "number" or num ~= num or num == math.huge or num == -math.huge then
		return nil
	end
	return math.max(0, math.floor(num))
end

--[[
	读取玩家 RedPoint 存档快照（GetPlrData 深拷贝后的子表，非会话活引用）。

	@param plr Player - 目标玩家
	@return { [string]: number }? - 键为已注册红点名、值为计数；无存档或字段非表时为 nil
]]
local function _getRedData(plr: Player): { [string]: number }?
	local redPoint = PlayerData.GetPlrDataByKey(plr, STAT_RED_POINT)
	if type(redPoint) ~= "table" then
		return nil
	end
	return redPoint
end

--[[
	获取或创建玩家下的红点 Folder。

	@param plr Player - 目标玩家；须仍在 Players 中
	@return Folder? - 镜像 Folder；玩家已离开或同名实例类型错误时为 nil
]]
local function _getFolder(plr: Player): Folder?
	local folder = InsMgr.GetIns(FOLDER_NAME, CLASS_FOLDER, plr)
	if folder:IsA("Folder") then
		return folder
	end
	Log.warn("SystemRedPoint: 红点 Folder 类型错误", plr.UserId, folder.ClassName)
	return nil
end

--[[
	确保指定红点 NumberValue 存在，并写入当前值。

	@param folder Folder - 玩家红点 Folder
	@param redName string - 已注册红点名称
	@param value number - 要同步到镜像的计数（≥0 整数）
	@return NumberValue? - 对应 NumberValue；同名实例类型错误时为 nil
]]
local function _ensureRedValue(folder: Folder, redName: string, value: number): NumberValue?
	local inst = InsMgr.GetIns(redName, CLASS_NUMBER_VALUE, folder)
	if not inst:IsA("NumberValue") then
		Log.warn("SystemRedPoint: 红点实例类型错误", redName, inst.ClassName)
		return nil
	end
	local redValue = inst :: NumberValue
	redValue.Value = value
	return redValue
end

--[[
	写入红点计数：先存档成功再同步镜像。

	@param plr Player - 目标玩家
	@param redName string - 已注册红点名称
	@param num number - 目标计数（将钳制为 ≥0 整数）
	@return boolean - 写入成功为 true
	@return string? - 失败时为 INVALID_PLAYER / NO_SAVE_DATA / UNKNOWN_RED_NAME / INVALID_VALUE / SAVE_FAILED
]]
local function _applyRedValue(plr: Player, redName: string, num: number): (boolean, string?)
	if not _validatePlayer(plr) then
		return false, ERR_INVALID_PLAYER
	end
	if not _isKnownRedName(redName) then
		Log.warn("SystemRedPoint: 未知红点名", redName)
		return false, ERR_UNKNOWN_RED_NAME
	end

	local count = _normalizeCount(num)
	if count == nil then
		return false, ERR_INVALID_VALUE
	end

	local redPoint = _getRedData(plr)
	if not redPoint then
		return false, ERR_NO_SAVE_DATA
	end

	local current = tonumber(redPoint[redName]) or 0
	if current ~= count then
		local ok, err = PlayerData.ChangePlrData(plr, { STAT_RED_POINT, redName }, count)
		if not ok then
			Log.warn("SystemRedPoint: 写入存档失败", plr.UserId, redName, err)
			return false, err or ERR_SAVE_FAILED
		end
	end

	local folder = _getFolder(plr)
	if not folder then
		return false, ERR_INVALID_PLAYER
	end
	if not _ensureRedValue(folder, redName, count) then
		return false, ERR_INVALID_PLAYER
	end
	return true, nil
end

--[[
	按红点类型重算数值；无专用逻辑时从存档快照读取。

	@param plr Player - 目标玩家
	@param redName string - 已注册红点名称
	@return number? - 重算或存档计数；无存档时为 nil
]]
local function _resolveRedValue(plr: Player, redName: string): number?
	-- TODO(林奥宇, 2026-08-31): 成就红点、商城红点待 Achieve/Shop 检测 API 接入

	local redPoint = _getRedData(plr)
	if not redPoint then
		return nil
	end
	return tonumber(redPoint[redName]) or 0
end

-- ========================================
-- 公共 API
-- ========================================

--[[
	返回已注册红点名称列表（深拷贝，调用方改副本不影响注册表）。

	@return { string } - 红点名称数组副本，如「签到红点」
]]
function SystemRedPoint.GetRedPointNames(): { string }
	return Copy.deepCopy(RED_POINT_INIT_LIST)
end

--[[
	设置红点计数。未知名称拒绝；非数字拒绝；负数/小数钳制为 ≥0 整数。

	@param plr Player - 目标玩家；须在线且已加载存档
	@param redName string - 已注册红点名称，如「签到红点」
	@param num number - 目标计数
	@return boolean - 设置成功为 true
	@return string? - 失败时为 INVALID_PLAYER / NO_SAVE_DATA / UNKNOWN_RED_NAME / INVALID_VALUE / SAVE_FAILED
]]
function SystemRedPoint.SetRedValue(plr: Player, redName: string, num: number): (boolean, string?)
	return _applyRedValue(plr, redName, num)
end

--[[
	累加红点计数。结果经 Set 路径钳制为 ≥0。

	@param plr Player - 目标玩家；须在线且已加载存档
	@param redName string - 已注册红点名称
	@param addNum number? - 增量，默认 1；可为负（减到 0 为止）
	@return boolean - 累加成功为 true
	@return string? - 失败时为 INVALID_PLAYER / NO_SAVE_DATA / UNKNOWN_RED_NAME / INVALID_VALUE / SAVE_FAILED
]]
function SystemRedPoint.AddRedValue(plr: Player, redName: string, addNum: number?): (boolean, string?)
	if not _validatePlayer(plr) then
		return false, ERR_INVALID_PLAYER
	end
	if not _isKnownRedName(redName) then
		Log.warn("SystemRedPoint: 未知红点名", redName)
		return false, ERR_UNKNOWN_RED_NAME
	end

	local delta = addNum
	if delta == nil then
		delta = 1
	elseif type(delta) ~= "number" or delta ~= delta or delta == math.huge or delta == -math.huge then
		return false, ERR_INVALID_VALUE
	end

	local redPoint = _getRedData(plr)
	if not redPoint then
		return false, ERR_NO_SAVE_DATA
	end

	local current = tonumber(redPoint[redName]) or 0
	return _applyRedValue(plr, redName, current + delta)
end

--[[
	清除红点（置 0）。

	@param plr Player - 目标玩家；须在线且已加载存档
	@param redName string - 已注册红点名称
	@return boolean - 清除成功为 true
	@return string? - 失败时为 INVALID_PLAYER / NO_SAVE_DATA / UNKNOWN_RED_NAME / SAVE_FAILED
]]
function SystemRedPoint.RemoveRedValue(plr: Player, redName: string): (boolean, string?)
	return _applyRedValue(plr, redName, 0)
end

--[[
	重算或同步指定红点到镜像。当前无业务重算时等于从存档刷镜像。

	@param plr Player - 目标玩家；须在线且已加载存档
	@param redName string - 已注册红点名称
	@return boolean - 更新成功为 true
	@return string? - 失败时为 INVALID_PLAYER / NO_SAVE_DATA / UNKNOWN_RED_NAME / SAVE_FAILED
]]
function SystemRedPoint.UpdateRedPoint(plr: Player, redName: string): (boolean, string?)
	if not _validatePlayer(plr) then
		return false, ERR_INVALID_PLAYER
	end
	if not _isKnownRedName(redName) then
		Log.warn("SystemRedPoint: 未知红点名", redName)
		return false, ERR_UNKNOWN_RED_NAME
	end

	local value = _resolveRedValue(plr, redName)
	if value == nil then
		return false, ERR_NO_SAVE_DATA
	end
	return _applyRedValue(plr, redName, value)
end

-- ========================================
-- 初始化
-- ========================================

--[[
	玩家入服时初始化红点 Folder 与各 NumberValue（只同步镜像，不重写存档）。

	@param plr Player - 刚完成存档加载的玩家
	@return nil - 玩家无效或无存档时提前返回，无返回值
]]
function SystemRedPoint.Init(plr: Player)
	if not _validatePlayer(plr) then
		return
	end

	local redPoint = _getRedData(plr)
	if not redPoint then
		return
	end

	local folder = _getFolder(plr)
	if not folder then
		return
	end

	for _, redName in ipairs(RED_POINT_INIT_LIST) do
		local value = tonumber(redPoint[redName]) or 0
		_ensureRedValue(folder, redName, value)
	end
end

return SystemRedPoint
