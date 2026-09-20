local module = {}

--[[
	返回已注册红点名称列表（深拷贝，调用方改副本不影响注册表）
	@return { string } - 红点名称数组副本，如「签到红点」
]]
function module.GetRedPointNames(): { string }
end

--[[
	设置红点计数。未知名称拒绝；非数字拒绝；负数/小数钳制为 ≥0 整数。
	@param plr Player - 目标玩家；须在线且已加载存档
	@param redName string - 已注册红点名称，如「签到红点」
	@param num number - 目标计数
	@return boolean - 设置成功为 true
	@return string? - 失败时为 INVALID_PLAYER / NO_SAVE_DATA / UNKNOWN_RED_NAME / INVALID_VALUE / SAVE_FAILED
]]
function module.SetRedValue(plr: Player, redName: string, num: number): (boolean, string?)
end

--[[
	累加红点计数。结果经 Set 路径钳制为 ≥0。
	@param plr Player - 目标玩家；须在线且已加载存档
	@param redName string - 已注册红点名称
	@param addNum number? - 增量，默认 1；可为负（减到 0 为止）
	@return boolean - 累加成功为 true
	@return string? - 失败时为 INVALID_PLAYER / NO_SAVE_DATA / UNKNOWN_RED_NAME / INVALID_VALUE / SAVE_FAILED
]]
function module.AddRedValue(plr: Player, redName: string, addNum: number?): (boolean, string?)
end

--[[
	清除红点（置 0）。
	@param plr Player - 目标玩家；须在线且已加载存档
	@param redName string - 已注册红点名称
	@return boolean - 清除成功为 true
	@return string? - 失败时为 INVALID_PLAYER / NO_SAVE_DATA / UNKNOWN_RED_NAME / SAVE_FAILED
]]
function module.RemoveRedValue(plr: Player, redName: string): (boolean, string?)
end

--[[
	重算或同步指定红点到镜像。当前无业务重算时等于从存档刷镜像。
	@param plr Player - 目标玩家；须在线且已加载存档
	@param redName string - 已注册红点名称
	@return boolean - 更新成功为 true
	@return string? - 失败时为 INVALID_PLAYER / NO_SAVE_DATA / UNKNOWN_RED_NAME / SAVE_FAILED
]]
function module.UpdateRedPoint(plr: Player, redName: string): (boolean, string?)
end

--[[
	玩家入服时初始化红点 Folder 与各 NumberValue（只同步镜像，不重写存档）。
	@param plr Player - 刚完成存档加载的玩家
	@return nil - 玩家无效或无存档时提前返回，无返回值
]]
function module.Init(plr: Player)
end

return module
