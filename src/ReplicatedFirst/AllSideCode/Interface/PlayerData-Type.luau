local PlayerData = {}

--[[
	获取指定玩家的完整数据快照

	@param plr Player - 玩家实例；客户端仅允许 LocalPlayer
	@return table? - 完整数据深拷贝；客户端未收到首次同步前为 nil
]]
function PlayerData.GetPlrData(plr: Player): any?
end

--[[
	按路径读取玩家数据中的嵌套值

	@param plr Player - 玩家实例；客户端仅允许 LocalPlayer
	@param key string|{string} - 单层如 "score"，多层如 {"stats","level"}
	@return any? - 路径上的值；不存在为 nil；table 为深拷贝
]]
function PlayerData.GetPlrDataByKey(plr: Player, key: string | { string }): any?
end

--[[
	服务端专用：向指定玩家推送数据同步（全量或按路径增量）

	@param plr Player - 目标玩家
	@param key string|{string}|nil - nil 表示全量；否则为增量路径
	@param value any - 要同步的值；全量时为整张数据表；增量 nil 表示删除该路径
	@return nil - 非服务端或玩家无效时静默忽略
]]
function PlayerData.Update(plr: Player, key: string | { string }?, value: any)
end

--[[
	服务端专用：修改玩家持久化数据（委托 SystemSave.ChangeStat，内部会推送客户端）

	@param plr Player - 玩家实例；须在线且已加载会话
	@param key string|{string} - 要修改的路径
	@param value any - 新值；nil 表示删除该路径
	@return boolean - 成功为 true
	@return string? - 失败时的 errorCode（非服务端为 SERVER_ONLY）
]]
function PlayerData.ChangePlrData(plr: Player, key: string | { string }, value: any): (boolean, string?)
end

--[[
	客户端注册 PLAYER_DATA_SYNC 推送后的回调（本地缓存已更新后触发）

	@param listener (key: string|{string}|nil, value: any) -> () - 同步回调；value 为快照，禁止写回
	@return (() -> ())? - 取消监听函数；非客户端或 listener 无效时为 nil
]]
function PlayerData.ListenClientSync(listener: (key: string | { string }?, value: any) -> ()): (() -> ())?
end

--[[
	注册 PlayerData 相关 NetWork 路由（模块加载时自动调用，可重复调用）

	@return nil - 无返回值
]]
function PlayerData.RegisterNetWork()
end

return PlayerData
