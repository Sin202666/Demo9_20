local module = {}

--[[
	初始化玩家数据
	@param plr Player - 玩家对象
	@return boolean, boolean? - 是否成功，是否为新玩家
]]
function module.InitialPlayerData(plr: Player): (boolean, boolean?)
end

--[[
	获取玩家数据快照（深拷贝）
	@param plr Player? - 玩家对象；省略时返回全部在线会话快照
	@return table? - 传入 plr 时为该玩家存档深拷贝；省略时为 { [playerId]: 存档拷贝 }，仅服内使用
]]
function module.GetStat(plr: Player?): any
end

--[[
	修改玩家数据
	@param plr Player - 玩家对象；须已加载会话
	@param statName string|{string} - 顶层键或嵌套路径，第一段须为 PLAYER_META_DATA 键
	@param value any - 新值；nil 删除路径；table 深拷贝写入；须可 DataStore 序列化
	@return boolean, string? - 成功 true；失败 false 与 INVALID_PLAYER / NO_SESSION_DATA / UNKNOWN_STAT_KEY / INVALID_STAT_PATH / UNSERIALIZABLE_VALUE
]]
function module.ChangeStat(plr: Player, statName: string | { string }, value: any): (boolean, string?)
end

--[[
	玩家离开时保存
	@param plr Player - 玩家对象
	@return nil
]]
function module.PlayerLeaveSave(plr: Player)
end

--[[
	交易时保存
	@param plr Player - 玩家对象
	@return boolean - 是否保存成功
]]
function module.TradeSave(plr: Player): boolean
end

--[[
	自动保存所有在线玩家数据
	@return nil - 无返回值；失败玩家由内部 Log 记录
]]
function module.AutoSave()
end

--[[
	注册玩家会话自动保存定时任务，由 UpdateManager 在 Start 前调用一次
	@return nil
]]
function module.Init()
end

return module
