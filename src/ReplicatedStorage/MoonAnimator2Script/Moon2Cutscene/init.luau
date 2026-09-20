--[[
	MoonAnimator2 播放器主模块
	用于解析和播放 MoonAnimator2 导出的动画数据
]]

local module = {}
module.__index = module

-- 依赖模块
local transforms = require(script.transforms)
local moonUtil = require(script.MoonUtil)
local taskManager = require(script.TaskManager)

-- 类型定义
type keyframeData = {
	ease: string?,
	value: any
}

type keyframes = {
	[number]: keyframeData,
	default: any,
	wrapper: ((any, any, number) -> any)?,
	lF: number?,
	joint: Motor6D?,
}

type properties = {
	[string]: keyframes
}

export type cutsceneType = {
	instance: StringValue,
	file: any,
	FPS: number,
	instances: {[number]: Instance},
	objs: {[number]: properties},
	timeElapsed: number,
	task: taskManager.manager,
	map: Instance?,
	playing: boolean?,
	objsComputed: boolean?, -- 标记 objs 是否已计算
	attachConnections: {[Camera]: RBXScriptConnection}?, -- 存储 AttachToPart 的连接，用于防止内存泄漏

	addObj: (self: cutsceneType) -> nil,
	replace: (self: cutsceneType, number) -> nil,
	setFrame: (self: cutsceneType, timeElapsed: number) -> boolean?,

	play: (self: cutsceneType, restart: boolean?) -> nil,
	stop: (self: cutsceneType) -> nil,
	isPlaying: (self: cutsceneType) -> boolean,
	wait: (self: cutsceneType) -> nil,

	canFindObjects: (self: cutsceneType) -> boolean,
	waitForObjects: (self: cutsceneType) -> nil,
	reset: (self: cutsceneType) -> nil,
}

-- 加载效果模块
local effects = script.Effects
module.subtitle = require(effects.subtitle)
module.vignette = require(effects.vignette)
module.fade = require(effects.fade)
module.letterbox = require(effects.letterbox)

--[[
	创建新的 Cutscene 实例
	@param file: StringValue - 包含动画数据的 JSON 字符串
	@param map: Instance? - 可选的映射对象（用于查找动画中的实例）
	@param dontClone: boolean? - 是否不克隆映射对象
	@return cutsceneType - Cutscene 实例
]]
function module.new(file: StringValue, map, dontClone: boolean?): cutsceneType
	local self = setmetatable({}, module)
	self.instance = file
	self.file = game:GetService("HttpService"):JSONDecode(file.Value)
	self.FPS = self.file.Information.FPS or 60
	self.instances = {}
	self.objs = {}
	self.timeElapsed = 0
	self.objsComputed = false -- 初始化为未计算状态
	self.attachConnections = {} -- 初始化连接存储表

	self.task = taskManager.new()
	self.map = map and not dontClone and map:Clone() or map

	return self
end

--[[
	计算并解析所有对象的关键帧数据
	@param self: cutsceneType
	@return table - 解析后的对象数据
]]
local function computeObjects(self: cutsceneType)
	self.objs = {}

	for _, v in self.instance:GetChildren() do
		module.addObj(self, v)
	end

	self.objsComputed = true -- 标记为已计算
	return self.objs
end

--[[
	设置播放状态
	@param self: cutsceneType
	@param b: boolean - 是否正在播放
]]
local function setPlaying(self: cutsceneType, b: boolean?)
	self.playing = b == true
	workspace:SetAttribute("cutscene", b and self.instance.Name or nil)
end

