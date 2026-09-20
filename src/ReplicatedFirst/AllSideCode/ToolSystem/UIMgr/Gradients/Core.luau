--[[
	Module: UIMgr.Gradients.Core
	Description: UIGradient / Color3 过渡与通用渐变挂载（由 Gradients/init 合并，业务勿直接 require）
	Author: 林奥宇
	Created: 2026-08-18
	Last Modified: 2026-09-01

	功能：
	- GetGradientColor：AllGridients/Gridient、旧 Assets/Gridient、Assets/UIGradient；Folder 包 UIGradient 也可
	- 类型未命中只 warn 一次（避免排行榜按格刷屏）
	- TransitionColor3（与渐变切换共用时长）
	- 进行中的 _gradientTransitions / _color3Transitions 只在本模块一份
	- 克隆剥脚本、过渡/移除时 Stop 循环、彩虹类过渡结束后自动 Play（经 Gradients.Anim）

	与 Rarity / Element / Title / Anim：
	- 子模块经 init 注入的 internals 调 finishGradientTransition / applyGradientWithTransition
	- Anim 先于本模块挂载；本模块运行时调 StopGradientAnim / PrepareClonedGradient / PlayGradientAnimForPreset
	- 业务只走 Utils.UIMgr
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log
local RunService = Utils.RunService
local ReplicatedStorage = Utils.ReplicatedStorage
local AssetPaths = Utils.AssetPaths
local AssetRegistry = Utils.AssetRegistry
local GradientCfg = require(script.Parent.Parent.GradientCfg)

local AllGridientsFolder: Folder? = AssetPaths.GetCatalog(AssetRegistry.Catalog.AllGridients) :: Folder?
local GradientFolder: Folder? = AllGridientsFolder and AllGridientsFolder:FindFirstChild("Gridient") :: Folder?
local XydColorFolder: Folder? = AllGridientsFolder and AllGridientsFolder:FindFirstChild("RarityGridient") :: Folder?
local HeroFrameFolder: Folder? = AllGridientsFolder and AllGridientsFolder:FindFirstChild("英雄框") :: Folder?
local TitleTemplatePath = AssetRegistry.BuildCatalogPath(AssetRegistry.Catalog.ModelRes, "Title")
local TitleTemplateResolved = AssetPaths.Resolve(TitleTemplatePath)
local TitleTemplateFolder: Folder? = if TitleTemplateResolved and TitleTemplateResolved:IsA("Folder")
	then TitleTemplateResolved :: Folder
	else nil
local UIMgrFolder = script.Parent.Parent
local XydEffectTemplate: Instance? = UIMgrFolder:FindFirstChild("框特效")

local GRADIENT_TRANSITION_DURATION = 0.25
local COLOR_NEAR_EPSILON = 1e-4
local ATTR_GRADIENT_ANIM = "GradientAnim"
local GRIDIENT_CHILD_NAME = "Gridient"
local LEGACY_GRIDIENT_CATALOG = "Gridient"
local UI_GRADIENT_CATALOG = "UIGradient"
local TEXT_GRADIENT_SUFFIX = "-Text"
local ASSETS_ROOT_NAME = "Assets"

local _gradientTransitions: { [Instance]: {
	connection: RBXScriptConnection,
	gradient: UIGradient,
	ancestryConnection: RBXScriptConnection?,
} } = {}
local _color3Transitions: { [Instance]: {
	connection: RBXScriptConnection,
	ancestryConnection: RBXScriptConnection?,
} } = {}
local _warnedMissingGradientType: { [string]: boolean } = {}

-- Anim 先于 Core 挂到同一 Gradients 表；本模块在 return function 入口赋值，运行时调 Play/Stop/Prepare
local _Gradients: any = nil

--[[
	停止 target 上的循环表现（无 Anim 时忽略）
	@param target Instance - UIGradient 或挂载父节点
]]
local function _stopAnim(target: Instance)
	local api = _Gradients
	if api and api.StopGradientAnim then
		api.StopGradientAnim(target)
	end
end

--[[
	克隆后剥子级脚本
	@param gradient UIGradient - 克隆实例
]]
local function _prepareClone(gradient: UIGradient)
	local api = _Gradients
	if api and api.PrepareClonedGradient then
		api.PrepareClonedGradient(gradient)
	end
end

--[[
	实例是否为 Folder

	@param inst Instance? - 待判断实例
	@return Folder? - 是 Folder 时返回；否则 nil
]]
local function _asFolder(inst: Instance?): Folder?
	if inst and inst:IsA("Folder") then
		return inst :: Folder
	end
	return nil
end

--[[
	取 Assets 下一级 catalog。GetCatalog 可能在 ReplicatedFirst 首帧负缓存，未命中时再直查 RS.Assets。

	@param catalogName string - catalog 名（AllGridients / Gridient / UIGradient）
	@return Folder? - catalog；不存在为 nil
]]
local function _findAssetsCatalog(catalogName: string): Folder?
	local viaApi = AssetPaths.GetCatalog(catalogName)
	if viaApi then
		return viaApi
	end
	local assetsRoot = AssetPaths.GetAssetsRoot()
	if not assetsRoot then
		local assets = ReplicatedStorage:FindFirstChild(ASSETS_ROOT_NAME)
		assetsRoot = _asFolder(assets)
	end
	if not assetsRoot then
		return nil
	end
	return _asFolder(assetsRoot:FindFirstChild(catalogName))
end

--[[
	按当前复制进度刷新 AllGridients 子目录引用（Gridient / RarityGridient / 英雄框）

	@return () - 无返回值
]]
local function _refreshGradientFolders()
	local all = _findAssetsCatalog(AssetRegistry.Catalog.AllGridients)
	if all then
		AllGridientsFolder = all
		local nested = _asFolder(all:FindFirstChild(GRIDIENT_CHILD_NAME))
		if nested then
			GradientFolder = nested
		end
		local rarity = _asFolder(all:FindFirstChild("RarityGridient"))
		if rarity then
			XydColorFolder = rarity
		end
		local hero = _asFolder(all:FindFirstChild("英雄框"))
		if hero then
			HeroFrameFolder = hero
		end
	end
	if not GradientFolder then
		GradientFolder = _findAssetsCatalog(LEGACY_GRIDIENT_CATALOG)
	end
end

--[[
	渐变预设查找目录：AllGridients/Gridient、旧 Assets/Gridient、Assets/UIGradient、AllGridients 根

	@return { Folder } - 去重后的目录列表
]]
local function _iterGradientFolders(): { Folder }
	_refreshGradientFolders()
	local seen: { [Instance]: boolean } = {}
	local list: { Folder } = {}
	local function add(folder: Folder?)
		if folder and not seen[folder] then
			seen[folder] = true
			table.insert(list, folder)
		end
	end
	add(GradientFolder)
	add(_findAssetsCatalog(LEGACY_GRIDIENT_CATALOG))
	add(_findAssetsCatalog(UI_GRADIENT_CATALOG))
	add(AllGridientsFolder)
	return list
end

--[[
	从预设实例克隆 UIGradient。预设可以是 UIGradient 本身，或包一层 Folder。

	@param inst Instance - Gridient 下与类型同名的子实例
	@return UIGradient? - 已 Prepare 的克隆；结构不符为 nil
]]
local function _cloneGradientFrom(inst: Instance): UIGradient?
	if inst:IsA("UIGradient") then
		local cloned = inst:Clone()
		_prepareClone(cloned)
		return cloned
	end
	local inner = inst:FindFirstChildOfClass("UIGradient")
	if inner then
		local cloned = inner:Clone()
		_prepareClone(cloned)
		return cloned
	end
	return nil
end

--[[
	按实例名在各渐变目录中取预设并克隆

	@param name string - Gridient 子级 Name
	@return UIGradient? - 克隆；未找到为 nil
]]
local function _findGradientTemplate(name: string): UIGradient?
	if name == "" then
		return nil
	end
	for _, folder in _iterGradientFolders() do
		local inst = folder:FindFirstChild(name)
		if inst then
			local cloned = _cloneGradientFrom(inst)
			if cloned then
				return cloned
			end
		end
	end
	return nil
end

--[[
	按逻辑名或 GradientCfg 别名取预设

	@param typeStr string - AddGradientColor / GetGradientColor 的类型键
	@return UIGradient? - 克隆；未找到为 nil
]]
local function _lookupGradient(typeStr: string): UIGradient?
	local found = _findGradientTemplate(typeStr)
	if found then
		return found
	end
	local nameStr = GradientCfg[typeStr]
	if type(nameStr) == "string" and nameStr ~= "" and nameStr ~= typeStr then
		found = _findGradientTemplate(nameStr)
		if found then
			return found
		end
	end
	return nil
end

--[[
	同一类型只 warn 一次（排行榜格子会按格调用）

	@param typeStr string - 未命中的类型键
	@return () - 无返回值
]]
local function _warnInvalidGradientType(typeStr: string)
	if _warnedMissingGradientType[typeStr] then
		return
	end
	_warnedMissingGradientType[typeStr] = true
	Log.warn("_type 配置不合法", typeStr)
end

--[[
	按预设键自动播循环
	@param gradient UIGradient - 目标
	@param typeKey string? - 逻辑名或预设名
]]
local function _autoPlay(gradient: UIGradient, typeKey: string?)
	local api = _Gradients
	if api and api.PlayGradientAnimForPreset then
		api.PlayGradientAnimForPreset(gradient, typeKey)
	end
end

--[[
	实例被 Destroy 时触发清理（AncestryChanged → parent 为 nil）
	@param instance Instance - 监听的 UI 实例
	@param onDestroyed () -> () - 销毁回调
	@return RBXScriptConnection - 可选手动断开
]]
local function _watchInstanceDestroyed(instance: Instance, onDestroyed: () -> ()): RBXScriptConnection
	return instance.AncestryChanged:Connect(function(_, newParent)
		if newParent == nil then
			onDestroyed()
		end
	end)
end

--[[
	读取支持 Color3 过渡的 Gui 实例当前颜色
	@param inst Instance - 目标实例
	@return Color3? - 当前颜色，不支持时 nil
	@return boolean - 是否支持 Color3 读写
]]
local function _getColor3ForInstance(inst: Instance): (Color3?, boolean)
	if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
		return inst.ImageColor3, true
	end
	if inst:IsA("TextLabel") or inst:IsA("TextButton") then
		return inst.TextColor3, true
	end
	if inst:IsA("Frame") then
		return inst.BackgroundColor3, true
	end
	if inst:IsA("UIStroke") then
		return inst.Color, true
	end
	return nil, false
end

--[[
	写入支持 Color3 过渡的 Gui 实例颜色
	@param inst Instance - 目标实例
	@param color Color3 - 目标颜色
	@return boolean - 是否写入成功
]]
local function _setColor3ForInstance(inst: Instance, color: Color3): boolean
	if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
		inst.ImageColor3 = color
		return true
	end
	if inst:IsA("TextLabel") or inst:IsA("TextButton") then
		inst.TextColor3 = color
		return true
	end
	if inst:IsA("Frame") then
		inst.BackgroundColor3 = color
		return true
	end
	if inst:IsA("UIStroke") then
		inst.Color = color
		return true
	end
	return false
end

--[[
	将渐变挂载父节点底色重置为白，以便 UIGradient 正片叠底
	@param parent Instance - 挂载 UIGradient 的父实例
]]
local function _resetParentWhiteBase(parent: Instance)
	if parent:IsA("TextLabel") or parent:IsA("TextButton") then
		parent.TextColor3 = Color3.new(1, 1, 1)
	elseif parent:IsA("Frame") then
		parent.BackgroundColor3 = Color3.new(1, 1, 1)
	elseif parent:IsA("ImageLabel") or parent:IsA("ImageButton") then
		parent.ImageColor3 = Color3.new(1, 1, 1)
	elseif parent:IsA("UIStroke") then
		parent.Color = Color3.new(1, 1, 1)
	end
end

--[[
	结束并清理指定实例上正在进行的 Color3 过渡
	@param instance Instance - 目标实例
]]
local function _finishColor3Transition(instance: Instance)
	local state = _color3Transitions[instance]
	if not state then
		return
	end
	_color3Transitions[instance] = nil
	state.connection:Disconnect()
	if state.ancestryConnection then
		state.ancestryConnection:Disconnect()
	end
end

--[[
	在 ColorSequence 上按归一化时间 t（0..1）采样 Color3
	@param seq ColorSequence - 源序列
	@param t number - 采样时间 0..1
	@return Color3 - 插值结果
]]
local function _getColorAtTime(seq: ColorSequence, t: number): Color3
	local kps = seq.Keypoints
	if not kps or #kps == 0 then
		return Color3.new(1, 1, 1)
	end
	if #kps == 1 or t <= kps[1].Time then
		return kps[1].Value
	end
	if t >= kps[#kps].Time then
		return kps[#kps].Value
	end
	for i = 1, #kps - 1 do
		if t >= kps[i].Time and t <= kps[i + 1].Time then
			local a = kps[i].Time
			local b = kps[i + 1].Time
			local subAlpha = (b - a > 0) and ((t - a) / (b - a)) or 0
			return kps[i].Value:Lerp(kps[i + 1].Value, subAlpha)
		end
	end
	return kps[#kps].Value
end

--[[
	两个 ColorSequence 在 0、1 两端采样后按 alpha 插值
	@param fromSeq ColorSequence - 起始序列
	@param toSeq ColorSequence - 目标序列
	@param alpha number - 插值系数 0..1
	@return ColorSequence - 两关键点新序列
]]
local function _lerpColorSequence(fromSeq: ColorSequence, toSeq: ColorSequence, alpha: number): ColorSequence
	local c0 = _getColorAtTime(fromSeq, 0):Lerp(_getColorAtTime(toSeq, 0), alpha)
	local c1 = _getColorAtTime(fromSeq, 1):Lerp(_getColorAtTime(toSeq, 1), alpha)
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, c0),
		ColorSequenceKeypoint.new(1, c1),
	})
end

--[[
	结束并清理指定 parent 上正在进行的 UIGradient 过渡
	@param parent Instance - 挂载渐变的父实例
]]
local function _finishGradientTransition(parent: Instance)
	local state = _gradientTransitions[parent]
	if not state then
		return
	end
	_gradientTransitions[parent] = nil
	state.connection:Disconnect()
	if state.ancestryConnection then
		state.ancestryConnection:Disconnect()
	end
end

--[[
	在已有 UIGradient 上从当前 Color/Rotation 丝滑过渡到目标模板
	@param parent Instance - 挂载渐变的父实例
	@param currentGradient UIGradient - 当前渐变（就地修改）
	@param newGradientTemplate UIGradient - 目标模板（调用后 Destroy）
	@param endRot number - 目标 Rotation
	@param attributeName string - 写入 parent 的 Attribute 名
	@param attributeValue string - Attribute 值
	@param animTypeKey string? - 过渡结束后自动播循环的查找键；缺省用 attributeValue
	@return UIGradient - 过渡中的渐变实例
]]
local function _applyGradientWithTransition(
	parent: Instance,
	currentGradient: UIGradient,
	newGradientTemplate: UIGradient,
	endRot: number,
	attributeName: string,
	attributeValue: string,
	animTypeKey: string?
): UIGradient
	_stopAnim(currentGradient)
	local animAttr = newGradientTemplate:GetAttribute(ATTR_GRADIENT_ANIM)
	if animAttr ~= nil then
		currentGradient:SetAttribute(ATTR_GRADIENT_ANIM, animAttr)
	end
	local startColor = currentGradient.Color
	local endColor = newGradientTemplate.Color
	local startRot = currentGradient.Rotation
	newGradientTemplate:Destroy()
	parent:SetAttribute(attributeName, attributeValue)

	local startTime = tick()
	local connection: RBXScriptConnection
	local playKey = animTypeKey or attributeValue
	connection = RunService.Heartbeat:Connect(function()
		local elapsed = tick() - startTime
		local alpha = math.min(1, elapsed / GRADIENT_TRANSITION_DURATION)
		currentGradient.Color = _lerpColorSequence(startColor, endColor, alpha)
		currentGradient.Rotation = startRot + (endRot - startRot) * alpha
		if alpha >= 1 then
			currentGradient.Color = endColor
			currentGradient.Rotation = endRot
			_finishGradientTransition(parent)
			_autoPlay(currentGradient, playKey)
		end
	end)
	local ancestryConnection = _watchInstanceDestroyed(parent, function()
		_finishGradientTransition(parent)
	end)
	_gradientTransitions[parent] = {
		connection = connection,
		gradient = currentGradient,
		ancestryConnection = ancestryConnection,
	}
	return currentGradient
end

--[[
	挂载通用渐变 API，并返回供 Rarity / Element / Title 使用的 internals。
	@param Gradients table - 与 init 同一份导出表，本函数向其挂载 Get/Add/RemoveGradientColor 等
	@return { finishGradientTransition: (Instance) -> (), applyGradientWithTransition: (Instance, UIGradient, UIGradient, number, string, string, string?) -> UIGradient, resetParentWhiteBase: (Instance) -> (), AllGridientsFolder: Folder?, XydColorFolder: Folder?, HeroFrameFolder: Folder?, XydEffectTemplate: Instance?, TitleTemplateFolder: Folder? } - 过渡函数与资源 Folder
]]
return function(Gradients)
	_Gradients = Gradients

	--[[
		获取渐变颜色
		@param _type string|number - 渐变类型
		@return UIGradient? - 渐变对象
	]]
	function Gradients.GetGradientColor(_type: string|number): UIGradient?
		local typeStr = tostring(_type)
		local found = _lookupGradient(typeStr)
		if
			not found
			and string.sub(typeStr, -#TEXT_GRADIENT_SUFFIX) ~= TEXT_GRADIENT_SUFFIX
		then
			found = _lookupGradient(typeStr .. TEXT_GRADIENT_SUFFIX)
		end
		if found then
			return found
		end
		_warnInvalidGradientType(typeStr)
		return nil
	end

	--[[
		添加渐变颜色
		@param _type string? - 渐变类型
		@param _parent Instance - 父实例
		@param isText boolean? - 是否为文本类型
		@param _Rot number? - 旋转角度
		@param useColorTransition boolean? - 父节点已有 UIGradient 时是否旧色→新色过渡（默认 true；false 则直接替换为目标渐变）
		@return UIGradient? - 渐变对象
	]]
	function Gradients.AddGradientColor(_type: string?, _parent: Instance, isText: boolean?, _Rot: number?, useColorTransition: boolean?): UIGradient?
		if not _type then
			return nil
		end

		local typeStr = tostring(_type)
		if _parent:GetAttribute("xyd") == typeStr then
			return _parent:FindFirstChildOfClass("UIGradient")::UIGradient?
		end

		-- 处理文本类型
		local gradientType = typeStr
		if isText == true then
			gradientType = typeStr.."-Text"
		end

		local newGradientTemplate: UIGradient? = Gradients.GetGradientColor(gradientType)
		if not newGradientTemplate and isText == true then
			newGradientTemplate = Gradients.GetGradientColor(typeStr)
			if newGradientTemplate then
				gradientType = typeStr
			end
		end
		if not newGradientTemplate then
			return nil
		end

		local useTrans = useColorTransition ~= false

		_stopAnim(_parent)
		_finishGradientTransition(_parent)

		local currentGradient: UIGradient? = _parent:FindFirstChildOfClass("UIGradient")

		if currentGradient and useTrans then
			local endRot = _Rot or newGradientTemplate.Rotation
			return _applyGradientWithTransition(
				_parent,
				currentGradient,
				newGradientTemplate,
				endRot,
				"xyd",
				typeStr,
				gradientType
			)
		end

		if currentGradient and not useTrans then
			currentGradient:Destroy()
		end

		_resetParentWhiteBase(_parent)
		newGradientTemplate.Parent = _parent
		if _Rot then
			newGradientTemplate.Rotation = _Rot
		end
		_parent:SetAttribute("xyd", typeStr)
		_autoPlay(newGradientTemplate, gradientType)
		return newGradientTemplate
	end

	--[[
		移除渐变颜色
		@param _parent Instance - 父实例
		@return () - 无返回值
	]]
	function Gradients.RemoveGradientColor(_parent: Instance)
		_stopAnim(_parent)
		_finishGradientTransition(_parent)
		local gradient: UIGradient? = _parent:FindFirstChildOfClass("UIGradient")
		if gradient then
			gradient:Destroy()
			_parent:SetAttribute("xyd", nil)
		end
	end

	--[[
		获取UIGradient
		@param _parent Instance - 父实例
		@return UIGradient? - 渐变对象
	]]
	function Gradients.GetUIGradient(_parent: Instance): UIGradient?
		return _parent:FindFirstChildOfClass("UIGradient")::UIGradient?
	end

	--[[
		对支持颜色的实例做 Color3 丝滑过渡（与渐变色切换同风格）。
		支持：ImageLabel/ImageButton（ImageColor3）、TextLabel/TextButton（TextColor3）、
		Frame（BackgroundColor3）、UIStroke（Color）。
		@param instance Instance - 目标实例（如 ShowFrame 的 Bg亮底纹 ImageLabel）
		@param targetColor Color3 - 目标颜色
		@param duration number? - 过渡时长（秒），缺省使用与渐变色相同的 GRADIENT_TRANSITION_DURATION
		@param useTransition boolean? - 是否插值过渡（默认 true；false 则立即设为目标色）
		@return () - 无返回值
	]]
	function Gradients.TransitionColor3(instance: Instance, targetColor: Color3, duration: number?, useTransition: boolean?)
		if not instance or not targetColor then return end
		if useTransition == false then
			_finishColor3Transition(instance)
			_setColor3ForInstance(instance, targetColor)
			return
		end
		local currentColor, supported = _getColor3ForInstance(instance)
		if not supported or not currentColor then return end

		duration = duration or GRADIENT_TRANSITION_DURATION
		-- 已接近目标色则直接设值
		local dr = math.abs(currentColor.R - targetColor.R)
		local dg = math.abs(currentColor.G - targetColor.G)
		local db = math.abs(currentColor.B - targetColor.B)
		if dr < COLOR_NEAR_EPSILON and dg < COLOR_NEAR_EPSILON and db < COLOR_NEAR_EPSILON then
			_setColor3ForInstance(instance, targetColor)
			return
		end

		_finishColor3Transition(instance)
		local startColor = currentColor
		local startTime = tick()
		local connection: RBXScriptConnection
		connection = RunService.Heartbeat:Connect(function()
			local elapsed = tick() - startTime
			local alpha = math.min(1, elapsed / duration)
			_setColor3ForInstance(instance, startColor:Lerp(targetColor, alpha))
			if alpha >= 1 then
				_setColor3ForInstance(instance, targetColor)
				_finishColor3Transition(instance)
			end
		end)
		local ancestryConnection = _watchInstanceDestroyed(instance, function()
			_finishColor3Transition(instance)
		end)
		_color3Transitions[instance] = { connection = connection, ancestryConnection = ancestryConnection }
	end

	return {
		finishGradientTransition = _finishGradientTransition,
		applyGradientWithTransition = _applyGradientWithTransition,
		resetParentWhiteBase = _resetParentWhiteBase,
		AllGridientsFolder = AllGridientsFolder,
		XydColorFolder = XydColorFolder,
		HeroFrameFolder = HeroFrameFolder,
		XydEffectTemplate = XydEffectTemplate,
		TitleTemplateFolder = TitleTemplateFolder,
	}
end
