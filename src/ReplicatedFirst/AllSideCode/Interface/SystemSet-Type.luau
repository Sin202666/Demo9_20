local SystemSet = {}

--[[
	将存档 Setting 同步到 player.Setting 下同名 NumberValue
	@param plr Player - 目标玩家
	@return nil - 玩家无效或无存档时提前返回
]]
function SystemSet.UpdateValue(plr: Player)
end

--[[
	玩家入服时创建设置实例并应用存档值
	@param plr Player - 刚完成数据加载的玩家
	@return nil - 玩家无效时提前返回
]]
function SystemSet.Init(plr: Player)
end

--[[
	变更单项设置并写回存档
	@param plr Player - 目标玩家
	@param setName string - settingConf.ShowName
	@param setValue number | string - 新设置值（Remote 可能传字符串）
	@return boolean - 变更成功为 true
	@return string? - 失败时为 EnumMgr.SetErr.*
]]
function SystemSet.ChangeSet(plr: Player, setName: string, setValue: number | string): (boolean, string?)
end

--[[
	注册设置相关 RemoteFunction（SETTING_CHANGE）并配置限频
	@return nil - 无返回值
]]
function SystemSet.RegisterNetWork()
end

return SystemSet
