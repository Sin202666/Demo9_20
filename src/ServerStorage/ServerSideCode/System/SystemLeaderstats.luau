--[[
	Module: SystemLeaderstats
	Description: 定时将玩家特殊货币数量同步到 Roblox 默认玩家列表（leaderstats）
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31

	功能：
	- UpdateLeaderstats：遍历在线玩家，刷新 leaderstats 下展示用 StringValue
	- 模块加载时向 UpdateModule 注册 1 秒任务（与 SystemBUFF 相同，由 UpdateManager 预加载）

	与相关模块：
	- 只写 Player 下展示镜像，不改存档、不发奖；数值来自 GetData.GetItemCountByID（服务端读 Bag/Shard）
	- 列对应 EnumMgr.ItemID.Coin（itemdataConf id=1）；仓库无玩家等级物品，不再引用不存在的 ItemID.Level
	- Roblox 默认玩家列表读 Instance.Name，无法走 TranslationHelper

	调用关系：
	- UpdateManager 预加载本模块以完成 Register；本模块无 Init
	- 需要立即刷新时可调 UpdateLeaderstats()

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SystemLeaderstats = Utils.SystemLeaderstats

	示例：
		SystemLeaderstats.UpdateLeaderstats()
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Players = Utils.Players
local EnumMgr = Utils.EnumMgr
local MathMgr = Utils.MathMgr
local InsMgr = Utils.InsMgr
local GetData = Utils.GetData
local UpdateModule = Utils.UpdateModule

-- ========================================
-- 模块定义
-- ========================================
local SystemLeaderstats = {}

-- ========================================
-- 常量定义
-- ========================================
-- Roblox 默认玩家列表只认名为 leaderstats 的子实例
local LEADERSTATS_FOLDER = "leaderstats"
local STAT_NAME = "Coin"
local STAT_ITEM_ID = EnumMgr.ItemID.Coin
local CLASS_FOLDER = "Folder"
local CLASS_STRING_VALUE = "StringValue"
-- 旧版曾用 Level 列且数据源为不存在的 ItemID.Level，创建 Coin 列时清掉以免双列
local LEGACY_STAT_LEVEL = "Level"

-- ========================================
-- 私有变量
-- ========================================
local _statValueByPlayer: { [Player]: StringValue } = {}

-- ========================================
-- 私有函数
-- ========================================

--[[
	离场时丢掉该玩家的 StringValue 缓存。

	@param plr Player - 离开的玩家
	@return nil - 无返回值
]]
local function _clearPlayerCache(plr: Player)
	_statValueByPlayer[plr] = nil
end

--[[
	获取或创建玩家 leaderstats 下的展示 StringValue（命中后缓存）。

	@param plr Player - 目标玩家；须仍在 Players 中
	@return StringValue? - 展示用 Value；玩家已离开时为 nil
]]
local function _getStatValue(plr: Player): StringValue?
	local cached = _statValueByPlayer[plr]
	if cached and cached.Parent then
		return cached
	end

	if not plr.Parent then
		_statValueByPlayer[plr] = nil
		return nil
	end

	local leaderstats = InsMgr.GetIns(LEADERSTATS_FOLDER, CLASS_FOLDER, plr)
	local leftover = leaderstats:FindFirstChild(LEGACY_STAT_LEVEL)
	if leftover then
		leftover:Destroy()
	end

	local statValue = InsMgr.GetIns(STAT_NAME, CLASS_STRING_VALUE, leaderstats) :: StringValue
	_statValueByPlayer[plr] = statValue
	return statValue
end

--[[
	刷新指定玩家的 leaderstats 展示值；值未变化时不写 Value。

	@param plr Player - 目标玩家
	@return nil - 玩家无效或已离开时提前返回
]]
local function _updateLeaderstatsForPlayer(plr: Player)
	if not plr or not plr.Parent then
		return
	end

	local statValue = _getStatValue(plr)
	if not statValue then
		return
	end

	local display = MathMgr.getNumStr(GetData.GetItemCountByID(plr, STAT_ITEM_ID))
	if statValue.Value ~= display then
		statValue.Value = display
	end
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	刷新所有在线玩家的 leaderstats 展示值。

	通常由 UpdateModule 每秒调用；也可在入包后立刻调一次。

	@return nil - 无返回值
]]
function SystemLeaderstats.UpdateLeaderstats()
	for _, plr: Player in Players:GetPlayers() do
		_updateLeaderstatsForPlayer(plr)
	end
end

-- ========================================
-- 定时任务与离场清理
-- ========================================
Players.PlayerRemoving:Connect(function(plr: Player)
	_clearPlayerCache(plr)
end)

UpdateModule.Register(UpdateModule.INTERVAL.SEC, function(_elapsed: number)
	SystemLeaderstats.UpdateLeaderstats()
end, { spawn = true })

return SystemLeaderstats