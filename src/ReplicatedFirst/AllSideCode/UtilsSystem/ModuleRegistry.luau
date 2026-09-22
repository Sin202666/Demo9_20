--[[
	Module: ModuleRegistry
	Description: UtilsSystem 内部路径注册表（ToolBasic / ToolSystem / ServerStorage 根）
	Author: 林奥宇
	Created: 2026-09-01
	Last Modified: 2026-09-01

	仅供同目录 init 通过 require(script.ModuleRegistry) 使用。
	业务代码禁止直接 require 本文件；一律走 Utils.键名。

	Create(ctx) 返回三个 registry：键名即 Utils 访问名，值为解析 ModuleScript 的闭包。
	ResolveModuleScript 供 init 解析 Folder+init 与 Rojo ModuleScript 两种形态。
]]

local ModuleRegistry = {}

export type RegistryContext = {
	toolPath: Instance,
	systemPath: Instance,
	allSideCode: Instance,
	serverSystemPath: Instance?,
	serverStoragePath: Instance?,
	isServer: boolean,
	replicatedStorage: ReplicatedStorage,
}

export type ModuleResolver = () -> Instance?

export type Registries = {
	toolModules: { [string]: ModuleResolver },
	systemModules: { [string]: ModuleResolver },
	serverRootModules: { [string]: ModuleResolver },
}

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	将 FindFirstChild 结果收成可 require 的 ModuleScript

	兼容 Rojo「目录即 ModuleScript」与 Folder 下挂 init 子脚本两种形态。
	先认 ModuleScript 本体，避免把容器 resolve 成 init 后再去其子级找兄弟模块。

	@param inst Instance? - FindFirstChild 结果；nil 时返回 nil
	@return ModuleScript? - 可 require 的脚本；无法解析时 nil
]]
local function _resolveModuleScript(inst: Instance?): ModuleScript?
	if not inst then
		return nil
	end
	if inst:IsA("ModuleScript") then
		return inst
	end
	local initChild = inst:FindFirstChild("init")
	if initChild and initChild:IsA("ModuleScript") then
		return initChild
	end
	return nil
end

--[[
	在父级下按名称解析可 require 的 ModuleScript

	@param path Instance - 父级 Instance（ToolBasic / ToolSystem 等）
	@param name string - 子模块名称
	@return ModuleScript? - 找到的 ModuleScript；不存在或无法解析时 nil
]]
local function _getModuleInstance(path: Instance, name: string): ModuleScript?
	return _resolveModuleScript(path:FindFirstChild(name))
end

--[[
	在容器（Folder 或 Rojo ModuleScript）下按子名解析 ModuleScript

	必须先取容器再取子项：若先把容器 resolve 成 init，会丢失与 init 同级的兄弟模块。

	@param containerParent Instance - 容器的父级
	@param containerName string - 容器名称（如 SoundModule / FXUtil）
	@param childName string - 子 ModuleScript 名称
	@return ModuleScript? - 子模块；容器或子项不存在时 nil
]]
local function _getChildModule(containerParent: Instance, containerName: string, childName: string): ModuleScript?
	local container = containerParent:FindFirstChild(containerName)
	if not container then
		return nil
	end
	return _resolveModuleScript(container:FindFirstChild(childName))
end

--[[
	获取 FXUtil 目录下的子 ModuleScript（BezierCurve / BurstStone 等已迁入 FXUtil）

	@param systemPath Instance - ToolSystem 根目录
	@param name string - FXUtil 子 ModuleScript 名称
	@return ModuleScript? - 子模块实例；FXUtil 或子项不存在时 nil
]]
local function _getFXUtilChildModule(systemPath: Instance, name: string): ModuleScript?
	return _getChildModule(systemPath, "FXUtil", name)
end

-- ============================================================================
-- 公共 API
-- ============================================================================

--[[
	解析 Folder+init 或 ModuleScript 本体，供 init 加载器复用

	@param inst Instance? - FindFirstChild 结果
	@return ModuleScript? - 可 require 的脚本；无法解析时 nil
]]
function ModuleRegistry.ResolveModuleScript(inst: Instance?): ModuleScript?
	return _resolveModuleScript(inst)
end

