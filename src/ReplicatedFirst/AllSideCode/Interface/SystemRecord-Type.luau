local SystemRecord = {}

--[[
	按统计项名称读取数值
	@param plr Player - 目标玩家
	@param recordStr string - 统计项名称（与存档 Record 字段键一致）
	@return number - 统计值；不存在或无存档时返回 0
]]
function SystemRecord.GetDataByID(plr: Player, recordStr: string): number
end

--[[
	玩家入服时初始化 Record 文件夹与 NEED_SHOW 镜像
	@param plr Player - 刚完成数据加载的玩家
]]
function SystemRecord.Init(plr: Player)
end

--[[
	为所有在线玩家累加游戏时长
	@param dt number - 时间增量（秒）；由 UpdateModule 每秒传入
]]
function SystemRecord.RecordGameTime(dt: number)
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
end

--[[
	注册背包统计 Bindable 与离场缓存清理；可重复调用，仅首次生效
]]
function SystemRecord.RegisterNetWork()
end

return SystemRecord