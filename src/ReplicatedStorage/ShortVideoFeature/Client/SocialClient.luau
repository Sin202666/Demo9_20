--[[
	Module: SocialClient
	Description: 客户端 Remote 封装；视频赞/评论赞/发评分冷却；暴露 Is*Cooling 供 UI 先反馈再决定是否发网
	Author: 林奥宇
	Created: 2026-08-13
	Last Modified: 2026-08-14
]]

local Remotes = require(script.Parent.Parent.Shared.Remotes)
local Constants = require(script.Parent.Parent.Shared.Constants)

local SocialClient = {}

local _folder: Folder? = nil
local _videoLikeCdUntil = 0
local _commentLikeCdUntil = 0
local _postCdUntil = 0

--[[
	绑定 Remotes Folder
	@param folder Folder - Remotes
]]
function SocialClient.Bind(folder: Folder)
	_folder = folder
end

local function get(name: string): Instance
	assert(_folder, "SocialClient not bound")
	return _folder:WaitForChild(name)
end

--[[
	冷却未结束则返回 RATE_LIMIT 回包
	@param untilClock number - os.clock 截止时刻
	@return any? - 限流回包或 nil（可继续）
]]
local function rateLimitIfCooling(untilClock: number): any?
	if os.clock() < untilClock then
		return { ok = false, err = Constants.ERROR.RATE_LIMIT }
	end
	return nil
end

--[[
	请求片单
]]
function SocialClient.RequestList()
	(get("RequestList") :: RemoteEvent):FireServer()
end

--[[
	监听片单更新
	@param cb (payload) -> () - 回调
	@return RBXScriptConnection
]]
function SocialClient.OnListUpdated(cb: (any) -> ()): RBXScriptConnection
	return (get("ListUpdated") :: RemoteEvent).OnClientEvent:Connect(cb)
end

--[[
	上报观看进度（W3）
	@param videoId string - 业务 id
	@param playedSec number - 已播秒
	@param durationSec number? - 时长
	@param ended boolean - 是否播完
]]
function SocialClient.ReportWatchProgress(videoId: string, playedSec: number, durationSec: number?, ended: boolean)
	(get("ReportWatchProgress") :: RemoteEvent):FireServer(videoId, playedSec, durationSec, ended)
end

--[[
	取视频状态
	@param videoId string - 业务 id
	@return any - 回包
]]
function SocialClient.GetVideoState(videoId: string): any
	return (get("GetVideoState") :: RemoteFunction):InvokeServer(videoId)
end

--[[
	拉评论页（hot=赞序 / newest=时间序；cursor 为 { score, cid } 或 nil）
	@param videoId string - 业务 id
	@param cursor any? - 上一页游标
	@param pageSize number? - 页大小
	@param sortMode string? - Constants.COMMENT_SORT；缺省 hot
	@return any - 回包
]]
function SocialClient.FetchComments(videoId: string, cursor: any?, pageSize: number?, sortMode: string?): any
	local mode = sortMode or Constants.DEFAULT_COMMENT_SORT
	return (get("FetchComments") :: RemoteFunction):InvokeServer(videoId, cursor, pageSize, mode)
end

--[[
	视频赞客户端冷却中？
	@return boolean - true 表示应跳过网络请求（可只播本地轻反馈）
]]
function SocialClient.IsVideoLikeCooling(): boolean
	return os.clock() < _videoLikeCdUntil
end

--[[
	评论赞客户端冷却中？
	@return boolean - true 表示应跳过网络请求
]]
function SocialClient.IsCommentLikeCooling(): boolean
	return os.clock() < _commentLikeCdUntil
end

--[[
	切换视频赞（独立冷却）
	@param videoId string - 业务 id
	@return any - 回包；冷却中 ok=false err=RATE_LIMIT
]]
function SocialClient.ToggleVideoLike(videoId: string): any
	local cd = Constants.CLIENT_VIDEO_LIKE_CD_SEC or Constants.CLIENT_LIKE_CD_SEC
	local blocked = rateLimitIfCooling(_videoLikeCdUntil)
	if blocked then
		return blocked
	end
	_videoLikeCdUntil = os.clock() + cd
	return (get("ToggleVideoLike") :: RemoteFunction):InvokeServer(videoId)
end

--[[
	切换评论赞（独立冷却，不与视频赞互挡）
	@param videoId string - 业务 id
	@param cid string - 评论 id
	@return any - 回包；冷却中 ok=false err=RATE_LIMIT
]]
function SocialClient.ToggleCommentLike(videoId: string, cid: string): any
	local cd = Constants.CLIENT_COMMENT_LIKE_CD_SEC or Constants.CLIENT_LIKE_CD_SEC
	local blocked = rateLimitIfCooling(_commentLikeCdUntil)
	if blocked then
		return blocked
	end
	_commentLikeCdUntil = os.clock() + cd
	return (get("ToggleCommentLike") :: RemoteFunction):InvokeServer(videoId, cid)
end

--[[
	发评（3s 客户端冷却）
	@param videoId string - 业务 id
	@param text string - 正文
	@return any - 回包；冷却中 ok=false err=RATE_LIMIT
]]
function SocialClient.PostComment(videoId: string, text: string): any
	local blocked = rateLimitIfCooling(_postCdUntil)
	if blocked then
		return blocked
	end
	_postCdUntil = os.clock() + Constants.CLIENT_POST_COMMENT_CD_SEC
	return (get("PostComment") :: RemoteFunction):InvokeServer(videoId, text)
end

return SocialClient