--[[
	播放动画
	@param self: cutsceneType
	@param restart: boolean? - 是否重新开始播放
]]
function module.play(self: cutsceneType, restart: boolean?)
	if restart then
		self.task:clone()
		computeObjects(self)
		self.timeElapsed = 0
	else
		-- 如果未计算过，先计算一次
		if not self.objsComputed then
			computeObjects(self)
		end
	end

	if self.map then
		-- self.map.Parent = workspace
	end

	if not self.task.cloned then
		self.task:clone()
	end

	-- 绑定到渲染循环，每帧更新动画
	game:GetService("RunService"):BindToRenderStep("cutscene_play", Enum.RenderPriority.Camera.Value + 1, function(dt)
		self.timeElapsed += dt * self.FPS

		-- 执行当前帧的任务
		for i, v in self.task.cloned do
			if tonumber(i) and i <= self.timeElapsed then
				self.task.run(v)
				self.task.cloned[i] = nil
			end
		end

		-- 更新当前帧的动画状态
		local ended = module.setFrame(self, self.timeElapsed)
		if ended then
			-- 动画结束，执行结束任务
			self.task.run(self.task.cloned[true])
			self:stop()
		end
	end)

	setPlaying(self, true)
end

--[[
	等待动画播放完成
	@param self: cutsceneType
]]
function module.wait(self: cutsceneType)
	if not self.playing then
		return
	end

	local cor = coroutine.running()
	self.task:onEnd(function()
		coroutine.resume(cor)
	end, true)

	return coroutine.yield()
end

--[[
	注册过场结束回调（等价 task:onEnd）
	@param self: cutsceneType
	@param fn: (self: cutsceneType) -> () - 结束回调
	@return () -> () - 取消注册
]]
function module.ended(self: cutsceneType, fn: (self: cutsceneType) -> ())
	return self.task:onEnd(function()
		fn(self)
	end)
end

--[[
	停止播放动画
	@param self: cutsceneType
]]
function module.stop(self: cutsceneType)
	if self.playing then
		game:GetService("RunService"):UnbindFromRenderStep("cutscene_play")
		setPlaying(self, nil)

		-- 清理所有 AttachToPart 连接，防止内存泄漏
		if self.attachConnections then
			for camera, connection in self.attachConnections do
				if connection and connection.Connected then
					connection:Disconnect()
				end
			end
			self.attachConnections = {}
		end
	end
end

--[[
	检查是否正在播放
	@param self: cutsceneType
	@return boolean
]]
function module.isPlaying(self: cutsceneType)
	return self.playing
end

--[[
	检查是否可以找到所有需要的对象
	@param self: cutsceneType
	@return boolean, table? - 是否找到所有对象，未找到的对象（如果有）
]]
function module.canFindObjects(self: cutsceneType)
	for _, v in self.file.Items do
		if not moonUtil.getObjectFromPath(v.Path, self.map) then
			return false, v
		end
	end

	return true
end

--[[
	等待所有需要的对象加载完成
	@param self: cutsceneType
]]
function module.waitForObjects(self: cutsceneType)
	if not self:canFindObjects() then
		repeat task.wait() until self:canFindObjects()
	end
end

-- 不支持的属性类型
local unsupported = {"MarkerTrack"}
-- 需要忽略的属性类型
local ignore = {"_RigContainer_collapsed", "_PropertyContainer_collapsed"}

