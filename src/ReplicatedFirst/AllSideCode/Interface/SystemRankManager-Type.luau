--[[
	Module: SystemRankManager-Type
	Description: SystemRankManager 类型声明（完整使用说明见 ClientSideCode/SystemModule/SystemRankManager/init.luau 文件头）
	Author: 林奥宇
	Created: 2026-06-30
	Last Modified: 2026-09-01
]]

local SystemRankManager = {}

--[[
	从 workspace 缓存刷新所有排行榜 SurfaceGui。
	无缓存或尚未 Init 出格子时静默 no-op。不写前 3 名 NumberValue。

	@return () - 无返回值
]]
function SystemRankManager.UpdateRank()
end

--[[
	榜板是否已绑定出至少一块板

	@return boolean - 已就绪为 true
]]
function SystemRankManager.IsReady(): boolean
	return false
end

--[[
	榜板就绪后回调。若已就绪则 task.defer 立即调用。

	@param callback () -> () - 就绪回调
	@return () - 无返回值
]]
function SystemRankManager.OnBoardsReady(callback: () -> ())
end

--[[
	读 workspace「前3名玩家」UserId（新表）。

	@param rankName string - 写榜键
	@return {number} - 最多 3 个 UserId；未登记或无镜像为空表
]]
function SystemRankManager.GetTop3UserIds(rankName: string): { number }
	return {}
end

--[[
	读 workspace 排行榜缓存并解码分数（新表）。

	@param rankName string - 写榜键
	@return { { userId: number, score: number } } - 解码后的条目；无缓存为空表
]]
function SystemRankManager.GetCacheEntries(rankName: string): { { userId: number, score: number } }
	return {}
end

--[[
	断开定时刷新连接与场景监听。格子与引用保留；连接断开后再次 Init 会重绑 Heartbeat。

	@return () - 无返回值
]]
function SystemRankManager.destroy()
end

--[[
	初始化排行榜格子并启动客户端定时刷新。仅客户端生效；由 RankManager 调用。
	按场景约定填充 场景/<世界>/功能/排行榜/Rank_*/Board/.../Main 与 MyRank。
	格子未就绪时再次 Init 会重试等待；已就绪则只补绑 Heartbeat。
	禁止服务端调用。

	@return () - 无返回值
]]
function SystemRankManager.Init()
end

return SystemRankManager
