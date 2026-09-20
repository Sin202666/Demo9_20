--[[
	Module: ViewportFrameModule
	Description: ViewportFrame 3D 模型预览封装；负责相机、模型挂载、光照、动画与阴影等 UI 视口能力
	Author: 林奥宇
	Created: 2026-06-30
	Last Modified: 2026-08-31

	展示模型挂载在 ViewportFrame / WorldModel / showModel 层级下，动画作用于 showModel。
	类型声明见 Interface/ViewportFrameModule-Type.luau。

	================================================================================
	使用说明
	================================================================================

	【适用场景】
	在 ScreenGui 的 ViewportFrame 内展示 3D 模型（英雄、装备、道具等），统一相机与模型布局，
	避免各 UI 脚本重复编写 Camera / WorldModel / 清理逻辑。只写离屏视口相机，不写世界 CurrentCamera。

	【与相关模块】
	- ResourceUtil：取展示用 Model 克隆体
	- AnimationModule：SetViewportFrameModelAnimation / CloseViewportFrameModelAnimation 委托 PlayAnimByModel / StopAnimByModel
	- InsMgr：复用或创建视口内名为 Camera / WorldModel 的子实例
	- UIMgr.SetViewPort：历史兜底相机逻辑，本模块 ResolveShowModelCamera 与其对齐

	【获取模块】
	local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	local ViewportFrameModule = Utils.ViewportFrameModule

	【快速开始】
	1. 准备 ViewportFrame 与要展示的 Model（通常为 ResourceUtil.GetModel 克隆体）
	2. 用 ResolveShowModelCamera 计算相机 CFrame（推荐），或直接读模型 Attribute
	3. new 创建实例；UI 关闭或切换时必须 destroy，避免模型与阴影泄漏

	local ResourceUtil = Utils.ResourceUtil
	local viewportFrame: ViewportFrame = frame:FindFirstChild("ViewportFrame") :: ViewportFrame
	local showModel = ResourceUtil.GetModel(ResourceUtil.ModelCategory.Anime, heroId)
	if showModel then
		local cameraCFrame = ViewportFrameModule.ResolveShowModelCamera(showModel)
		local vp = ViewportFrameModule.new(viewportFrame, showModel, cameraCFrame)
		-- UI 关闭时：
		vp:destroy()
	end

	【模型 Attribute 约定】（优先级从高到低，与 UIMgr.SetViewPort 兜底一致）
	- CameraOffset (CFrame)：模型或 PrimaryPart 上的相机偏移；模型会先 PivotTo 原点再应用
	- Head (CFrame | Vector3)：自定义相机位置；Vector3 时转为 CFrame.new
	- 无上述 Attribute 时：R6 人形按 Head/Torso 自动 lookAt(0,0,-7)；否则默认 CFrame.new(0,2,8)

	【构造函数 new】
	ViewportFrameModule.new(viewportFrame, showModel?, cameraOffset?, modelOffset?)
	- viewportFrame ViewportFrame - 目标视口，内部会自动创建/复用 Camera 与 WorldModel
	- showModel Model? - 展示模型；传入时会清除视口内旧展示模型，并挂到 WorldModel 下
	- cameraOffset CFrame | Vector3? - 相机 CFrame 或位置 Vector3，默认原点 CFrame
	- modelOffset CFrame? - 模型 PivotTo 偏移，默认原点
	- 返回：预览实例；viewportFrame 无效时返回 nil

	注意：历史调用方可能传入 Vector3（如 model:GetAttribute("Head")），模块内部会自动转为 CFrame；
	新代码请优先使用 ResolveShowModelCamera 或显式 CFrame。

	【切换模型 SetShowModel】
	vp:SetShowModel(newModel, cameraOffset?, modelOffset?)
	在同一 ViewportFrame 实例上替换展示模型并更新相机，会销毁 viewportFrame 下非 WorldModel 的旧 Model。
	destroy 之后再调用实例方法会静默 return。

	【静态工具 ResolveShowModelCamera】
	ViewportFrameModule.ResolveShowModelCamera(showModel) -> CFrame
	将模型 Pivot 到原点后，按 Attribute / R6 规则解析相机 CFrame，供 new / SetShowModel 的 cameraOffset 使用。

	【可选能力】
	- SetViewportFrameColor(color, opacity) - 调整 ImageColor3 / ImageTransparency
	- CreateViewportFrameShadow(shadowOffset) - 克隆视口生成黑色偏移阴影，ZIndex = -1
	- SetViewportFrameCameraFOV(fov) - 设置相机 FieldOfView
	- SetViewportFrameLight(ambient, lightColor, lightDirection) - 设置视口光照
	- SetViewportFrameModelAnimation(name) / CloseViewportFrameModelAnimation() - 在 showModel 上播放动画（依赖 AnimationModule）
	  Close 为历史命名，语义为停止当前动画，不是关闭视口

	【生命周期】
	- new 会 Destroy viewportFrame 内已有 Model，并清理同级名为 `{Name}Shadow` 的遗留阴影视口
	- destroy 会先停止动画，再清空展示模型与阴影，并清空 CurrentCamera；可重复调用
	- 未 destroy 的实例会导致克隆模型残留在 ViewportFrame 中

	【项目内参考调用】
	- UIMgr SetHeroAward / SetHeroShardAward：ViewportFrameModule.new(frame, model, model:GetAttribute("Head") or Vector3.new(0,0,0))
	- UpdateLog：ViewportFrameModule.new(viewportFrame, displayHero, model:GetAttribute("Body") or Vector3.new(0,0,0))
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local InsMgr = Utils.InsMgr
local AnimationModule = Utils.AnimationModule
local Log = Utils.Log

-- ========================================
-- 模块定义
-- ========================================
local ViewportFrameModule = {}
ViewportFrameModule.__index = ViewportFrameModule

-- ========================================
-- 常量定义
-- ========================================
local ORIGIN_CFRAME = CFrame.new()
local R6_CAMERA_POSITION = Vector3.new(0, 0, -7)
local DEFAULT_CAMERA_CFRAME = CFrame.new(0, 2, 8)

local ATTR_CAMERA_OFFSET = "CameraOffset"
local ATTR_HEAD = "Head"
local PART_NAME_HEAD = "Head"
local PART_NAME_TORSO = "Torso"

local CAMERA_CHILD_NAME = "Camera"
local WORLD_MODEL_CHILD_NAME = "WorldModel"
local SHADOW_NAME_SUFFIX = "Shadow"
local SHADOW_COLOR = Color3.new(0, 0, 0)
local SHADOW_TRANSPARENCY = 0
local SHADOW_ZINDEX = -1

-- ========================================
-- 私有函数
-- ========================================

--[[
	将相机偏移参数规范为 CFrame（兼容历史 Vector3 传参）

	@param offset CFrame | Vector3? - 相机偏移；nil 或非 CFrame/Vector3 时返回原点
	@return CFrame - 有效相机 CFrame
]]
local function _toCameraCFrame(offset: CFrame | Vector3?): CFrame
	if not offset then
		return ORIGIN_CFRAME
	end
	if typeof(offset) == "Vector3" then
		return CFrame.new(offset :: Vector3)
	end
	if typeof(offset) == "CFrame" then
		return offset :: CFrame
	end
	return ORIGIN_CFRAME
end

--[[
	清理视口内展示模型，保留 WorldModel 容器与 Camera

	@param viewportFrame ViewportFrame - 目标视口
]]
local function _clearShowModels(viewportFrame: ViewportFrame)
	for _, child in viewportFrame:GetChildren() do
		if child:IsA("WorldModel") then
			for _, model in child:GetChildren() do
				if model:IsA("Model") then
					model:Destroy()
				end
			end
		elseif child:IsA("Model") then
			child:Destroy()
		end
	end
end

--[[
	销毁与视口同级、由本模块命名的遗留阴影视口

	@param viewportFrame ViewportFrame - 原视口；无 Parent 时跳过
]]
local function _destroyOrphanShadow(viewportFrame: ViewportFrame)
	local parent = viewportFrame.Parent
	if not parent then
		return
	end
	local orphan = parent:FindFirstChild(viewportFrame.Name .. SHADOW_NAME_SUFFIX)
	if orphan and orphan:IsA("ViewportFrame") and orphan ~= viewportFrame then
		orphan:Destroy()
	end
end

--[[
	从模型或 PrimaryPart 读取 CameraOffset Attribute

	@param inst Instance - 模型或部件
	@return CFrame? - 有效 CFrame 属性，否则 nil
]]
local function _readCameraOffsetFrom(inst: Instance): CFrame?
	local off = inst:GetAttribute(ATTR_CAMERA_OFFSET)
	if typeof(off) == "CFrame" then
		return off
	end
	if inst:IsA("Model") then
		local pp = inst.PrimaryPart
		if pp then
			off = pp:GetAttribute(ATTR_CAMERA_OFFSET)
			if typeof(off) == "CFrame" then
				return off
			end
		end
	end
	return nil
end

--[[
	实例是否仍持有有效 ViewportFrame（destroy 后为 false）

	@param self table - 预览实例（读 viewportFrame 字段）
	@return boolean - viewportFrame 仍为 ViewportFrame 时 true
]]
local function _isAlive(self): boolean
	local vf = self.viewportFrame
	return typeof(vf) == "Instance" and vf:IsA("ViewportFrame")
end

-- ========================================
-- 公共 API
-- ========================================

--[[
	模型已在原点时解析展示用相机 CFrame：CameraOffset / Head Attribute，或 R6 人形默认视角

	@param showModel Model - 已克隆、即将放入 ViewportFrame 的模型
	@return CFrame - 供 viewportCamera 使用的相机 CFrame；showModel 无效时返回默认机位
]]
function ViewportFrameModule.ResolveShowModelCamera(showModel: Model): CFrame
	if typeof(showModel) ~= "Instance" or not showModel:IsA("Model") then
		Log.warn("[ViewportFrameModule] ResolveShowModelCamera: showModel 无效")
		return DEFAULT_CAMERA_CFRAME
	end
	showModel:PivotTo(ORIGIN_CFRAME)
	local cf = _readCameraOffsetFrom(showModel)
	if cf then
		return cf
	end
	local headAttr = showModel:GetAttribute(ATTR_HEAD)
	if typeof(headAttr) == "CFrame" then
		return headAttr
	end
	if typeof(headAttr) == "Vector3" then
		return CFrame.new(headAttr)
	end
	local head = showModel:FindFirstChild(PART_NAME_HEAD)
	if head and head:IsA("BasePart") then
		local focus = head.Position
		-- R6 默认朝 -Z，相机放在 -Z 侧才能看到正面
		return CFrame.lookAt(R6_CAMERA_POSITION, focus)
	end
	local torso = showModel:FindFirstChild(PART_NAME_TORSO)
	if torso and torso:IsA("BasePart") then
		local focus = torso.Position
		return CFrame.lookAt(R6_CAMERA_POSITION, focus)
	end
	return DEFAULT_CAMERA_CFRAME
end

--[[
	创建 ViewportFrame 预览实例

	@param viewportFrame ViewportFrame - 目标 UI 视口
	@param showModel Model? - 初始展示模型，nil 则仅初始化相机与 WorldModel
	@param cameraOffset CFrame | Vector3? - 相机 CFrame 或位置；nil 时原点
	@param modelOffset CFrame? - 模型 PivotTo 偏移，nil 时原点
	@return table? - 预览实例（viewportFrame / showModel / viewportCamera / worldModel）；无效视口时 nil，须 destroy
]]
function ViewportFrameModule.new(
	viewportFrame: ViewportFrame,
	showModel: Model?,
	cameraOffset: CFrame | Vector3?,
	modelOffset: CFrame?
)
	if typeof(viewportFrame) ~= "Instance" or not viewportFrame:IsA("ViewportFrame") then
		Log.warn("[ViewportFrameModule] new: viewportFrame 无效")
		return nil
	end

	_clearShowModels(viewportFrame)
	_destroyOrphanShadow(viewportFrame)

	local self = setmetatable({}, ViewportFrameModule)
	self.viewportFrame = viewportFrame
	self.viewportCamera = InsMgr.GetIns(CAMERA_CHILD_NAME, "Camera", self.viewportFrame)
	self.worldModel = InsMgr.GetIns(WORLD_MODEL_CHILD_NAME, "WorldModel", self.viewportFrame)

	self.shadowViewportFrame = nil
	self.viewportModelAnimationName = nil
	if showModel then
		self.showModel = showModel
		self.showModel:PivotTo(modelOffset or ORIGIN_CFRAME)
		self.showModel.Parent = self.worldModel
	end

	self.viewportCamera.CFrame = _toCameraCFrame(cameraOffset)
	self.viewportFrame.CurrentCamera = self.viewportCamera

	return self
end

--[[
	在同一实例上替换展示模型并更新相机

	@param self table - 预览实例
	@param showModel Model - 新展示模型
	@param cameraOffset CFrame | Vector3? - 新相机 CFrame 或位置；nil 时原点
	@param modelOffset CFrame? - 模型 PivotTo 偏移，nil 时原点
]]
function ViewportFrameModule.SetShowModel(self, showModel: Model, cameraOffset: CFrame | Vector3?, modelOffset: CFrame?)
	if not _isAlive(self) then
		return
	end
	if typeof(showModel) ~= "Instance" or not showModel:IsA("Model") then
		return
	end

	self:CloseViewportFrameModelAnimation()
	_clearShowModels(self.viewportFrame)

	self.showModel = showModel
	self.showModel:PivotTo(modelOffset or ORIGIN_CFRAME)
	self.showModel.Parent = self.worldModel

	self.viewportCamera.CFrame = _toCameraCFrame(cameraOffset)
end

--[[
	释放实例持有的模型与阴影，UI 关闭或列表项回收时调用；可重复调用

	@param self table - 预览实例
]]
function ViewportFrameModule.destroy(self)
	self:CloseViewportFrameModelAnimation()
	if _isAlive(self) then
		_clearShowModels(self.viewportFrame)
		if self.shadowViewportFrame then
			self.shadowViewportFrame:Destroy()
		end
		_destroyOrphanShadow(self.viewportFrame)
		self.viewportFrame.CurrentCamera = nil
	elseif self.shadowViewportFrame then
		self.shadowViewportFrame:Destroy()
	end
	self.showModel = nil
	self.shadowViewportFrame = nil
	self.viewportCamera = nil
	self.worldModel = nil
	self.viewportFrame = nil
end

--[[
	设置 ViewportFrame 着色与透明度

	@param self table - 预览实例
	@param color Color3 - ImageColor3 颜色
	@param opacity number - ImageTransparency，0 不透明、1 全透明
]]
function ViewportFrameModule.SetViewportFrameColor(self, color: Color3, opacity: number)
	if not _isAlive(self) then
		return
	end
	self.viewportFrame.ImageColor3 = color
	self.viewportFrame.ImageTransparency = opacity
end

--[[
	克隆视口生成黑色偏移阴影层（ZIndex = -1）

	@param self table - 预览实例
	@param shadowOffset UDim2 - 相对原视口的 Position 偏移（仅使用 Offset 分量）
	@return ViewportFrame? - 阴影视口实例，同时保存在实例 shadowViewportFrame；destroy 后 nil
]]
function ViewportFrameModule.CreateViewportFrameShadow(self, shadowOffset: UDim2)
	if not _isAlive(self) then
		return nil
	end
	if typeof(shadowOffset) ~= "UDim2" then
		Log.warn("[ViewportFrameModule] CreateViewportFrameShadow: shadowOffset 无效")
		return nil
	end
	if self.shadowViewportFrame then
		self.shadowViewportFrame:Destroy()
		self.shadowViewportFrame = nil
	end
	_destroyOrphanShadow(self.viewportFrame)
	local shadowViewportFrame = self.viewportFrame:Clone()
	shadowViewportFrame.Name = self.viewportFrame.Name .. SHADOW_NAME_SUFFIX
	shadowViewportFrame.Parent = self.viewportFrame.Parent
	shadowViewportFrame.ImageColor3 = SHADOW_COLOR
	shadowViewportFrame.ImageTransparency = SHADOW_TRANSPARENCY
	shadowViewportFrame.ZIndex = SHADOW_ZINDEX
	local oriPosition = self.viewportFrame.Position
	shadowViewportFrame.Position = UDim2.new(
		oriPosition.X.Scale,
		oriPosition.X.Offset + shadowOffset.X.Offset,
		oriPosition.Y.Scale,
		oriPosition.Y.Offset + shadowOffset.Y.Offset
	)
	self.shadowViewportFrame = shadowViewportFrame
	return shadowViewportFrame
end

--[[
	在展示模型上播放指定名称动画（同名动画已在播放则跳过）

	@param self table - 预览实例
	@param animationName string - AnimationModule 配置的动画名称
]]
function ViewportFrameModule.SetViewportFrameModelAnimation(self, animationName: string)
	if not _isAlive(self) then
		return
	end
	if typeof(animationName) ~= "string" or animationName == "" then
		return
	end
	if self.viewportModelAnimationName == animationName then
		return
	end
	self:CloseViewportFrameModelAnimation()
	self.viewportModelAnimationName = animationName
	if self.showModel then
		AnimationModule.PlayAnimByModel(self.showModel, self.viewportModelAnimationName)
	end
end

--[[
	停止当前 ViewportFrame 模型动画（历史名 Close，语义为 Stop）

	@param self table - 预览实例
]]
function ViewportFrameModule.CloseViewportFrameModelAnimation(self)
	local animName = self.viewportModelAnimationName
	self.viewportModelAnimationName = nil
	if animName and self.showModel then
		AnimationModule.StopAnimByModel(self.showModel, animName)
	end
end

--[[
	设置视口相机视野

	@param self table - 预览实例
	@param fov number - FieldOfView 角度（度）
]]
function ViewportFrameModule.SetViewportFrameCameraFOV(self, fov: number)
	if not _isAlive(self) then
		return
	end
	self.viewportCamera.FieldOfView = fov
end

--[[
	设置视口相机光照

	@param self table - 预览实例
	@param ambient Color3 - 环境光颜色
	@param lightColor Color3 - 定向光颜色
	@param lightDirection Vector3 - 定向光方向
]]
function ViewportFrameModule.SetViewportFrameLight(self, ambient: Color3, lightColor: Color3, lightDirection: Vector3)
	if not _isAlive(self) then
		return
	end
	self.viewportCamera.Ambient = ambient
	self.viewportCamera.LightColor = lightColor
	self.viewportCamera.LightDirection = lightDirection
end

return ViewportFrameModule
