local DataCache = {}

export type InitOpts = {
	cacheRoot: Instance?,
	clearNameOnSweep: boolean?,
	registerSweep: boolean?,
}

--[[
	初始化缓存根目录；服务端由 UpdateManager 注入并注册定时清扫

	@param opts InitOpts? - 可选配置：
		cacheRoot Instance? - 缓存 Folder 父级；缺省时服为 ServerStorage、客为 ReplicatedStorage
		clearNameOnSweep boolean? - true 时 ClearCache 同时清名字；缺省与是否存在 ServerStorage 一致
		registerSweep boolean? - true 时向 UpdateModule 注册清扫；缺省与是否存在 ServerStorage 一致
	@return nil
]]
function DataCache.Init(opts: InitOpts?)
end

--[[
	获取玩家名字（带缓存）

	@param userId number - Roblox 用户 ID；非正数时返回占位符
	@return string - 玩家昵称；无法获取时为 "???"
]]
function DataCache.GetPlrName(userId: number): string
end

--[[
	获取玩家头像 URL（带缓存）

	@param userId number - Roblox 用户 ID；非正数时返回空字符串
	@return string - HeadShot 60x60 头像 URL；失败时为空字符串
]]
function DataCache.GetPortrait(userId: number): string
end

--[[
	检查头像缓存是否过期并异步刷新（先拉成功再写时间戳）

	@param userId number - Roblox 用户 ID
	@return nil
]]
function DataCache.UpdatePortrait(userId: number)
end

--[[
	清理本轮未使用的缓存条目

	@return nil
]]
function DataCache.ClearCache()
end

return DataCache
