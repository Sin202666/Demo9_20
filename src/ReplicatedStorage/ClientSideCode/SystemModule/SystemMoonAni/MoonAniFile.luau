--[[
	Module: MoonAniFile
	Description: SystemMoonAni 过场文件解析、场景 map 克隆摆放、时长估算
	Author: 林奥宇
	Created: 2026-08-25
	Last Modified: 2026-08-25

	功能：
	- 解析 MoonAnimator2Saves / 推断 mapName / 估算时长
	- 从 Assets/MoonAni 克隆场景并摆放（map 外包 Folder）
	- 提供 decodeMoonFile 供 MoonAniCamera 读取 Items

	仅由 SystemMoonAni 同目录模块 require(script.MoonAniFile) 使用。
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local MoonAniFile = {}

local MOON_SAVES_ROOT_NAME = "MoonAnimator2Saves"
local MOON_MAP_ASSETS_FOLDER = "MoonAni"
local MOON_ASSETS_ROOT_NAME = "Assets"
local DEFAULT_DURATION_SEC = 20
local MAX_LENGTH_AS_SECONDS = 600

export type SceneMapOpts = {
	map: Instance?,
	mapName: string?,
	mapCFrame: CFrame?,
	mapPosition: Vector3?,
	mapParent: Instance?,
}

--[[
	模块内警告输出

	@param ... any - warn 参数
	@return nil
]]
local function _warn(...: any)
	warn("[SystemMoonAni]", ...)
end

--[[
	判断是否为 Moon2Cutscene 可播放的过场实例

	@param inst Instance - 候选实例
	@return boolean - StringValue / Folder 为 true
]]
local function _isMoonAniFile(inst: Instance): boolean
	return inst:IsA("StringValue") or inst:IsA("Folder")
end

--[[
	获取过场资源根目录 ReplicatedStorage/MoonAnimator2Saves

	@return Folder? - 资源根；不存在时 nil
]]
function MoonAniFile.getSaveRoot(): Instance?
	return ReplicatedStorage:FindFirstChild(MOON_SAVES_ROOT_NAME)
end

--[[
	解析过场文件：StringValue/Folder 实例，或 Saves 下按名称查找

	@param file Instance | string - 过场实例，或 MoonAnimator2Saves 下名称
	@return Instance? - 可交给 Moon2Cutscene.new 的实例；找不到时 nil
]]
function MoonAniFile.resolveFile(file: Instance | string): Instance?
	if typeof(file) == "Instance" then
		if _isMoonAniFile(file) then
			return file
		end
		return nil
	end

	if type(file) ~= "string" or file == "" then
		return nil
	end

	local root = MoonAniFile.getSaveRoot()
	if not root then
		return nil
	end

	local child = root:FindFirstChild(file)
	if child and _isMoonAniFile(child) then
		return child
	end

	child = root:FindFirstChild(file, true)
	if child and _isMoonAniFile(child) then
		return child
	end

	return nil
end

--[[
	获取场景模型资源根 ReplicatedStorage/Assets/MoonAni

	@return Instance? - MoonAni 文件夹；不存在时 nil
]]
local function _getMapAssetRoot(): Instance?
	local assets = ReplicatedStorage:FindFirstChild(MOON_ASSETS_ROOT_NAME)
	if not assets then
		return nil
	end
	return assets:FindFirstChild(MOON_MAP_ASSETS_FOLDER)
end

--[[
	解析 Play 选项中的摆放 CFrame

	@param opts SceneMapOpts - 播放选项中的 map 相关字段
	@return CFrame? - 有效 CFrame；未提供时 nil
]]
local function _resolveMapCFrame(opts: SceneMapOpts): CFrame?
	if typeof(opts.mapCFrame) == "CFrame" then
		return opts.mapCFrame
	end
	if typeof(opts.mapPosition) == "Vector3" then
		return CFrame.new(opts.mapPosition)
	end
	return nil
end

--[[
	将 map 根实例摆放到目标 CFrame

	@param root Instance - 场景 map 根（Model / BasePart / Folder）
	@param cf CFrame - 目标位姿
	@return nil
]]
local function _applyMapTransform(root: Instance, cf: CFrame)
	if root:IsA("Model") then
		root:PivotTo(cf)
		return
	end
	if root:IsA("BasePart") then
		root.CFrame = cf
		return
	end
	local model = root:FindFirstChildWhichIsA("Model", true)
	if model then
		model:PivotTo(cf)
		return
	end
	local part = root:FindFirstChildWhichIsA("BasePart", true)
	if part then
		local offset = cf * part.CFrame:Inverse()
		for _, desc in root:GetDescendants() do
			if desc:IsA("BasePart") then
				desc.CFrame = offset * desc.CFrame
			end
		end
		return
	end
	_warn("map 无法摆放：未找到 Model/BasePart", root:GetFullName())
end

--[[
	解码 Moon 导出 StringValue 的 JSON

	@param fileInst Instance - Moon 导出文件
	@return any? - 解码表；失败 nil
]]
function MoonAniFile.decodeMoonFile(fileInst: Instance): any?
	if not fileInst:IsA("StringValue") then
		return nil
	end
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode((fileInst :: StringValue).Value)
	end)
	if not ok or type(decoded) ~= "table" then
		return nil
	end
	return decoded
end

--[[
	从 Path.InstanceNames 提取 Workspace 下第一层名字（跳过 Camera/Terrain 等）

	@param path any - Items[i].Path
	@return string? - 候选 map 名
]]
local function _workspaceChildNameFromPath(path: any): string?
	if type(path) ~= "table" then
		return nil
	end
	if path.ItemType == "Camera" then
		return nil
	end
	local names = path.InstanceNames
	if type(names) ~= "table" then
		return nil
	end
	for i, name in names do
		if name == "Workspace" then
			local child = names[i + 1]
			if type(child) == "string"
				and child ~= ""
				and child ~= "Camera"
				and child ~= "CurrentCamera"
				and child ~= "Terrain"
				and child ~= "Lighting"
				and child ~= "MoonAnimatorEffects"
			then
				return child
			end
			return nil
		end
	end
	return nil
end

--[[
	从过场文件 Items 路径推断场景模型名（Workspace 下第一层，优先命中 Assets/MoonAni）

	@param fileInst Instance - Moon 导出文件
	@return string? - mapName；解析不到时 nil
]]
function MoonAniFile.inferMapNameFromFile(fileInst: Instance): string?
	local decoded = MoonAniFile.decodeMoonFile(fileInst)
	if not decoded or type(decoded.Items) ~= "table" then
		return nil
	end

	local counts: { [string]: number } = {}
	local order: { string } = {}
	for _, item in decoded.Items do
		if type(item) == "table" then
			local name = _workspaceChildNameFromPath(item.Path)
			if name then
				if counts[name] == nil then
					table.insert(order, name)
					counts[name] = 0
				end
				counts[name] += 1
			end
		end
	end
	if #order == 0 then
		return nil
	end

	local assetRoot = _getMapAssetRoot()
	if assetRoot then
		local bestExist: string? = nil
		local bestExistCount = -1
		for _, name in order do
			if assetRoot:FindFirstChild(name) or assetRoot:FindFirstChild(name, true) then
				local c = counts[name]
				if c > bestExistCount then
					bestExist = name
					bestExistCount = c
				end
			end
		end
		if bestExist then
			return bestExist
		end
	end

	local bestName = order[1]
	local bestCount = counts[bestName] or 0
	for i = 2, #order do
		local name = order[i]
		local c = counts[name] or 0
		if c > bestCount then
			bestName = name
			bestCount = c
		end
	end
	return bestName
end

--[[
	准备 Moon2Cutscene 用的场景 map：opts.map 优先；否则从 Assets/MoonAni 克隆并摆放

	@param opts SceneMapOpts - map 相关选项
	@param fileInst Instance? - 过场文件（用于推断 mapName）
	@param errorCode { INVALID_ARGUMENT: string, MAP_NOT_FOUND: string } - 错误码表
	@return Instance? - 传给 Moon2Cutscene.new 的 map
	@return Instance? - 本模块克隆的 map（结束时销毁）；非克隆时为 nil
	@return string? - 失败错误码
]]
function MoonAniFile.prepareSceneMap(
	opts: SceneMapOpts,
	fileInst: Instance?,
	errorCode: { INVALID_ARGUMENT: string, MAP_NOT_FOUND: string }
): (Instance?, Instance?, string?)
	if opts.map then
		if typeof(opts.map) ~= "Instance" then
			return nil, nil, errorCode.INVALID_ARGUMENT
		end
		return opts.map, nil, nil
	end

	local mapName = opts.mapName
	if type(mapName) ~= "string" or mapName == "" then
		mapName = if fileInst then MoonAniFile.inferMapNameFromFile(fileInst) else nil
	end

	local mapCFrame = _resolveMapCFrame(opts)
	if not mapName or mapName == "" then
		if mapCFrame then
			_warn("无法从过场解析 mapName，请传 mapName 或检查 Items 路径含 Workspace.<模型名>")
			return nil, nil, errorCode.MAP_NOT_FOUND
		end
		return nil, nil, nil
	end

	if not mapCFrame then
		_warn("使用场景模型时需要 mapCFrame 或 mapPosition")
		return nil, nil, errorCode.INVALID_ARGUMENT
	end

	local assetRoot = _getMapAssetRoot()
	if not assetRoot then
		_warn("缺少 ReplicatedStorage/Assets/MoonAni")
		return nil, nil, errorCode.MAP_NOT_FOUND
	end

	local template = assetRoot:FindFirstChild(mapName)
	if not template then
		template = assetRoot:FindFirstChild(mapName, true)
	end
	if not template then
		_warn(string.format("MAP_NOT_FOUND: %s（路径 ReplicatedStorage/Assets/MoonAni）", mapName))
		return nil, nil, errorCode.MAP_NOT_FOUND
	end

	local parent = opts.mapParent
	if parent == nil then
		parent = Workspace
	end
	if typeof(parent) ~= "Instance" then
		return nil, nil, errorCode.INVALID_ARGUMENT
	end

	local clone = template:Clone()
	-- 保留原名：Moon 路径多为 Workspace.<mapName>...，map 等价 Workspace，子级名必须一致
	clone.Name = template.Name
	_applyMapTransform(clone, mapCFrame)

	-- Moon2Cutscene 把 map 当作 Workspace：跳过 game/Workspace 后从 map 子级查找
	local mapRoot = Instance.new("Folder")
	mapRoot.Name = "MoonAniMap_" .. template.Name
	clone.Parent = mapRoot
	mapRoot.Parent = parent

	return mapRoot, mapRoot, nil
end

--[[
	销毁本模块克隆的场景 map

	@param map Instance? - 运行时 map 实例
	@return nil
]]
function MoonAniFile.destroySpawnedMap(map: Instance?)
	if map and map.Parent then
		map:Destroy()
	end
end

--[[
	估算过场时长（秒），用于结束兜底；解析失败时返回 DEFAULT_DURATION_SEC

	@param fileInst Instance - Moon 导出文件
	@param fpsOverride number? - Play 选项覆盖的 FPS
	@return number - 秒
]]
function MoonAniFile.estimateDurationSec(fileInst: Instance, fpsOverride: number?): number
	local decoded = MoonAniFile.decodeMoonFile(fileInst)
	if type(decoded) ~= "table" then
		return DEFAULT_DURATION_SEC
	end
	local info = decoded.Information
	local fps = 60
	if type(info) == "table" then
		fps = tonumber(fpsOverride) or tonumber(info.FPS) or tonumber(info.Fps) or fps
		local durationSec = tonumber(info.Duration)
		if durationSec and durationSec > 0 then
			return durationSec
		end
		local length = tonumber(info.Length)
		if length and length > 0 then
			local asSec = length / math.max(fps, 1)
			if asSec <= MAX_LENGTH_AS_SECONDS then
				return asSec
			end
			return length
		end
		local frameCount = tonumber(info.FrameCount) or tonumber(info.TotalFrames)
		if frameCount and frameCount > 0 then
			return frameCount / math.max(fps, 1)
		end
	elseif typeof(fpsOverride) == "number" and fpsOverride > 0 then
		fps = fpsOverride
	end
	return DEFAULT_DURATION_SEC
end

return MoonAniFile
