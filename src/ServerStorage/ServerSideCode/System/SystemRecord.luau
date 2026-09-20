--[[
	Module: SystemRecord
	Description: 生涯统计读写、背包事件累计、玩家实例 NumberValue 镜像
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-01

	功能：
	- GetDataByID：按统计项名称读取数值（无存档或缺项返回 0）
	- Init(plr)：入服时在玩家下创建 Record 文件夹与 NEED_SHOW 镜像
	- RecordAdd / RecordCover：累加或覆盖统计项并经 PlayerData.ChangePlrData 持久化
	- RecordGetBagItem / RecordDelBagItem：背包获得/消耗映射为钻石、金币统计项
	- RegisterNetWork：注册 RECORD_ITEM_GAIN / RECORD_ITEM_REMOVE Bindable（模块加载时调用，可重复调用）
	- RecordGameTime：由 UpdateModule 每秒驱动，为在线玩家累加 RankConfig 时长字段
	- 排行榜金币/时长字段名与 RankConfig.RANK_DATA_FIELDS 对齐，勿再抄中文键

	与相关模块的关系：
	- 会话读写只经 PlayerData（内部 SystemSave.ChangeStat）；不直连 DataStore
	- Player 下 Record/NumberValue 仅为客户端可读镜像，不是发奖或排行权威
	- SystemBag 经 Bindable 通知增减；SystemRank / SystemFeedback 读 GetDataByID
	- 非时长、非成就计数的统计变更会刷新 SystemRedPoint「成就红点」
	- 结构补全在 SystemSave 加载流；本模块不做版本迁移

	调用关系：
	- PlayerManager 入服数据加载完成后调用 Init(plr)
	- UpdateManager 预加载本模块以注册秒级游戏时长定时任务
	- SystemBag payload 为数组 { Player, itemID, itemCount }（下标 1/2/3）

	加载方式（仅服务端）：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local SystemRecord = Utils.SystemRecord

	使用示例：
		local RankConfig = Utils.RankConfig
		SystemRecord.Init(player)
		SystemRecord.RecordAdd(player, "通关次数", 1)
		local playTime = SystemRecord.GetDataByID(player, RankConfig.RANK_DATA_FIELDS[RankConfig.RANK_TIME_NAME])
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local Players = Utils.Players
local Log = Utils.Log
local PlayerData = Utils.PlayerData
local EnumMgr = Utils.EnumMgr
local RankConfig = Utils.RankConfig
local SystemRedPoint = Utils.SystemRedPoint
local NetWork = Utils.NetWork
local NetMsg = Utils.NetMsg
local UpdateModule = Utils.UpdateModule

-- ========================================
-- 模块定义
-- ========================================
local SystemRecord = {}

-- ========================================
-- 常量定义
-- ========================================
local RECORD_FOLDER_NAME = EnumMgr.PlayerInst.RecordFolder
local RECORD_KEY_PLAY_TIME = RankConfig.GetRecordField(RankConfig.RANK_TIME_NAME) :: string
local RECORD_KEY_DIAMOND_GAIN = "总钻石获得"
local RECORD_KEY_COIN_GAIN = RankConfig.GetRecordField(RankConfig.RANK_GOLD_NAME) :: string
local RECORD_KEY_DIAMOND_SPEND = "总钻石花费"
local RECORD_KEY_COIN_SPEND = "总金币花费"
local RECORD_KEY_ACHIEVEMENT_COUNT = "完成多少个成就"
local RED_POINT_ACHIEVEMENT = "成就红点"

local ERROR_INVALID_PLAYER = "INVALID_PLAYER"
local ERROR_NO_RECORD_DATA = "NO_RECORD_DATA"
local ERROR_INVALID_ITEM_ID = "INVALID_ITEM_ID"
local ERROR_SAVE_FAILED = "SAVE_FAILED"

-- 需要在玩家实例下创建 NumberValue 镜像的统计项（其余项仅写存档）
local NEED_SHOW = {
	RECORD_KEY_PLAY_TIME,
}

local NEED_SHOW_SET: { [string]: boolean } = {
	[RECORD_KEY_PLAY_TIME] = true,
}

local BAG_GAIN_RECORD_KEY = {
	[EnumMgr.ItemID.Diamond] = RECORD_KEY_DIAMOND_GAIN,
	[EnumMgr.ItemID.Coin] = RECORD_KEY_COIN_GAIN,
}

local BAG_SPEND_RECORD_KEY = {
	[EnumMgr.ItemID.Diamond] = RECORD_KEY_DIAMOND_SPEND,
	[EnumMgr.ItemID.Coin] = RECORD_KEY_COIN_SPEND,
}

-- ========================================
-- 私有变量
-- ========================================
local _recordFolderByPlayer: { [Player]: Folder } = {}
local _showValueByPlayer: { [Player]: { [string]: NumberValue } } = {}
local _netRegistered = false

-- ========================================
-- 私有函数
-- ========================================

--[[
	校验玩家是否在线且有效
	@param plr any - 待校验对象；须为仍挂在 Players 下的 Player
	@return boolean - 有效在线玩家为 true
]]
local function _validatePlayer(plr: any): boolean
	return typeof(plr) == "Instance" and plr:IsA("Player") and plr:IsDescendantOf(Players)
end

--[[
	离场时丢掉该玩家的 Folder / NumberValue 缓存
	@param plr Player - 正在离开的玩家
]]
local function _clearPlayerCache(plr: Player)
	_recordFolderByPlayer[plr] = nil
	_showValueByPlayer[plr] = nil
end

--[[
	读取玩家 Record 存档表（只读，不写入）
	@param plr Player - 目标玩家；须已加载会话
	@return table? - 存档中 Record 字段；无会话或非表时为 nil
]]
local function _getRecordData(plr: Player): { [string]: number }?
	local recordData = PlayerData.GetPlrDataByKey(plr, "Record")
	if type(recordData) ~= "table" then
		return nil
	end
	return recordData
end

--[[
	持久化单个统计项（经 ChangeStat 推送客户端）
	@param plr Player - 目标玩家
	@param recordKey string - 统计项名称
	@param recordValue number - 统计值
	@return boolean - 写入成功为 true
	@return string? - 失败时的错误码
]]
local function _saveRecordData(plr: Player, recordKey: string, recordValue: number): (boolean, string?)
	local ok, err = PlayerData.ChangePlrData(plr, { "Record", recordKey }, recordValue)
	if not ok then
		Log.warn("SystemRecord: ChangePlrData 失败", plr.UserId, recordKey, err)
		return false, err or ERROR_SAVE_FAILED
	end
	return true, nil
end

--[[
	获取或创建玩家下的 Record 文件夹，并写入缓存
	@param plr Player - 目标玩家
	@return Folder - 挂载在玩家下的 Record 文件夹
]]
local function _getRecordFolder(plr: Player): Folder
	local cached = _recordFolderByPlayer[plr]
	if cached and cached.Parent == plr then
		return cached
	end

	local folder: Instance? = plr:FindFirstChild(RECORD_FOLDER_NAME)
	if not folder or not folder:IsA("Folder") then
		local newFolder = Instance.new("Folder")
		newFolder.Name = RECORD_FOLDER_NAME
		newFolder.Parent = plr
		_recordFolderByPlayer[plr] = newFolder
		return newFolder
	end

	local typedFolder = folder :: Folder
	_recordFolderByPlayer[plr] = typedFolder
	return typedFolder
end

--[[
	同步已存在的 NumberValue 镜像（仅 NEED_SHOW 项在 Init 中创建）
	@param plr Player - 目标玩家
	@param recordStr string - 统计项名称
	@param itemCount number - 统计值
]]
local function _updatePlayerValue(plr: Player, recordStr: string, itemCount: number)
	if not NEED_SHOW_SET[recordStr] then
		return
	end

	local showMap = _showValueByPlayer[plr]
	local value: NumberValue? = showMap and showMap[recordStr]
	if value and value.Parent then
		value.Value = itemCount
		return
	end

	local folder: Folder = _getRecordFolder(plr)
	local existing: NumberValue? = folder:FindFirstChild(recordStr) :: NumberValue?
	if existing and existing:IsA("NumberValue") then
		existing.Value = itemCount
		if not showMap then
			showMap = {}
			_showValueByPlayer[plr] = showMap
		end
		showMap[recordStr] = existing
	end
end

--[[
	解析背包统计 Bindable 载荷（数组下标，与 SystemBag FireBindable 一致）
	@param data any - { [1]: Player, [2]: number|string 物品 ID, [3]: number 数量 }；数量须 > 0
	@return Player? - 有效玩家；无效时为 nil
	@return number? - 物品 ID；无效时为 nil
	@return number? - 物品数量；无效时为 nil
]]
local function _parseBagRecordPayload(data: any): (Player?, number?, number?)
	if typeof(data) ~= "table" then
		return nil, nil, nil
	end

	local plr = data[1]
	local itemID = tonumber(data[2])
	local itemCount = tonumber(data[3])

	if not _validatePlayer(plr) or not itemID or not itemCount or itemCount <= 0 then
		return nil, nil, nil
	end

	return plr, itemID, itemCount
end

--[[
	写入统计项（覆盖或累加）并持久化；不直接改会话表，只经 ChangePlrData
	@param plr Player - 目标玩家；须在线且已加载存档
	@param recordStr string - 统计项名称
	@param itemCount number - 覆盖时为新值，累加时为增量
	@param isCover boolean - true 覆盖，false 累加
	@return boolean - 写入成功为 true
	@return string? - 失败时的错误码（INVALID_PLAYER / NO_RECORD_DATA / SAVE_FAILED）
]]
local function _recordData(plr: Player, recordStr: string, itemCount: number, isCover: boolean): (boolean, string?)
	if not _validatePlayer(plr) then
		return false, ERROR_INVALID_PLAYER
	end

	recordStr = tostring(recordStr)
	itemCount = tonumber(itemCount) or 0

	local recordDataTable = _getRecordData(plr)
	if not recordDataTable then
		return false, ERROR_NO_RECORD_DATA
	end

	local current = tonumber(recordDataTable[recordStr]) or 0
	local newValue = if isCover then itemCount else current + itemCount

	local saved, saveErr = _saveRecordData(plr, recordStr, newValue)
	if not saved then
		return false, saveErr
	end

	_updatePlayerValue(plr, recordStr, newValue)

	if recordStr ~= RECORD_KEY_PLAY_TIME and recordStr ~= RECORD_KEY_ACHIEVEMENT_COUNT then
		SystemRedPoint.UpdateRedPoint(plr, RED_POINT_ACHIEVEMENT)
	end

	return true, nil
end

-- ========================================
-- 公共 API
-- ========================================

--[[
	按统计项名称读取数值
	@param plr Player - 目标玩家
	@param recordStr string - 统计项名称（与存档 Record 字段键一致）
	@return number - 统计值；不存在或无存档时返回 0
]]
function SystemRecord.GetDataByID(plr: Player, recordStr: string): number
	recordStr = tostring(recordStr)
	local recordDataTable = _getRecordData(plr)
	if not recordDataTable then
		return 0
	end
	return tonumber(recordDataTable[recordStr]) or 0
end

--[[
	玩家入服时初始化 Record 文件夹与 NEED_SHOW 镜像
	@param plr Player - 刚完成数据加载的玩家
]]
function SystemRecord.Init(plr: Player)
	if not _validatePlayer(plr) then
		Log.warn("SystemRecord.Init: 无效玩家")
		return
	end

	local folder: Folder = _getRecordFolder(plr)
	local showMap = _showValueByPlayer[plr]
	if not showMap then
		showMap = {}
		_showValueByPlayer[plr] = showMap
	end

	for _, showKey in ipairs(NEED_SHOW) do
		local existing: Instance? = folder:FindFirstChild(showKey)
		local numberValue: NumberValue
		if existing and existing:IsA("NumberValue") then
			numberValue = existing :: NumberValue
		else
			numberValue = Instance.new("NumberValue")
			numberValue.Name = showKey
			numberValue.Parent = folder
		end
		numberValue.Value = SystemRecord.GetDataByID(plr, showKey)
		showMap[showKey] = numberValue
	end
end

--[[
	为所有在线玩家累加游戏时长
	@param dt number - 时间增量（秒）；由 UpdateModule 每秒传入
]]
function SystemRecord.RecordGameTime(dt: number)
	for _, plr: Player in Players:GetPlayers() do
		SystemRecord.RecordAdd(plr, RECORD_KEY_PLAY_TIME, dt)
	end
end

--[[
	记录背包获得物品的统计（仅钻石/金币映射为统计项，其余物品直接成功返回）
	@param plr Player - 目标玩家
	@param itemId string | number - 物品 ID（EnumMgr.ItemID）
	@param itemCount number - 获得数量
	@return boolean - 写入成功或未追踪物品时为 true
	@return string? - 失败时的错误码
]]
function SystemRecord.RecordGetBagItem(plr: Player, itemId: string | number, itemCount: number): (boolean, string?)
	local parsedId = tonumber(itemId)
	if not parsedId then
		return false, ERROR_INVALID_ITEM_ID
	end

	local recordKey = BAG_GAIN_RECORD_KEY[parsedId]
	if not recordKey then
		return true, nil
	end

	return SystemRecord.RecordAdd(plr, recordKey, itemCount)
end

--[[
	记录背包消耗物品的统计（仅钻石/金币映射为统计项，其余物品直接成功返回）
	@param plr Player - 目标玩家
	@param itemId string | number - 物品 ID（EnumMgr.ItemID）
	@param itemCount number - 消耗数量
	@return boolean - 写入成功或未追踪物品时为 true
	@return string? - 失败时的错误码
]]
function SystemRecord.RecordDelBagItem(plr: Player, itemId: string | number, itemCount: number): (boolean, string?)
	local parsedId = tonumber(itemId)
	if not parsedId then
		return false, ERROR_INVALID_ITEM_ID
	end

	local recordKey = BAG_SPEND_RECORD_KEY[parsedId]
	if not recordKey then
		return true, nil
	end

	return SystemRecord.RecordAdd(plr, recordKey, itemCount)
end

--[[
	覆盖统计值
	@param plr Player - 目标玩家；须在线且已加载存档
	@param recordStr string - 统计项名称
	@param itemCount number - 新统计值
	@return boolean - 写入成功为 true
	@return string? - 失败时的错误码
]]
function SystemRecord.RecordCover(plr: Player, recordStr: string, itemCount: number): (boolean, string?)
	return _recordData(plr, recordStr, itemCount, true)
end

--[[
	累加统计值
	@param plr Player - 目标玩家；须在线且已加载存档
	@param recordStr string - 统计项名称
	@param itemCount number - 增量
	@return boolean - 写入成功为 true
	@return string? - 失败时的错误码
]]
function SystemRecord.RecordAdd(plr: Player, recordStr: string, itemCount: number): (boolean, string?)
	return _recordData(plr, recordStr, itemCount, false)
end

--[[
	注册背包统计 Bindable 与离场缓存清理；可重复调用，仅首次生效
]]
function SystemRecord.RegisterNetWork()
	if _netRegistered then
		return
	end
	_netRegistered = true

	NetWork.RegisterBindableEvent(NetMsg.RECORD_ITEM_GAIN, function(data: any)
		local plr, itemID, itemCount = _parseBagRecordPayload(data)
		if not plr then
			Log.warn("SystemRecord: RECORD_ITEM_GAIN 载荷无效")
			return
		end
		SystemRecord.RecordGetBagItem(plr, itemID :: number, itemCount :: number)
	end)

	NetWork.RegisterBindableEvent(NetMsg.RECORD_ITEM_REMOVE, function(data: any)
		local plr, itemID, itemCount = _parseBagRecordPayload(data)
		if not plr then
			Log.warn("SystemRecord: RECORD_ITEM_REMOVE 载荷无效")
			return
		end
		SystemRecord.RecordDelBagItem(plr, itemID :: number, itemCount :: number)
	end)

	Players.PlayerRemoving:Connect(_clearPlayerCache)
end

-- ========================================
-- 模块加载时注册通信与定时任务
-- ========================================
SystemRecord.RegisterNetWork()

UpdateModule.Register(UpdateModule.INTERVAL.SEC, function(elapsed: number)
	SystemRecord.RecordGameTime(elapsed)
end, { spawn = true })

return SystemRecord