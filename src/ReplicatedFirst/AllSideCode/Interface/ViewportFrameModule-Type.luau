--[[
	Module: ViewportFrameModule-Type
	Description: ViewportFrameModule 类型声明（完整使用说明见 ToolBasic/ViewportFrameModule.luau 文件头）
	Author: 林奥宇
	Created: 2026-06-30
	Last Modified: 2026-08-31
]]

local ViewportFrameModule = {}

-- ============================================================================
-- ViewportFrameModule 类类型定义
-- ============================================================================

export type ViewportFrameModuleInstance = {
	viewportFrame: ViewportFrame?,
	showModel: Model?,
	viewportCamera: Camera?,
	worldModel: WorldModel?,
	shadowViewportFrame: ViewportFrame?,
	viewportModelAnimationName: string?,

	SetViewportFrameColor: (self: ViewportFrameModuleInstance, color: Color3, opacity: number) -> nil,
	CreateViewportFrameShadow: (self: ViewportFrameModuleInstance, shadowOffset: UDim2) -> ViewportFrame?,
	SetViewportFrameModelAnimation: (self: ViewportFrameModuleInstance, animationName: string) -> nil,
	CloseViewportFrameModelAnimation: (self: ViewportFrameModuleInstance) -> nil,
	SetViewportFrameCameraFOV: (self: ViewportFrameModuleInstance, fov: number) -> nil,
	SetViewportFrameLight: (
		self: ViewportFrameModuleInstance,
		ambient: Color3,
		lightColor: Color3,
		lightDirection: Vector3
	) -> nil,
	SetShowModel: (
		self: ViewportFrameModuleInstance,
		showModel: Model,
		cameraOffset: CFrame | Vector3?,
		modelOffset: CFrame?
	) -> nil,
	destroy: (self: ViewportFrameModuleInstance) -> nil,
}

export type ViewportFrameModuleClass = {
	ResolveShowModelCamera: (showModel: Model) -> CFrame,
	new: (
		viewportFrame: ViewportFrame,
		showModel: Model?,
		cameraOffset: CFrame | Vector3?,
		modelOffset: CFrame?
	) -> ViewportFrameModuleInstance?,

	SetViewportFrameColor: (self: ViewportFrameModuleInstance, color: Color3, opacity: number) -> nil,
	CreateViewportFrameShadow: (self: ViewportFrameModuleInstance, shadowOffset: UDim2) -> ViewportFrame?,
	SetViewportFrameModelAnimation: (self: ViewportFrameModuleInstance, animationName: string) -> nil,
	CloseViewportFrameModelAnimation: (self: ViewportFrameModuleInstance) -> nil,
	SetViewportFrameCameraFOV: (self: ViewportFrameModuleInstance, fov: number) -> nil,
	SetViewportFrameLight: (
		self: ViewportFrameModuleInstance,
		ambient: Color3,
		lightColor: Color3,
		lightDirection: Vector3
	) -> nil,
	SetShowModel: (
		self: ViewportFrameModuleInstance,
		showModel: Model,
		cameraOffset: CFrame | Vector3?,
		modelOffset: CFrame?
	) -> nil,
	destroy: (self: ViewportFrameModuleInstance) -> nil,
}

--[[
	解析展示用相机 CFrame

	@param showModel Model - 展示模型
	@return CFrame - 相机 CFrame；模型无效时为默认机位
]]
function ViewportFrameModule.ResolveShowModelCamera(showModel: Model): CFrame
end

--[[
	创建 ViewportFrame 预览实例

	@param viewportFrame ViewportFrame - 目标视口
	@param showModel Model? - 展示模型；nil 则只初始化相机与 WorldModel
	@param cameraOffset CFrame | Vector3? - 相机偏移；nil 时原点
	@param modelOffset CFrame? - 模型 Pivot 偏移；nil 时原点
	@return ViewportFrameModuleInstance? - 预览实例；viewportFrame 无效时 nil
]]
function ViewportFrameModule.new(
	viewportFrame: ViewportFrame,
	showModel: Model?,
	cameraOffset: CFrame | Vector3?,
	modelOffset: CFrame?
): ViewportFrameModuleInstance?
end

--[[
	替换展示模型

	@param self ViewportFrameModuleInstance - 实例
	@param showModel Model - 新展示模型
	@param cameraOffset CFrame | Vector3? - 相机偏移；nil 时原点
	@param modelOffset CFrame? - 模型 Pivot 偏移；nil 时原点
]]
function ViewportFrameModule.SetShowModel(
	self: ViewportFrameModuleInstance,
	showModel: Model,
	cameraOffset: CFrame | Vector3?,
	modelOffset: CFrame?
)
end

--[[
	释放实例

	@param self ViewportFrameModuleInstance - 实例
]]
function ViewportFrameModule.destroy(self: ViewportFrameModuleInstance): nil
end

--[[
	设置 ViewportFrame 着色与透明度

	@param self ViewportFrameModuleInstance - 实例
	@param color Color3 - ImageColor3 颜色
	@param opacity number - ImageTransparency，0 不透明、1 全透明
]]
function ViewportFrameModule.SetViewportFrameColor(self: ViewportFrameModuleInstance, color: Color3, opacity: number): nil
end

--[[
	创建 ViewportFrame 阴影

	@param self ViewportFrameModuleInstance - 实例
	@param shadowOffset UDim2 - 阴影 Position 偏移（仅 Offset 分量）
	@return ViewportFrame? - 阴影视口；destroy 后 nil
]]
function ViewportFrameModule.CreateViewportFrameShadow(self: ViewportFrameModuleInstance, shadowOffset: UDim2): ViewportFrame?
end

--[[
	播放展示模型动画

	@param self ViewportFrameModuleInstance - 实例
	@param animationName string - AnimationModule 配置的动画名称
]]
function ViewportFrameModule.SetViewportFrameModelAnimation(self: ViewportFrameModuleInstance, animationName: string): nil
end

--[[
	停止展示模型动画（历史名 Close，语义为 Stop）

	@param self ViewportFrameModuleInstance - 实例
]]
function ViewportFrameModule.CloseViewportFrameModelAnimation(self: ViewportFrameModuleInstance): nil
end

--[[
	设置相机 FOV

	@param self ViewportFrameModuleInstance - 实例
	@param fov number - 视野角度（度）
]]
function ViewportFrameModule.SetViewportFrameCameraFOV(self: ViewportFrameModuleInstance, fov: number): nil
end

--[[
	设置视口光照

	@param self ViewportFrameModuleInstance - 实例
	@param ambient Color3 - 环境光
	@param lightColor Color3 - 定向光颜色
	@param lightDirection Vector3 - 定向光方向
]]
function ViewportFrameModule.SetViewportFrameLight(
	self: ViewportFrameModuleInstance,
	ambient: Color3,
	lightColor: Color3,
	lightDirection: Vector3
): nil
end

return ViewportFrameModule
