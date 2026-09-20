--[[
	Module: FXUtil/GhostShadow
	Description: 模型残影视觉暂留（单次/连续/开关状态）
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

local module = {}

-- ============================================================================
-- 导入和依赖
-- ============================================================================

-- Services
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

-- UtilsSystem - 统一模块访问接口
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

-- Modules (通过 UtilsSystem 延迟加载)
local VisibleMgr = Utils.VisibleMgr
local InsMgr = Utils.InsMgr

-- Ghost_Shadow_On 的 RenderStepped 连接（按模型索引，Off/离树时断开）
local _ghostStepConns: { [Instance]: RBXScriptConnection } = {}

--[[
	断开并清理指定模型的残影 RenderStepped 连接
]]
local function _disconnectGhostStep(_oriModel: Instance)
	local conn = _ghostStepConns[_oriModel]
	if conn then
		conn:Disconnect()
		_ghostStepConns[_oriModel] = nil
	end
end

-- ============================================================================
-- 内部辅助函数
-- ============================================================================

--[[
	清理残影克隆体上不需要的脚本/GUI/贴图等
	@param shadow Model
]]
local function _cleanupUnwantedInstances(shadow: Model)
	-- 清理子对象
	for k, v in pairs(shadow:GetChildren()) do
		if v:IsA("LocalScript") or v:IsA("BillboardGui") then
			v:Destroy()
		end
	end
	
	-- 清理所有后代中的不需要的实例
	local descendants = shadow:GetDescendants()
	for k, v in pairs(descendants) do
		if v:IsA("Shirt") or
		   v:IsA("Pants") or
		   v:IsA("Decal") or
		   v:IsA("ParticleEmitter") or
		   v:IsA("Beam") or
		   v:IsA("BillboardGui") or
		   v:IsA("SurfaceGui") or
		   v:IsA("Texture") then
			Debris:AddItem(v, 0)
		end
	end
end

--[[
	设置残影 Neon 材质与颜色
	@param shadow Model
	@param color Color3
	@param transPercent number
]]
local function _setupShadowAppearance(shadow: Model, color: Color3, transPercent: number)
	local shadowVt = shadow:GetDescendants()
	table.insert(shadowVt, shadow)
	
	for k, v in pairs(shadowVt) do
		-- 处理MeshPart
		if v:IsA("MeshPart") then
			v.Transparency = v.Transparency + (1 - v.Transparency) * transPercent
			v.Material = Enum.Material.Neon
			v.TextureID = ""
			v.Color = color
		end
		
		-- 处理Part
		if v:IsA("Part") then
			v.Transparency = v.Transparency + (1 - v.Transparency) * transPercent
			v.Material = Enum.Material.Neon
			v.Color = color
		end
		
		-- 处理SpecialMesh
		if v:IsA("SpecialMesh") then
			v.TextureId = ""
		end
	end
end

--[[
	残影 BasePart 透明度渐隐至 1
	@param shadow Model
	@param lifeTime number
]]
local function _applyFadeEffect(shadow: Model, lifeTime: number)
	local shadowVt = shadow:GetDescendants()
	table.insert(shadowVt, shadow)
	
	for k, v in pairs(shadowVt) do
		if v:IsA("BasePart") then
			local tween = TweenService:Create(v, TweenInfo.new(lifeTime), {Transparency = 1})
			tween:Play()
		end
	end
end

-- ============================================================================
-- 公共API
-- ============================================================================

--[[
	生成单个残影（视觉暂留效果）
	@param _oriModel: Model - 原始模型
	@param _lifeTime: number? - 生命周期（秒），默认0.5
	@param _color: Color3? - 残影颜色，默认黑色
	@param _transPrecent: number? - 透明度百分比，默认0.5
	@param _Scale: number? - 缩放比例，默认1
]]
function module.Spawn_Normal_Ghost(
	_oriModel: Model,
	_lifeTime: number?,
	_color: Color3?,
	_transPrecent: number?,
	_Scale: number?
)
	-- 参数验证和默认值
	if not _oriModel then
		return
	end
	
	_color = _color or Color3.new(0, 0, 0)
	_lifeTime = _lifeTime or 0.5
	_transPrecent = _transPrecent or 0.5
	_Scale = _Scale or 1

	-- 克隆模型
	_oriModel.Archivable = true
	local shadow: Model = _oriModel:Clone()
	_oriModel.Archivable = false
	
	-- 移除标签
	if shadow.PrimaryPart then
		shadow.PrimaryPart:RemoveTag("NameTag")
	end
	
	-- 清理不需要的实例
	_cleanupUnwantedInstances(shadow)
	
	-- 设置名称和父级
	shadow.Name = _oriModel.Name.."Shadow"
	shadow.Parent = workspace
	
	-- 设置物理属性
	VisibleMgr.AnchoredAll(shadow)
	VisibleMgr.UnQueryAll(shadow)
	VisibleMgr.UnCollideAll(shadow)
	VisibleMgr.UnTouchAll(shadow)
	VisibleMgr.SetPlayerCollideID(shadow)
	
	-- 应用缩放
	shadow:ScaleTo(_Scale :: number)
	
	-- 设置外观
	_setupShadowAppearance(shadow, _color :: Color3, _transPrecent :: number)
	
	-- 应用渐隐效果
	_applyFadeEffect(shadow, _lifeTime :: number)
	
	-- 延迟销毁
	task.delay(_lifeTime :: number, function()
		Debris:AddItem(shadow, 0)
	end)
end

--[[
	生成多个残影
	@param _oriModel: Model - 原始模型
	@param _lifeTime: number? - 生命周期（秒）
	@param _color: Color3? - 残影颜色
	@param _transPrecent: number? - 透明度百分比
	@param _spawnTime: number? - 生成次数，默认1
	@param _spawnInterval: number? - 生成间隔（秒），默认0.5
]]
function module.Spawn_Several_Ghosts(
	_oriModel: Model,
	_lifeTime: number?,
	_color: Color3?,
	_transPrecent: number?,
	_spawnTime: number?,
	_spawnInterval: number?
)
	_spawnTime = _spawnTime or 1
	_spawnInterval = _spawnInterval or 0.5

	task.spawn(function()
		for i = 1, (_spawnTime :: number) do
			if _oriModel then
				module.Spawn_Normal_Ghost(_oriModel, _lifeTime, _color, _transPrecent)
			end
			task.wait(_spawnInterval :: number)
		end
	end)
end

--[[
	开启残影状态（持续生成残影）
	@param _oriModel: Model - 原始模型
	@param _lifeTime: number? - 生命周期（秒）
	@param _color: Color3? - 残影颜色
	@param _transPrecent: number? - 透明度百分比
	@param _spawnInterval: number? - 生成间隔（秒）
]]
function module.Ghost_Shadow_On(
	_oriModel: Model,
	_lifeTime: number?,
	_color: Color3?,
	_transPrecent: number?,
	_spawnInterval: number?
)
	if not _oriModel then
		return
	end

	local GhostShadow = InsMgr.GetIns("GhostShadow", "BoolValue", _oriModel)
	if GhostShadow.Value then
		return -- 已经开启
	end
	
	GhostShadow.Value = true

	_disconnectGhostStep(_oriModel)

	local time = 0
	local spawnInterval = _spawnInterval or 0.1
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function(dt)
		if not _oriModel.Parent or not GhostShadow.Parent or GhostShadow.Value == false then
			_disconnectGhostStep(_oriModel)
			return
		end

		if time >= spawnInterval then
			module.Spawn_Normal_Ghost(_oriModel, _lifeTime, _color, _transPrecent)
			time = 0
		end

		time += dt
	end)
	_ghostStepConns[_oriModel] = conn
end

--[[
	关闭残影状态
	@param _oriModel: Model - 原始模型
]]
function module.Ghost_Shadow_Off(_oriModel: Model)
	if not _oriModel then
		return
	end

	local ghostFlag = _oriModel:FindFirstChild("GhostShadow")
	if ghostFlag and ghostFlag:IsA("BoolValue") then
		ghostFlag.Value = false
	end
	_disconnectGhostStep(_oriModel)
end

return module
