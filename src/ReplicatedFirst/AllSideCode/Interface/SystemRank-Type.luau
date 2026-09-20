--[[
	Module: SystemRank-Type
	Description: SystemRank 类型声明（完整使用说明见 ServerSideCode/System/SystemRank 文件头）
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-01
]]

local SystemRank = {}

--[[
	上传一名玩家各榜分数至 OrderedDataStore。先快照 Record 再写。

	@param player Player - 目标玩家
	@return () - 无返回值；失败见 Log
]]
function SystemRank.UploadPlayer(player: Player)
end

--[[
	上传所有在线玩家的排行榜分数至 OrderedDataStore
	原始分 <= 0 跳过；单条失败只 Log，不中断其余玩家/其余榜

	@return nil - 批量写榜无汇总返回值；失败见 Log
]]
function SystemRank.UploadPlayerRankInfo()
end

--[[
	读 workspace「前3名玩家」镜像 UserId（新表，不含 0）。

	@param rankName string - 写榜键
	@return {number} - 最多 3 个 UserId；未登记或无镜像为空表
]]
function SystemRank.GetTop3UserIds(rankName: string): { number }
	return {}
end

--[[
	读 workspace 排行榜缓存并解码分数（新表，非 NumberValue 引用）。

	@param rankName string - 写榜键
	@return { { userId: number, score: number } } - { userId, score }；无缓存或未登记为空表
]]
function SystemRank.GetCacheEntries(rankName: string): { { userId: number, score: number } }
	return {}
end

--[[
	拉取各榜排序页并发布至 workspace 缓存
	单榜失败只 Log，不中断其余榜

	@return nil - 批量拉榜无汇总返回值；失败见 Log
]]
function SystemRank.UpdateRank()
end

--[[
	注册排行榜写榜与缓存发布定时任务，由 UpdateManager 在 Start 前调用一次。
	同时确保 RankTemp 在 ReplicatedStorage 对客户端可见。重复调用幂等。

	@return nil - 已初始化时直接返回
]]
function SystemRank.Init()
end

return SystemRank