--[[
	添加对象并解析其关键帧数据
	@param self: cutsceneType
	@param obj: Folder - 包含关键帧数据的文件夹
]]
function module.addObj(self: cutsceneType, obj: Folder)
	local objIndex = tonumber(obj.Name)
	self.objs[objIndex] = {}
	self.instances[objIndex] = self.instances[objIndex] or moonUtil.getObjectFromPath(self.file.Items[objIndex].Path, self.map)

	if not self.instances[objIndex] then
		local pathInfo = self.file.Items[objIndex] and self.file.Items[objIndex].Path
		local pathStr = "unknown"
		if pathInfo and pathInfo.InstanceNames then
			pathStr = table.concat(pathInfo.InstanceNames, ".")
		end
		warn("[Moon2Cutscene] addObj: 找不到对象 index=", objIndex, "path=", pathStr, "map=", self.map and self.map:GetFullName())
	end

	--[[
		获取关键帧的缓动数据
		@param keyframe: Instance - 关键帧实例
		@return table? - 缓动数据 {类型, 方向}
	]]
	local function getEasingData(keyframe)
		local ease
		if keyframe:FindFirstChild("Eases") then
			ease = {keyframe:FindFirstChild("Eases") and keyframe.Eases["0"].Type.Value}

			if keyframe.Eases["0"]:FindFirstChild("Params") then
				ease[2] = keyframe.Eases["0"].Params.Direction.Value
			end
		end

		return ease
	end

	for _, propType in obj:GetChildren() do
		if table.find(ignore, propType.Name) then
			continue
		end

		if table.find(unsupported, propType.Name) then
			continue
		end

		if propType.Name == "Rig" then
			if not self.instances[objIndex] then
				continue
			end

			self.objs[objIndex].Rig = {}

			for _, joint in propType:GetChildren() do
				if #joint._keyframes:GetChildren() == 0 then
					continue
				end

				local j = moonUtil.getMotor(self.instances[objIndex], joint._hier.Value)

				if not j then
					continue
				end

				local layer = #joint._hier.Value:split(".")
				self.objs[objIndex].Rig[layer] = self.objs[objIndex].Rig[layer] or {}
				self.objs[objIndex].Rig[layer][joint._hier.Value] = {default = joint.default.Value, joint = j}

				for _, keyframe in joint._keyframes:GetChildren() do
					local i = tonumber(keyframe.Name)
					if not i then
						continue
					end

					local ease = getEasingData(keyframe)
					for _, n in keyframe.Values:GetChildren() do
						local e = tonumber(n.Name)
						if not e then continue end

						self.objs[objIndex].Rig[layer][joint._hier.Value][i + e] = {
							ease,
							n.Value,
						}
					end
				end
			end

			continue
		end


		local c = propType.default:GetChildren()[1]
		self.objs[objIndex][propType.Name] = {
			default = propType.default.Value,
			wrapper = c and transforms.Wrappers[c.Name]
		}

		if #propType:GetChildren() == 0 then
			continue
		end

		for _, keyframe in propType:GetChildren() do
			local i = tonumber(keyframe.Name)
			if not i then
				continue
			end

			local ease = getEasingData(keyframe)
			for _, n in keyframe.Values:GetChildren() do
				local e = tonumber(n.Name)
				if not e then continue end

				self.objs[objIndex][propType.Name][i + e] = {
					ease,
					n.Value,
				}
			end
		end
	end
end

--[[
	替换指定索引的对象实例
	@param self: cutsceneType
	@param objIndex: number - 对象索引
	@param newInstance: Instance - 新的实例
]]
function module.replace(self: cutsceneType, objIndex: number, newInstance: Instance)
	self.instances[objIndex] = newInstance
end

--[[
	检查表是否为空
	@param t: table
	@return boolean
]]
local function isEmpty(t)
	for _, v in t do
		return false
	end

	return true
end

--[[
	重置所有对象到默认状态
	@param self: cutsceneType
]]
function module.reset(self: cutsceneType)
	computeObjects(self) -- 这会设置 objsComputed = true
	local frames: {Rig: {}, Properties: {}} = moonUtil.getKeyFrames(self)

	-- 重置骨骼关节
	for joint, keyframes: keyframes in frames.Rig do
		joint.C1 = keyframes.default
	end

	-- 重置属性
	for obj, property: {} in frames.Properties do
		local propName = property[1]
		local defaultValue = property[2].default
		if propName == "CFrame" and obj:IsA("Model") then
			obj:PivotTo(defaultValue)
		else
			obj[propName] = defaultValue
		end
	end
end