--[[
	按路径上下文构建三类 registry（闭包捕获 ctx，不暴露可变内部表给业务）

	@param ctx RegistryContext - 已解析的 ToolBasic / ToolSystem / 服务端路径与端侧标志
	@return Registries - toolModules / systemModules / serverRootModules
]]
function ModuleRegistry.Create(ctx: RegistryContext): Registries
	local toolPath = ctx.toolPath
	local systemPath = ctx.systemPath
	local allSideCode = ctx.allSideCode
	local serverSystemPath = ctx.serverSystemPath
	local serverStoragePath = ctx.serverStoragePath
	local isServer = ctx.isServer
	local replicatedStorage = ctx.replicatedStorage

	--[[
		服务端优先 ServerSideCode.System；否则走 fallback 或 ToolSystem 同名

		@param name string - System 目录下模块名，与 Utils 键名一致
		@param fallback (() -> ModuleScript?)? - 非服务端或服侧缺失时的解析；nil 则回落 ToolSystem
		@return ModuleScript? - 解析结果；都不存在时 nil
	]]
	local function _preferServerSystemModule(name: string, fallback: (() -> ModuleScript?)?): ModuleScript?
		if isServer and serverSystemPath then
			local serverMod = _resolveModuleScript(serverSystemPath:FindFirstChild(name))
			if serverMod then
				return serverMod
			end
		end
		if fallback then
			return fallback()
		end
		return _getModuleInstance(systemPath, name)
	end

	--[[
		客户端 PlayerAimSync：ClientSideCode.SystemSkill.BaseSkill.PlayerAimSync

		@return ModuleScript? - 客户端瞄准同步模块；路径未就绪时 nil
	]]
	local function _getClientPlayerAimSync(): ModuleScript?
		local clientSide = replicatedStorage:FindFirstChild("ClientSideCode")
		if not clientSide then
			return nil
		end
		local systemSkill = clientSide:FindFirstChild("SystemSkill")
		local baseSkill = systemSkill and systemSkill:FindFirstChild("BaseSkill")
		if not baseSkill then
			return nil
		end
		return _resolveModuleScript(baseSkill:FindFirstChild("PlayerAimSync"))
	end

	local toolModules: { [string]: ModuleResolver } = {
		InsMgr = function()
			return _getModuleInstance(toolPath, "InsMgr")
		end,
		VisibleMgr = function()
			return _getModuleInstance(toolPath, "VisibleMgr")
		end,
		Log = function()
			return _getModuleInstance(toolPath, "Log")
		end,
		MathMgr = function()
			return _getModuleInstance(toolPath, "MathMgr")
		end,
		KeyframeEval = function()
			return _getModuleInstance(toolPath, "KeyframeEval")
		end,
		AnchorRelative = function()
			return _getModuleInstance(toolPath, "AnchorRelative")
		end,
		Copy = function()
			return _getModuleInstance(toolPath, "Copy")
		end,
		ObjectPoolUtil = function()
			return _getModuleInstance(systemPath, "ObjectPoolUtil")
		end,
		HumanModule = function()
			return _getModuleInstance(toolPath, "HumanModule")
		end,
		ResRestore = function()
			return _getModuleInstance(toolPath, "ResRestore")
		end,
		ViewportFrameModule = function()
			return _getModuleInstance(toolPath, "ViewportFrameModule")
		end,
		TimeTransfer = function()
			return _getModuleInstance(toolPath, "TimeTransfer")
		end,
		TranslationHelper = function()
			return _getModuleInstance(toolPath, "TranslationHelper")
		end,
		ConfigInstance = function()
			return _getModuleInstance(toolPath, "ConfigInstance")
		end,
		GameConfig = function()
			return _getModuleInstance(toolPath, "GameConfig")
		end,
		AssetPaths = function()
			return _getModuleInstance(toolPath, "AssetPaths")
		end,
		AssetRegistry = function()
			return _getModuleInstance(toolPath, "AssetRegistry")
		end,
		NetMsg = function()
			return _getModuleInstance(toolPath, "NetMsg")
		end,
		NetChannel = function()
			return _getModuleInstance(toolPath, "NetChannel")
		end,
		NetPipeConfig = function()
			return _getModuleInstance(toolPath, "NetPipeConfig")
		end,
		NetChannelMap = function()
			return _getModuleInstance(toolPath, "NetChannelMap")
		end,
		RankConfig = function()
			return _getModuleInstance(toolPath, "RankConfig")
		end,
		LightingTweenUtil = function()
			return _getModuleInstance(toolPath, "LightingTweenUtil")
		end,
		ChannelResultUtil = function()
			return _getModuleInstance(toolPath, "ChannelResultUtil")
		end,
	}

	local systemModules: { [string]: ModuleResolver } = {
		EnumMgr = function()
			return _getModuleInstance(systemPath, "EnumMgr")
		end,
		AnimationModule = function()
			return _getModuleInstance(systemPath, "AnimationModule")
		end,
		ActionArbiter = function()
			return _getModuleInstance(systemPath, "ActionArbiter")
		end,
		AnimationLayer = function()
			return _getModuleInstance(systemPath, "AnimationLayer")
		end,
		LocoStyle = function()
			return _getModuleInstance(systemPath, "LocoStyle")
		end,
		LocoStyleSets = function()
			return _getModuleInstance(systemPath, "LocoStyleSets")
		end,
		CharacterControl = function()
			return _getModuleInstance(systemPath, "CharacterControl")
		end,
		CharacterMotion = function()
			return _getModuleInstance(systemPath, "CharacterMotion")
		end,
		CfgFind = function()
			return _getModuleInstance(systemPath, "CfgFind")
		end,
		GetData = function()
			return _getModuleInstance(systemPath, "GetData")
		end,
		DeviceType = function()
			return _getModuleInstance(systemPath, "DeviceType")
		end,
		UIMgr = function()
			return _getModuleInstance(systemPath, "UIMgr")
		end,
		UISetMgr = function()
			return _getModuleInstance(systemPath, "UISetMgr")
		end,
		ScrollUtil = function()
			return _getModuleInstance(systemPath, "ScrollUtil")
		end,
		ShowDetail = function()
			return _getModuleInstance(systemPath, "ShowDetail")
		end,
		TipsModule = function()
			return _getModuleInstance(systemPath, "TipsModule")
		end,
		SoundModule = function()
			return _getModuleInstance(systemPath, "SoundModule")
		end,
		Check = function()
			return _getModuleInstance(systemPath, "Check")
		end,
		AssetAcquire = function()
			return _getModuleInstance(systemPath, "AssetAcquire")
		end,
		ResourceUtil = function()
			return _getModuleInstance(systemPath, "ResourceUtil")
		end,
		SkillPreloadUtil = function()
			return _getModuleInstance(systemPath, "SkillPreloadUtil")
		end,
		-- 服务端优先 ServerSideCode.System；客户端回落 ToolSystem stub
		SkillBuffUtil = function()
			return _preferServerSystemModule("SkillBuffUtil")
		end,
		-- 服务端优先；客户端回落 ToolSystem stub（applyHit 为 no-op）
		HitResolver = function()
			return _preferServerSystemModule("HitResolver")
		end,
		-- 服务端优先；客户端回落 ClientSideCode BaseSkill（SkillModule 相对 require 同一文件）
		PlayerAimSync = function()
			return _preferServerSystemModule("PlayerAimSync", _getClientPlayerAimSync)
		end,
		CombatWorld = function()
			return _getModuleInstance(systemPath, "CombatWorld")
		end,
		EnemyLogicalStore = function()
			return _getModuleInstance(systemPath, "EnemyLogicalStore")
		end,
		EnemyLogicalTypes = function()
			return _getModuleInstance(systemPath, "EnemyLogicalTypes")
		end,
		EnemyLogicalSync = function()
			return _getModuleInstance(systemPath, "EnemyLogicalSync")
		end,
		EnemySim = function()
			return _getModuleInstance(systemPath, "EnemySim")
		end,
		LogicalHitValidate = function()
			return _getModuleInstance(systemPath, "LogicalHitValidate")
		end,
		LogicEntityMotion = function()
			return _getModuleInstance(systemPath, "LogicEntityMotion")
		end,
		RangerAi = function()
			return _getModuleInstance(systemPath, "RangerAi")
		end,
		LogicalMoveCommand = function()
			return _getModuleInstance(systemPath, "LogicalMoveCommand")
		end,
		PathFindUtil = function()
			return _getModuleInstance(systemPath, "PathFindUtil")
		end,
		LogicalPathFollow = function()
			return _getModuleInstance(systemPath, "LogicalPathFollow")
		end,
		LogicalDisplaceProfile = function()
			return _getModuleInstance(systemPath, "LogicalDisplaceProfile")
		end,
		LogicalDisplace = function()
			return _getModuleInstance(systemPath, "LogicalDisplace")
		end,
		LogicalAirborneProfile = function()
			return _getModuleInstance(systemPath, "LogicalAirborneProfile")
		end,
		LogicalAirborne = function()
			return _getModuleInstance(systemPath, "LogicalAirborne")
		end,
		-- 服务端优先 ServerSideCode.System；客户端回落 ToolSystem 播轨
		SkillHitPresentation = function()
			return _preferServerSystemModule("SkillHitPresentation")
		end,
		-- 服务端优先 ServerSideCode.System；客户端回落 ToolSystem 播轨
		NPCCosmeticHit = function()
			return _preferServerSystemModule("NPCCosmeticHit")
		end,
		CameraImpulse = function()
			return _getModuleInstance(systemPath, "CameraImpulse")
		end,
		FindPlayerByID = function()
			return _getModuleInstance(systemPath, "FindPlayerByID")
		end,
		SkillSyncLog = function()
			return _getModuleInstance(allSideCode, "SkillSyncLog")
		end,
		GmEmailWhitelist = function()
			return _getModuleInstance(allSideCode, "GmEmailWhitelist")
		end,
		Struct = function()
			local classFolder = allSideCode:FindFirstChild("Class")
			if not classFolder then
				return nil
			end
			return _resolveModuleScript(classFolder:FindFirstChild("Struct"))
		end,
		SkillNet = function()
			return _getModuleInstance(systemPath, "SkillNet")
		end,
		MountNet = function()
			return _getModuleInstance(systemPath, "MountNet")
		end,
		AutoBattleNet = function()
			return _getModuleInstance(systemPath, "AutoBattleNet")
		end,
		AddListen = function()
			return _getModuleInstance(systemPath, "AddListen")
		end,
		RequestRateLimit = function()
			return _getModuleInstance(systemPath, "RequestRateLimit")
		end,
		UIanima = function()
			return _getModuleInstance(systemPath, "UIanima")
		end,
		SequenceManager = function()
			return _getModuleInstance(systemPath, "SequenceManager")
		end,
		-- UISequence 与 SequenceManager 同模块（商业命名别名）
		UISequence = function()
			return _getModuleInstance(systemPath, "SequenceManager")
		end,
		SpeedLineFX = function()
			return _getModuleInstance(systemPath, "SpeedLineFX")
		end,
		WorldUtil = function()
			return _getModuleInstance(systemPath, "WorldUtil")
		end,
		SoundInstance = function()
			return _getChildModule(systemPath, "SoundModule", "SoundInstance")
		end,
		FootstepSoundsConfig = function()
			return _getChildModule(systemPath, "FootstepSound", "FootstepSoundsConfig")
		end,
		TipsRenderer = function()
			return _getChildModule(systemPath, "TipsModule", "TipsRenderer")
		end,
		TipsConfig = function()
			return _getChildModule(systemPath, "TipsModule", "TipsConfig")
		end,
		BezierCurve = function()
			return _getFXUtilChildModule(systemPath, "BezierCurve")
		end,
		BurstStone = function()
			return _getFXUtilChildModule(systemPath, "BurstStone")
		end,
		FloorWave = function()
			return _getModuleInstance(systemPath, "FloorWave")
		end,
		FXUtil = function()
			return _getModuleInstance(systemPath, "FXUtil")
		end,
		GhostShadow = function()
			return _getFXUtilChildModule(systemPath, "GhostShadow")
		end,
		Lightning = function()
			return _getFXUtilChildModule(systemPath, "Lightning")
		end,
		-- 与 FXUtil.PartIcles 同一门面 ModuleScript（幂等 Activate + 完整引擎 API 转发）
		PartIcles = function()
			return _getFXUtilChildModule(systemPath, "PartIcles")
		end,
		HatchEffect = function()
			return _getModuleInstance(systemPath, "HatchEffect")
		end,
		ItemEffect = function()
			return _getModuleInstance(systemPath, "ItemEffect")
		end,
		PlayerData = function()
			return _getModuleInstance(systemPath, "PlayerData")
		end,
		RayCast = function()
			return _getModuleInstance(systemPath, "RayCast")
		end,
		NetWork = function()
			return _getModuleInstance(systemPath, "NetWork")
		end,
		-- 服务端优先 ServerSideCode.System；客户端回落 ToolSystem stub
		SystemEnemy = function()
			return _preferServerSystemModule("SystemEnemy")
		end,
		SystemSummon = function()
			return _getModuleInstance(systemPath, "SystemSummon")
		end,
		SystemPlrAttr = function()
			return _preferServerSystemModule("SystemPlrAttr")
		end,
		-- SystemCharacterMotion：仅 ServerSideCode.System，由 __index 服务端动态发现加载；勿挂 systemModules（无客户端回落，挂表会触发路径 warn）
		SystemGameConfig = function()
			return _getModuleInstance(systemPath, "SystemGameConfig")
		end,
		-- RP17 技能运行时别名：GameGlobalConfig → SystemGameConfig（同一 Get/GetValue API）
		GameGlobalConfig = function()
			return _getModuleInstance(systemPath, "SystemGameConfig")
		end,
		UpdateModule = function()
			return _getModuleInstance(systemPath, "UpdateModule")
		end,
	}

	local serverRootModules: { [string]: ModuleResolver } = {
		GameAnalytics = function()
			if not serverStoragePath then
				return nil
			end
			return _resolveModuleScript(serverStoragePath:FindFirstChild("GameAnalytics"))
		end,
	}

	return {
		toolModules = toolModules,
		systemModules = systemModules,
		serverRootModules = serverRootModules,
	}
end

return ModuleRegistry
