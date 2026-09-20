--[[
	Module: MoonAniCamera
	Description: SystemMoonAni 镜头对齐：CameraStartCF 偏移烘焙与开播相机
	Author: 林奥宇
	Created: 2026-08-25
	Last Modified: 2026-08-25

	仅由 SystemMoonAni/init 通过 require(script.MoonAniCamera) 使用。
]]

local Workspace = game:GetService("Workspace")

local MoonAniFile = require(script.Parent.MoonAniFile)

local MoonAniCamera = {}

local CAMERA_START_PART_NAME = "CameraStartCF"

--[[
	判断 Moon Path 是否为摄像机轨

	@param path any - Items[i].Path
	@return boolean - 是否 Camera
]]
local function _isCameraPath(path: any): boolean
	if type(path) ~= "table" then
		return false
	end
	if path.ItemType == "Camera" then
		return true
	end
	local names = path.InstanceNames
	if type(names) == "table" then
		for _, n in names do
			if n == "Camera" or n == "CurrentCamera" or n == "cutscene_camera" then
				return true
			end
		end
	end
	return false
end

--[[
	查找过场文件中 Camera 条目对应的子 Folder 索引

	@param fileInst Instance - Moon 导出 StringValue
	@return number? - Items 索引（与子 Folder.Name 一致）
]]
local function _findCameraItemIndex(fileInst: Instance): number?
	local decoded = MoonAniFile.decodeMoonFile(fileInst)
	if not decoded or type(decoded.Items) ~= "table" then
		return nil
	end
	for index, item in decoded.Items do
		if type(item) == "table" and _isCameraPath(item.Path) then
			local num = tonumber(index)
			if num then
				return num
			end
		end
	end
	return nil
end

--[[
	读取属性 Folder 下最早一帧的 CFrame（无关键帧则用 default）

	@param cframeProp Instance - 名为 CFrame 的属性容器
	@return CFrame? - 第一帧位姿
]]
local function _readFirstCFrameFromProp(cframeProp: Instance): CFrame?
	local earliestFrame: number? = nil
	local earliestValue: CFrame? = nil

	for _, keyframe in cframeProp:GetChildren() do
		local frame = tonumber(keyframe.Name)
		if not frame then
			continue
		end
		local values = keyframe:FindFirstChild("Values")
		if not values then
			continue
		end
		for _, entry in values:GetChildren() do
			local sub = tonumber(entry.Name) or 0
			local total = frame + sub
			local value = (entry :: any).Value
			if typeof(value) == "CFrame" then
				if earliestFrame == nil or total < earliestFrame then
					earliestFrame = total
					earliestValue = value
				end
			end
		end
	end

	if earliestValue then
		return earliestValue
	end

	local defaultInst = cframeProp:FindFirstChild("default")
	if defaultInst then
		local value = (defaultInst :: any).Value
		if typeof(value) == "CFrame" then
			return value
		end
	end
	return nil
end

--[[
	读取指定 Items 索引的 CFrame 第一帧

	@param fileInst Instance - Moon 导出文件
	@param itemIndex number - Items 索引
	@return CFrame? - 第一帧
]]
local function _getItemFirstCFrame(fileInst: Instance, itemIndex: number): CFrame?
	local objFolder = fileInst:FindFirstChild(tostring(itemIndex))
	if not objFolder then
		return nil
	end
	local cframeProp = objFolder:FindFirstChild("CFrame")
	if not cframeProp then
		return nil
	end
	return _readFirstCFrameFromProp(cframeProp)
end

--[[
	从 Moon 导出文件读取摄像机第一帧 CFrame

	@param fileInst Instance - MoonAnimator2Saves 下 StringValue
	@return CFrame? - 第一帧；无 Camera 轨时 nil
]]
local function _getCameraFirstFrame(fileInst: Instance): CFrame?
	local index = _findCameraItemIndex(fileInst)
	if not index then
		return nil
	end
	return _getItemFirstCFrame(fileInst, index)
end

