--[[
	Module: Remotes
	Description: 确保 ShortVideoFeature 包内 Remotes 存在；服务端创建，客户端等待
	Author: 林奥宇
	Created: 2026-08-13
	Last Modified: 2026-08-13
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = {}

local FOLDER_NAME = "Remotes"
local SPECS = {
	ListUpdated = "RemoteEvent",
	RequestList = "RemoteEvent",
	ReportWatchProgress = "RemoteEvent",
	GetVideoState = "RemoteFunction",
	FetchComments = "RemoteFunction",
	ToggleVideoLike = "RemoteFunction",
	ToggleCommentLike = "RemoteFunction",
	PostComment = "RemoteFunction",
}

--[[
	获取功能根 Folder
	@return Folder - ShortVideoFeature
]]
local function getFeatureFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild("ShortVideoFeature")
	if not folder then
		error("[ShortVideoFeature] ReplicatedStorage.ShortVideoFeature missing")
	end
	return folder :: Folder
end

--[[
	确保 Remotes 子节点就绪（服务端调用）
	@return Folder - Remotes 文件夹
]]
function Remotes.Ensure(): Folder
	local feature = getFeatureFolder()
	local folder = feature:FindFirstChild(FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = feature
	end
	for name, className in pairs(SPECS) do
		local child = folder:FindFirstChild(name)
		if not child then
			child = Instance.new(className)
			child.Name = name
			child.Parent = folder
		elseif child.ClassName ~= className then
			child:Destroy()
			child = Instance.new(className)
			child.Name = name
			child.Parent = folder
		end
	end
	return folder :: Folder
end

--[[
	等待 Remotes 就绪（客户端）
	@return Folder - Remotes 文件夹
]]
function Remotes.Wait(): Folder
	local feature = getFeatureFolder()
	local folder = feature:WaitForChild(FOLDER_NAME, 30)
	if not folder then
		error("[ShortVideoFeature] Remotes folder timeout")
	end
	for name, _ in pairs(SPECS) do
		folder:WaitForChild(name, 10)
	end
	return folder :: Folder
end

--[[
	取得命名 Remote（服务端用 Ensure 后）
	@param name string - 节点名
	@return Instance - RemoteEvent 或 RemoteFunction
]]
function Remotes.Get(name: string): Instance
	local folder = Remotes.Ensure()
	local child = folder:FindFirstChild(name)
	if not child then
		error("[ShortVideoFeature] remote missing: " .. name)
	end
	return child
end

return Remotes