--[[
	设置当前帧的动画状态
	@param self: cutsceneType
	@param timeElapsed: number - 已过去的时间（帧数）
	@return boolean? - 动画是否已结束
]]
function module.setFrame(self: cutsceneType, timeElapsed: number)
	-- 使用标志位检查，避免每帧遍历表（性能优化）
	if not self.objsComputed then
		computeObjects(self)
	end

	for objIndex: number, properties: properties in self.objs do
		for property: string, keyframes: keyframes in properties do
			-- 处理骨骼动画（Rig）
			if property == "Rig" then
				for layerInd, layer in keyframes do
					for jointKey, keyframes: keyframes in layer do
						--[[
							设置关节的 C1 值
							@param alpha: number - 插值系数 (0-1)
							@param flast: keyframeData? - 上一个关键帧
							@param fnext: keyframeData? - 下一个关键帧
						]]
						local function set(alpha: number, flast, fnext)
							if not fnext or not fnext[2] then
								return
							end

							transforms.C1(keyframes.joint, fnext[2], flast and flast[2] or keyframes.default, alpha)
						end

						local sorted,
						flast: keyframeData, flastNum: number,
						fnext: keyframeData, fnextNum: number
							= moonUtil.getFrames(timeElapsed, keyframes)

						-- 如果没有下一个关键帧，说明动画已结束
						if not fnext then
							flast = keyframes[sorted[#sorted - 1]]
							fnext = keyframes[sorted[#sorted]]

							set(1, flast, fnext)

							-- 清理已完成的动画数据
							self.objs[objIndex][property][layerInd][jointKey] = nil
							if isEmpty(self.objs[objIndex][property][layerInd]) then
								self.objs[objIndex][property][layerInd] = nil

								if isEmpty(self.objs[objIndex][property]) then
									self.objs[objIndex][property] = nil

									if isEmpty(self.objs[objIndex]) then
										self.objs[objIndex] = nil
									end
								end
							end

							continue
						end

						-- 计算插值系数并应用
						local alpha = moonUtil.getEase(flast and flast[1])(math.min((timeElapsed - (flastNum or 0)) / (fnextNum - (flastNum or 0)), 1))
						set(alpha, flast, fnext)
					end
				end

				continue
			end

			-- 未实现的属性：立刻剔除，避免每帧刷屏，并防止 objs 无法清空导致过场永不结束
			if not transforms[property] then
				self.objs[objIndex][property] = nil
				if isEmpty(self.objs[objIndex]) then
					self.objs[objIndex] = nil
				end
				continue
			end

			--[[
				设置普通属性的值
				@param alpha: number - 插值系数 (0-1)
				@param lastValue: keyframeData? - 上一个关键帧的值
				@param nextValue: keyframeData? - 下一个关键帧的值
			]]
			local function set(alpha: number, lastValue: any, nextValue: any)
				if type(nextValue) ~= "table" or nextValue[2] == nil then
					return
				end

				local lastVal = (type(lastValue) == "table" and lastValue[2]) or keyframes.default

				-- 使用包装器处理特殊类型（如 NumberSequence, ColorSequence）
				if keyframes.wrapper then
					transforms[property](self.instances[objIndex], keyframes.wrapper(nextValue[2], lastVal, alpha), nil, nil, nil, self)
					return
				end

				-- 传递 cutscene 实例给 AttachToPart 等需要清理连接的属性
				transforms[property](self.instances[objIndex], nextValue[2], lastVal, alpha, self)
			end

			local sorted,
			flast: keyframeData, flastNum: number,
			fnext: keyframeData, fnextNum: number
				= moonUtil.getFrames(timeElapsed, keyframes)

			-- 如果没有下一个关键帧，说明动画已结束
			if not fnext then
				flast = keyframes[sorted[#sorted - 1]]
				fnext = keyframes[sorted[#sorted]]

				keyframes.lF = fnextNum

				set(1, flast, fnext)

				-- 清理已完成的动画数据
				self.objs[objIndex][property] = nil
				if isEmpty(self.objs[objIndex]) then
					self.objs[objIndex] = nil
				end

				continue
			end

			-- 处理关键帧切换
			if flastNum then
				if not keyframes.lF or keyframes.lF ~= flastNum then
					local prevData = nil
					for i, frameNum in ipairs(sorted) do
						if frameNum == flastNum then
							if i > 1 then
								prevData = keyframes[sorted[i - 1]]
							end
							break
						end
					end
					set(1, prevData, flast)
				end
			end

			-- 计算插值系数并应用
			local alpha = moonUtil.getEase(flast and flast[1])(math.clamp((timeElapsed - (flastNum or 0)) / (fnextNum - (flastNum or 0)), 0, 1))
			keyframes.lF = alpha == 1 and fnextNum or flastNum

			set(alpha, flast, fnext)
		end
	end

	-- 如果所有对象都已处理完毕，返回 true 表示动画结束
	if isEmpty(self.objs) then
		return true
	end

	return false
end

return module