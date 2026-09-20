local SystemBUFF = {}

--[[
	更新所有玩家的 BUFF 倒计时

	@param dt number - 时间增量（秒）
	@return nil
]]
function SystemBUFF.UpdateBuff(dt: number)
end

--[[
	添加或叠加 BUFF

	@param plr Player - 目标玩家
	@param buffID string | number - buffdataConf 配置 ID
	@param addTime number - 添加时长（分钟）；负数表示永久
	@return boolean, string? - 成功 true；失败 false 与 errorCode
]]
function SystemBUFF.AddBUFF(plr: Player, buffID: string | number, addTime: number): (boolean, string?)
end

--[[
	将存档 buff 同步到 Player.BUFF 实例树

	@param plr Player - 目标玩家
	@return nil
]]
function SystemBUFF.UpdateBuffValue(plr: Player)
end

--[[
	玩家入服时初始化 BUFF 实例镜像

	@param plr Player - 目标玩家
	@return nil
]]
function SystemBUFF.Init(plr: Player)
end

return SystemBUFF