--[[
	收集 Attachment 类型 Items 下标（相对父级 CFrame，不可套世界偏移）

	@param fileInst Instance - Moon 导出文件
	@return { [number]: boolean } - 需跳过的索引集
]]
local function _getAttachmentItemIndexSet(fileInst: Instance): { [number]: boolean }
	local skip: { [number]: boolean } = {}
	local decoded = MoonAniFile.decodeMoonFile(fileInst)
	if not decoded or type(decoded.Items) ~= "table" then
		return skip
	end
	for itemIndex, item in decoded.Items do
		local path = type(item) == "table" and item.Path or nil
		local itemType = type(path) == "table" and path.ItemType or nil
		if itemType == "Attachment" then
			local num = tonumber(itemIndex)
			if num then
				skip[num] = true
			end
		end
	end
	return skip
end

--[[
	递归给 CFrameValue 应用偏移；跳过 Rig 与 Attachment item

	@param parent Instance - 根节点
	@param offset CFrame - 刚体偏移
	@param skipItemIndexes { [number]: boolean }? - 跳过的 Items 下标
	@param underSkippedItem boolean? - 是否已在跳过的 item 下
	@return nil
]]
local function _applyOffsetToCFrameValues(
	parent: Instance,
	offset: CFrame,
	skipItemIndexes: { [number]: boolean }?,
	underSkippedItem: boolean?
)
	if parent.Name == "Rig" then
		return
	end
	local skipped = underSkippedItem == true
	for _, child in parent:GetChildren() do
		local childSkipped = skipped
		if not childSkipped and skipItemIndexes then
			local idx = tonumber(child.Name)
			if idx and skipItemIndexes[idx] then
				childSkipped = true
			end
		end
		if not childSkipped then
			local ok, val = pcall(function()
				return (child :: any).Value
			end)
			if ok and typeof(val) == "CFrame" then
				(child :: any).Value = offset * val
			end
		end
		if child.Name ~= "Rig" then
			_applyOffsetToCFrameValues(child, offset, skipItemIndexes, childSkipped)
		end
	end
end

--[[
	从已摆放的动画模型第一层子节点读取 CameraStartCF Part 的世界 CFrame

	@param sceneMap Instance? - map 根
	@return CFrame? - 定位 Part 世界位姿；找不到时 nil
]]
local function _findCameraStartCFrame(sceneMap: Instance?): CFrame?
	if not sceneMap then
		return nil
	end

	local function readFromModel(model: Instance): CFrame?
		local marker = model:FindFirstChild(CAMERA_START_PART_NAME)
		if marker and marker:IsA("BasePart") then
			return marker.CFrame
		end
		return nil
	end

	local direct = readFromModel(sceneMap)
	if direct then
		return direct
	end

	for _, child in sceneMap:GetChildren() do
		local cf = readFromModel(child)
		if cf then
			return cf
		end
	end
	return nil
end

--[[
	开播前将本地相机切到 Scriptable 并设到目标位姿

	@param worldCf CFrame - 世界空间相机位姿
	@return nil
]]
local function _applyStartupCamera(worldCf: CFrame)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = worldCf
	camera.Focus = worldCf
end

--[[
	按 CameraStartCF 对齐过场文件：必要时克隆并烘焙 CFrame 偏移

	@param fileInst Instance - 原始过场文件
	@param sceneMap Instance? - 已摆放场景 map
	@return Instance - 交给 Moon2Cutscene.new 的文件实例
	@return Instance? - 若克隆了文件则返回克隆体（结束时销毁）
]]
function MoonAniCamera.prepareAlignedPlayFile(fileInst: Instance, sceneMap: Instance?): (Instance, Instance?)
	local playFile: Instance = fileInst
	local playFileClone: Instance? = nil
	local firstCam = _getCameraFirstFrame(fileInst)
	local cameraRef = _findCameraStartCFrame(sceneMap)
	if firstCam and cameraRef then
		local offset = cameraRef * firstCam:Inverse()
		_applyStartupCamera(cameraRef)

		playFileClone = fileInst:Clone()
		playFile = playFileClone
		local skipAttachmentIndexes = _getAttachmentItemIndexSet(playFile)
		_applyOffsetToCFrameValues(playFile, offset, skipAttachmentIndexes, false)
	elseif cameraRef and not firstCam then
		_applyStartupCamera(cameraRef)
	end
	return playFile, playFileClone
end

return MoonAniCamera
