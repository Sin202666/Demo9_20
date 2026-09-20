--[[
	Module: BaseSkillRuntimeHost
	Description: 技能运行时宿主（state / control / hitbox / material / 时钟）
	Author: 林奥宇
	Created: 2026-07-29
	Last Modified: 2026-08-12

	调用方：BaseSkillClient / BaseSkillServer 在 new() 时创建 controlRuntime，start 时初始化其余。
	时钟：一期 A 起经 CombatWorld.register，禁止本模块内 Heartbeat:Connect。

	加载：由 BaseSkillClient / BaseSkillServer require(script.Parent.BaseSkillRuntimeHost)
]]
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local CombatWorld = Utils.CombatWorld
local FXUtil = Utils.FXUtil
local ResRestore = Utils.ResRestore
local SkillStateRuntime = require(script.Parent.SkillStateRuntime)
local SkillControlRuntime = require(script.Parent.SkillControlRuntime)
local SkillHitboxRuntime = require(script.Parent.SkillHitboxRuntime)

local BaseSkillRuntimeHost = {}

--[[
	创建运行时宿主（仅 controlRuntime 在此时创建）
	@param definition table - { skillModule, skillName }
	@param options table? - { isClient, getActionsOverCheck }
	@return table - host { controlRuntime, runData, hitboxRuntime, timeConnection, clockId }
]]
function BaseSkillRuntimeHost.create(definition, options)
	options = options or {}
	local skillModule = definition and definition.skillModule
	return {
		controlRuntime = SkillControlRuntime.create(skillModule, {
			isClient = options.isClient,
			getActionsOverCheck = options.getActionsOverCheck,
		}),
		runData = nil,
		hitboxRuntime = nil,
		timeConnection = nil,
		clockId = nil,
	}
end

--[[
	初始化运行数据（State、Visual、Logic、material）
	@param host table - 由 create 返回
	@param definition table - { skillModule, skillName }
	@param options table? - { isClient, skillResFolder } 客户端需传 skillResFolder
	@return table - runData
]]
function BaseSkillRuntimeHost.initMaterial(host, definition, options)
	options = options or {}
	local skillModule = definition.skillModule
	local runData = {
		material = {},
		runEvent = {},
		hitbox = {},
	}

	if skillModule.States and skillModule.InitialState then
		runData.State = SkillStateRuntime.createStateData(skillModule)
		runData.Visual = options.isClient and {
			projectileModel = nil,
			projectileMotion = nil,
			explosionPlayed = false,
			pendingProjectileHitEvent = nil,
		} or {}
		runData.Logic = {
			hasExploded = false,
			projectileHitboxMotion = nil,
			projectileLastPosition = nil,
			impactPosition = nil,
			impactType = nil,
			impactTargetId = nil,
		}
	end

	if options.isClient and options.skillResFolder then
		local resNameList = skillModule.ResNameList or {}
		for _, materialName in resNameList do
			local _material = options.skillResFolder:FindFirstChild(materialName)
			if _material then
				local clone = FXUtil.GetInstance_From_Pool(_material)
				if clone and clone:IsA("Model") then
					if ResRestore and ResRestore.Restore then
						ResRestore.Restore(clone)
					end
					clone.Parent = nil
					runData.material[_material.Name] = clone
				end
			end
		end
	end

	host.runData = runData
	return runData
end

--[[
	创建 Hitbox 运行时
	@param host table - 运行时宿主
	@param skillInstance table - 技能实例（提供 skillModule, skillName, skillInputData, combatSeed）
	@param inputData table - { characterId, characterType, combatSeed }
	@return table - hitbox instances
]]
function BaseSkillRuntimeHost.initHitbox(host, skillInstance, inputData)
	host.hitboxRuntime = SkillHitboxRuntime.create(skillInstance)
	SkillHitboxRuntime.spawnAll(host.hitboxRuntime, inputData)
	return host.hitboxRuntime.instances
end

--[[
	启动时钟（注册到 CombatWorld；不再 Heartbeat:Connect）
	@param host table - 运行时宿主
	@param _runService any - 兼容旧调用方，已忽略
	@param tickFn (deltaTime: number) -> () - 每帧回调
	@return table - CombatWorld Handle（含 Disconnect）
]]
function BaseSkillRuntimeHost.startClock(host, _runService, tickFn)
	BaseSkillRuntimeHost.stopClock(host)
	local clockId = CombatWorld.allocId("BaseSkillClock")
	host.clockId = clockId
	host.timeConnection = CombatWorld.register(clockId, tickFn, CombatWorld.Phase.SkillRuntime)
	return host.timeConnection
end

--[[
	停止时钟（从 CombatWorld 注销；幂等）
	@param host table - 运行时宿主
]]
function BaseSkillRuntimeHost.stopClock(host)
	local clockId = host.clockId
	local handle = host.timeConnection
	host.clockId = nil
	host.timeConnection = nil
	if clockId then
		CombatWorld.unregister(clockId)
	end
	-- 调用方可能仍持有 handle 并再 Disconnect；标记 Connected 使其幂等
	if type(handle) == "table" then
		handle.Connected = false
	elseif typeof(handle) == "RBXScriptConnection" then
		handle:Disconnect()
	end
end

--[[
	销毁 Hitbox
	@param host table - 运行时宿主
]]
function BaseSkillRuntimeHost.destroyHitbox(host)
	if host.hitboxRuntime then
		SkillHitboxRuntime.destroyAll(host.hitboxRuntime)
		host.hitboxRuntime = nil
	end
end

--[[
	重置 controlRuntime
	@param host table - 运行时宿主
]]
function BaseSkillRuntimeHost.resetControl(host)
	SkillControlRuntime.reset(host.controlRuntime)
end

return BaseSkillRuntimeHost