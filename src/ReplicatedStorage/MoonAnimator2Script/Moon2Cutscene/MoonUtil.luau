--[[
	MoonAnimator2 工具函数模块
	提供对象查找、缓动函数获取等工具函数
]]

local module = {}
local easingFunctions = require(script.Parent.easingFunctions)
local effects = script.Parent.Effects

-- 初始化效果对象
local _, _, vignette = require(effects.vignette)()
vignette.ImageTransparency = 1

local effects = {
	Letterbox = require(effects.letterbox)(),
	Vignette = vignette,
	["Screen Cover"] = require(effects.screen_cover)(),
	["Subtitles"] = require(effects.subtitle)()
}

local Lighting = game:GetService("Lighting")

--[[
	路径是否指向 Lighting（含误写成 Workspace.Lighting）

	@param names { string }? - InstanceNames
	@param itemType string? - ItemType
	@return boolean
]]
local function isLightingPath(names: any, itemType: string?): boolean
	if itemType == "Lighting" then
		return true
	end
	if type(names) ~= "table" then
		return false
	end
	-- game.Lighting...
	if names[2] == "Lighting" then
		return true
	end
	-- 误导出：game.Workspace.Lighting...
	if names[2] == "Workspace" and names[3] == "Lighting" then
		return true
	end
	return false
end

--[[
	解析到 game.Lighting（或其后子级）；Workspace.Lighting 一律映射到 Lighting

	@param path table - Path
	@return Instance? - Lighting 或子实例
]]
local function resolveLightingObject(path: table): Instance?
	local names = path.InstanceNames
	local obj: Instance = Lighting
	if type(names) ~= "table" then
		return obj
	end

	local startIdx = 3
	if names[2] == "Workspace" and names[3] == "Lighting" then
		startIdx = 4
	elseif names[2] == "Lighting" then
		startIdx = 3
	else
		return obj
	end

	for i = startIdx, #names do
		local n = names[i]
		local expectedType = path.InstanceTypes and path.InstanceTypes[i]
		local found: Instance? = nil
		for _, v in obj:GetChildren() do
			if v.Name == n then
				if type(expectedType) ~= "string" or expectedType == "" or v:IsA(expectedType) then
					found = v
					break
				end
			end
		end
		if not found then
			return nil
		end
		obj = found
	end
	return obj
end

--[[
	根据路径查找对象
	@param path: table - 包含 InstanceNames 和 InstanceTypes 的路径表
	@param map: Instance? - 可选的映射对象（用于限制搜索范围）
	@return Instance? - 找到的对象，如果未找到则返回 nil
]]
function module.getObjectFromPath(path: table, map)

	-- 特殊处理：摄像机
	if path.ItemType and path.ItemType == "Camera" then
		return workspace.CurrentCamera
	end

	-- Lighting：含误写的 game.Workspace.Lighting → 一律改写到 game.Lighting
	if isLightingPath(path.InstanceNames, path.ItemType) then
		return resolveLightingObject(path)
	end

	-- 特殊处理：MoonAnimator 效果对象
	if path.InstanceNames[3] == "MoonAnimatorEffects" then
		if effects[path.InstanceNames[4]] then
			return effects[path.InstanceNames[4]]
		end
	end

	-- Workspace 路径从 map 解析；其它从 game 完整解析
	local secondName = path.InstanceNames and path.InstanceNames[2]
	local useMapRoot = map ~= nil and secondName == "Workspace"
	local obj = if useMapRoot then map else game
	local skipCount = if useMapRoot then 2 else 1

	for i, n in path.InstanceNames do
		if i <= skipCount then
			continue
		end

		local hasNotFound = true
		local expectedType = path.InstanceTypes and path.InstanceTypes[i]

		for _, v in obj:GetChildren() do
			if v.Name == n then
				local typeOk = type(expectedType) ~= "string" or expectedType == "" or v:IsA(expectedType)
				-- Folder ↔ Model 容器互换
				if not typeOk and expectedType == "Folder" and v:IsA("Model") then
					typeOk = true
				elseif not typeOk and expectedType == "Model" and v:IsA("Folder") then
					typeOk = true
				end
				if typeOk then
					obj = v
					hasNotFound = nil
					break
				end
			end
		end

		if hasNotFound then
			return
		end
	end

	return obj
end

--[[
	查找第一个匹配类型和名称的后代对象
	@param a: string - 对象类型（如 "BasePart"）
	@param name: string - 对象名称
	@param ancestor: Instance - 祖先对象
	@return Instance? - 找到的对象
]]
local function findFirstDescendantWhichIsAOfName(a: string, name: string, ancestor: Instance)
	for _, v in ancestor:GetDescendants() do
		if v:IsA(a) and v.Name == name then
			return v
		end
	end
end

--[[
	根据名称获取骨骼中的 Motor6D 关节
	@param rig: Instance - 骨骼对象
	@param name: string - 关节路径（用点分隔）
	@return Motor6D? - 找到的关节
]]
function module.getMotor(rig, name: string): Motor6D?
	if not rig then
		return nil
	end

	local path = string.split(name, ".")
	local obj = findFirstDescendantWhichIsAOfName("BasePart", path[#path], rig)
	if not obj then
		return nil
	end

	-- 查找连接到该对象的 Motor6D
	for _, v: Instance in rig:GetDescendants() do
		if v:IsA("Motor6D") and v.Part1 and v.Part1.Name == obj.Name then
			return v
		end
	end
end

--[[
	获取缓动函数
	@param ease: {string}? - 缓动数据 {类型, 方向}
	@return function - 缓动函数
]]
function module.getEase(ease: {string}?)
	ease = ease or {}
	ease[1] = ease[1] or "Linear"
	ease[2] = ease[2] or ""

	return easingFunctions[ease[1] .. ease[2]]
end

--[[
	获取当前时间对应的关键帧
	@param timeElapsed: number - 已过去的时间（帧数）
	@param keyframes: keyframes - 关键帧数据
	@return table, keyframeData?, number, keyframeData?, number - 排序后的帧列表，上一个关键帧，上一个帧号，下一个关键帧，下一个帧号
]]
function module.getFrames(timeElapsed: number, keyframes: keyframes)
	local orderedFrames = {}
	for frame in keyframes do
		if tonumber(frame) then
			table.insert(orderedFrames, frame)
		end
	end

	local flast, fnext
	table.sort(orderedFrames)

	-- 查找当前时间对应的关键帧区间
	for index, frame in orderedFrames do
		if frame > timeElapsed then
			flast, fnext = index - 1, index
			break
		end
	end

	flast, fnext = orderedFrames[flast], orderedFrames[fnext]
	return orderedFrames,
	keyframes[flast], flast or 0,
	keyframes[fnext], fnext
end

--[[
	获取所有关键帧数据（用于重置）
	@param self: cutsceneType
	@return table - 包含 Rig 和 Properties 的关键帧数据
]]
function module.getKeyFrames(self)
	local f = {Rig = {}, Properties = {}}

	for objIndex: number, properties: properties in self.objs do
		for property: string, keyframes: keyframes in properties do
			if property == "Rig" then
				-- 处理骨骼关节
				for layerInd, layer in keyframes do
					for jointKey, keyframes: keyframes in layer do
						local joint = module.getMotor(self.instances[objIndex], jointKey)
						f.Rig[joint] = keyframes
					end
				end

				continue
			end

			-- 处理普通属性
			f.Properties[self.instances[objIndex]] = {property, keyframes}
		end
	end

	return f
end

return module
