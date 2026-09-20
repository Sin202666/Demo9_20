--[[
	Module: SystemLightingWeather
	Description: 客户端天气基线 / lease / overlay reconcile 编排；视觉时钟经本模块转发
	Author: 林奥宇
	Created: 2026-08-04
	Last Modified: 2026-08-31

	功能：
	- baseline（世界）+ lease 栈（技能/副本等）；生效层 = 最高 priority lease，否则 baseline
	- 写者优先级（通道侧）：FxLease(CC) > CustomOverlay > WeatherBase（本模块负责后两层编排）
	- reconcile 三态：Overlay applied/held 不回退天气；仅 none 走天气包
	- 全量 apply：天气失败 / overlay 硬 held 写 LightingLastError；FxBusy/QualitySkip 只写 SkipReason
	- 同帧 defer coalesce（见 ApplyCoalesce）；时钟不合并；transitionTime last-wins
	- Acquire / setBaseline 返回 true = 请求已接受；画面经 coalesce 异步落地
	  判断落地：Pending==false 且 LightingAppliedName==CurrentLightingName 且 LastError==nil
	- 同 writer 过密 force / lease 上限 / TTL·StaleWarn·HardMax（见 LeaseLifecycle）
	- reapplyEffective：绕过同名短路强制重放（GM / 画质切换 / 资源热更）
	- Acquire fail-closed：非法 priority（含 Baseline）/ 缺配置 / schema 失败不建 lease
	- 缺配置 apply：保留上一画面；BootReady fail-soft；createForOwner 失败降级单例
	- GraphicsQuality 低档：QualityGate → SystemLighting；低→高须 reapplyEffective
	- 生产全量/增量 apply 仅经 ApplyCoalesce；ApplyPipeline.applyEffectiveIfChanged 仅同步/测试辅助

	时钟：
	- 服端 ClockAuthority 为权威；本模块 setClockTime / getClockTime 为客户端视觉目标缓存
	- 业务勿绕过 lease 直写天气通道；业务仅经 LightingManager Bindable

	调试 Attribute（见 DebugAttrs）：
	- CurrentLightingName（意图）/ LightingAppliedName（落地）/ Baseline / LeaseCount / TopWriter
	- LightingLastError / OverlayTop / SkipReason / StaleLeaseWriters / ApplyPending / BootReady

	子模块：
	- LeaseStack / ApplyPipeline / ApplyCoalesce / LeaseLifecycle / QualityGate / DebugAttrs

	单例：应由 LightingManager 经 Init() 唯一持有；内部经 createForOwner 创建 Lighting / CustomState

	使用（仅 LightingManager）：
	local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	local weather = Utils.SystemLightingWeather.Init()
	weather:acquireLease("SpaceSkill1", "空间技能", 0.25, Utils.EnumMgr.WeatherWriterPriority.Skill, false, 30)
	weather:releaseLease("SpaceSkill1", 0.5)
	weather:reapplyEffective(0)
	-- 健康检查：game.Lighting:GetAttribute("LightingBootReady") == true
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log
local ReplicatedStorage = Utils.ReplicatedStorage
local SystemLighting = Utils.SystemLighting
local SystemLightingCustomState = Utils.SystemLightingCustomState
local Lighting = Utils.Lighting
local EnumMgr = Utils.EnumMgr
local LightingTweenUtil = Utils.LightingTweenUtil
local LeaseStack = require(script.LeaseStack)
local ApplyPipeline = require(script.ApplyPipeline)
local ApplyCoalesce = require(script.ApplyCoalesce)
local LeaseLifecycle = require(script.LeaseLifecycle)
local QualityGate = require(script.QualityGate)
local DebugAttrs = require(script.DebugAttrs)

-- ========================================
-- 常量 / 类型
-- ========================================
local ATTRS: ApplyPipeline.AttrNames = DebugAttrs

local DEFAULT_LIGHTING_NAME = "Day"
local CC_CLASS_NAME = "ColorCorrectionEffect"
local WeatherAcquireForceMinIntervalSec = EnumMgr.WeatherAcquireForceMinIntervalSec
local WeatherMaxActiveLeases = EnumMgr.WeatherMaxActiveLeases
local DEFAULT_MAX_ACTIVE_LEASES = 16
local FALLBACK_FORCE_MIN_SEC = 0.05

export type WeatherLease = LeaseStack.WeatherLease
export type WeatherLeaseSnapshot = LeaseStack.WeatherLeaseSnapshot

export type SystemLightingWeather = {
	new: (self: SystemLightingWeather) -> SystemLightingWeather,
	Init: (self: SystemLightingWeather) -> SystemLightingWeather,
	setClockTime: (self: SystemLightingWeather, clockTime: number, transitionTime: number?) -> (),
	getClockTime: (self: SystemLightingWeather) -> number,
	reportClientError: (self: SystemLightingWeather, message: string?) -> (),
	hasLease: (self: SystemLightingWeather, writerId: string) -> boolean,
	getActiveLeases: (self: SystemLightingWeather) -> { WeatherLeaseSnapshot },
	setBaseline: (self: SystemLightingWeather, lightingName: string, transitionTime: number) -> boolean,
	acquireLease: (
		self: SystemLightingWeather,
		writerId: string,
		lightingName: string,
		transitionTime: number,
		priority: number?,
		force: boolean?,
		ttl: number?
	) -> boolean,
	releaseLease: (self: SystemLightingWeather, writerId: string, transitionTime: number) -> boolean,
	forceClearLeases: (self: SystemLightingWeather, maxPriority: number?, transitionTime: number) -> boolean,
	reapplyEffective: (self: SystemLightingWeather, transitionTime: number) -> boolean,
	reconcileChannel: (self: SystemLightingWeather, className: string, transitionTime: number) -> (),
	onFxCcBusyReleased: (self: SystemLightingWeather) -> (),
	sweepExpiredLeases: (self: SystemLightingWeather) -> (),
	setCustomStateAndReconcile: (
		self: SystemLightingWeather,
		customName: string,
		nowState: boolean,
		transitionTime: number
	) -> boolean,
	destroy: (self: SystemLightingWeather) -> nil,
}

-- ========================================
-- 模块定义
-- ========================================
local SystemLightingWeather = {}
SystemLightingWeather.__index = SystemLightingWeather

local _singleton: SystemLightingWeather? = nil
local _didInitApply = false

-- ========================================
-- 私有函数
-- ========================================
--[[
	当前 host 是否仍是有效单例（destroy / 换实例后作废已 defer 的回调）

	@param host any - Weather 实例，与模块级 _singleton 比较
	@return boolean - true 表示仍是当前单例
]]
local function _isLive(host: any): boolean
	return _singleton == host
end

local _coalesceDeps: ApplyCoalesce.CoalesceDeps = {
	attrs = ATTRS,
	isLive = _isLive,
}

local _lifecycleDeps: LeaseLifecycle.LifecycleDeps = {
	attrs = ATTRS,
	isLive = _isLive,
	applyIfChanged = function(host: any, transitionTime: number, force: boolean?)
		return ApplyCoalesce.applyEffectiveIfChangedCoalesced(host, _coalesceDeps, transitionTime, force)
	end,
}

--[[
	记录或清空最近错误 Attribute

	@param message string? - 错误文案；nil 表示清空
	@return nil - 无返回值
]]
local function _setLastError(message: string?)
	ApplyPipeline.setLastError(ATTRS.lastError, message)
end

--[[
	编排层是否可用（createForOwner 成功）

	@param self SystemLightingWeather - 实例
	@return boolean - true 可写通道
]]
local function _isReady(self: SystemLightingWeather): boolean
	return self._degraded ~= true and self._lightingSystem ~= nil and self._customState ~= nil
end

--[[
	未就绪时写 LastError 并返回 false

	@param self SystemLightingWeather - 实例
	@param opName string - 操作名（日志）
	@return boolean - 恒 false
]]
local function _rejectIfNotReady(self: SystemLightingWeather, opName: string): boolean
	Log.warn("SystemLightingWeather: 降级态拒绝操作", opName)
	_setLastError("Weather 降级：createForOwner 失败")
	return false
end

--[[
	同步 LightingBootReady（编排可用且 Config 目录存在）

	@param self SystemLightingWeather - 实例
	@return nil - 无返回值
]]
local function _syncBootReady(self: SystemLightingWeather)
	local ready = _isReady(self) and self._configFolder ~= nil
	local attrName = ATTRS.bootReady
	if attrName then
		Lighting:SetAttribute(attrName, ready)
	end
	if not ready and not self._bootFailLogged then
		self._bootFailLogged = true
		local reason = if not _isReady(self)
			then "Weather 降级：createForOwner 失败"
			else "缺少 Assets.LightingConfig（上线须阻断）"
		Log.warn("SystemLightingWeather: BootReady=false", reason)
		_setLastError(reason)
	end
end

--[[
	调度 lease 维护（TTL / StaleWarn / HardMax）

	@param self SystemLightingWeather - 实例
	@return nil - 无返回值
]]
local function _scheduleLeaseSweep(self: SystemLightingWeather)
	LeaseLifecycle.scheduleSweep(self, _lifecycleDeps, function(host)
		(host :: SystemLightingWeather):sweepExpiredLeases()
	end)
end

--[[
	写入启动期调试 Attribute 初值

	@param self SystemLightingWeather - 实例
	@return nil - 无返回值
]]
local function _resetDebugAttrs(self: SystemLightingWeather)
	Lighting:SetAttribute(ATTRS.currentLighting, self._baselineName)
	if ATTRS.appliedLighting then
		Lighting:SetAttribute(ATTRS.appliedLighting, nil)
	end
	Lighting:SetAttribute(ATTRS.baselineLighting, self._baselineName)
	Lighting:SetAttribute(ATTRS.leaseCount, 0)
	Lighting:SetAttribute(ATTRS.topLeaseWriter, nil)
	Lighting:SetAttribute(ATTRS.overlayTop, nil)
	Lighting:SetAttribute(ATTRS.skipReason, nil)
	if ATTRS.staleLeaseWriters then
		Lighting:SetAttribute(ATTRS.staleLeaseWriters, nil)
	end
	ApplyCoalesce.setApplyPending(ATTRS, false)
end

-- ========================================
-- 公共函数
-- ========================================
--[[
	初始化天气编排单例（重复 new 返回同一实例）

	@return SystemLightingWeather - 实例；createForOwner 失败时为降级单例（API 拒绝写）
]]
function SystemLightingWeather.new()
	if _singleton then
		Log.warn("SystemLightingWeather: 重复 new，返回已有单例（应由 LightingManager 唯一持有）")
		return _singleton
	end

	local self = setmetatable({}, SystemLightingWeather)
	self._degraded = false
	self._bootFailLogged = false
	self._forceAcquireAt = {} :: { [string]: number }
	self._staleWarnedWriters = {} :: { [string]: boolean }
	self._baselineName = DEFAULT_LIGHTING_NAME
	-- 尚未成功 apply；勿预填默认名，否则缺配置失败后同名短路粘住
	self._effectiveName = ""
	self._leases = {} :: { [string]: WeatherLease }
	self._leaseOrderSeq = 0
	self._sweepToken = 0
	self._applyCoalesceToken = 0
	self._pendingFullApply = false
	self._pendingApplyTransition = nil :: number?
	self._pendingReconcileChannels = {} :: { [string]: boolean }
	self._qualityGate = QualityGate.createState()
	self._configFolder = nil

	local lightingSystem = SystemLighting.createForOwner("SystemLightingWeather")
	local customState = SystemLightingCustomState.createForOwner("SystemLightingWeather")
	if not lightingSystem or not customState then
		if lightingSystem then
			lightingSystem:destroy()
		end
		if customState then
			customState:destroy()
		end
		Log.warn("SystemLightingWeather: createForOwner 失败，进入降级态（不中断启动）")
		self._degraded = true
		self._lightingSystem = nil
		self._customState = nil
		_resetDebugAttrs(self)
		_setLastError("Weather 降级：createForOwner 失败")
		_syncBootReady(self)
		_singleton = self
		return self
	end

	self._lightingSystem = lightingSystem
	self._customState = customState

	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local configFolder = if assets then assets:FindFirstChild("LightingConfig") else nil
	if configFolder and configFolder:IsA("Folder") then
		self._configFolder = configFolder :: Folder
	else
		self._configFolder = nil
		Log.warn("SystemLightingWeather: 缺少 Assets.LightingConfig，天气 apply 降级（BootReady=false）")
		_setLastError("缺少 LightingConfig 目录")
	end

	_resetDebugAttrs(self)
	if self._configFolder then
		Lighting:SetAttribute(ATTRS.lastError, nil)
	end
	_syncBootReady(self)

	QualityGate.bind(self._qualityGate, function(isLow: boolean)
		if not _isReady(self) then
			return
		end
		self._lightingSystem:setGraphicsQualityLow(isLow)
		if _didInitApply then
			self:reapplyEffective(0)
		end
	end)
	self._lightingSystem:setGraphicsQualityLow(QualityGate.getIsLow(self._qualityGate))

	_singleton = self
	return self
end

--[[
	Manager 调用：确保单例并做首次天气 apply（同步，不经 coalesce）

	@return SystemLightingWeather - 实例
]]
function SystemLightingWeather.Init()
	local self = SystemLightingWeather.new()
	if not _didInitApply then
		_didInitApply = true
		if _isReady(self) then
			ApplyPipeline.applyEffectiveWeather(self, ATTRS, 0)
		end
	end
	return self
end

--[[
	设置视觉时钟（转发 SystemLighting；transition 内部 normalize）

	@param clockTime number - 时钟时间（0–24，内部 clamp）
	@param transitionTime number? - 过渡时间（秒）；nil/0 立即生效
	@return nil - 无返回值
]]
function SystemLightingWeather.setClockTime(self: SystemLightingWeather, clockTime: number, transitionTime: number?)
	if not _isReady(self) then
		_rejectIfNotReady(self, "setClockTime")
		return
	end
	self._lightingSystem:setClockTime(clockTime, LightingTweenUtil.normalizeTransitionTime(transitionTime))
end

--[[
	读取缓存的逻辑时钟（客户端目标值；Tween 中途可与服务 ClockTime 不一致）

	@return number - 最近一次 setClockTime 的目标值（0–24）；降级态为 0
]]
function SystemLightingWeather.getClockTime(self: SystemLightingWeather): number
	if not _isReady(self) then
		return 0
	end
	return self._lightingSystem:getClockTime()
end

--[[
	写入或清空 LightingLastError（Manager / 本模块唯一入口）

	@param message string? - 错误文案；nil 表示清空
	@return nil - 无返回值
]]
function SystemLightingWeather.reportClientError(self: SystemLightingWeather, message: string?)
	_setLastError(message)
end

--[[
	查询指定 writer 是否持有 lease

	@param writerId string - 写者标识
	@return boolean - 是否存在于 _leases
]]
function SystemLightingWeather.hasLease(self: SystemLightingWeather, writerId: string): boolean
	return self._leases[writerId] ~= nil
end

--[[
	返回当前全部 lease 的深拷贝快照（调试 / GM；勿依赖字段可变）

	@return {WeatherLeaseSnapshot} - 只读快照数组
]]
function SystemLightingWeather.getActiveLeases(self: SystemLightingWeather): { WeatherLeaseSnapshot }
	return LeaseStack.snapshotLeases(self._leases)
end

--[[
	设置世界 baseline；无更高 lease 时才 apply

	@param lightingName string - 天气配置名
	@param transitionTime number - 过渡时间（秒）
	@return boolean - true=baseline 已接受；落地见 AppliedName/Pending/LastError。false=缺配置/降级
]]
function SystemLightingWeather.setBaseline(self: SystemLightingWeather, lightingName: string, transitionTime: number): boolean
	if not _isReady(self) then
		return _rejectIfNotReady(self, "setBaseline")
	end
	transitionTime = LightingTweenUtil.normalizeTransitionTime(transitionTime)
	if not ApplyPipeline.findLightingConfig(self, lightingName, ATTRS.lastError) then
		Log.warn("SystemLightingWeather: 缺少天气配置", lightingName)
		if self._configFolder == nil then
			_setLastError("缺少 LightingConfig 目录")
		elseif Lighting:GetAttribute(ATTRS.lastError) == nil then
			_setLastError("缺少天气配置: " .. lightingName)
		end
		return false
	end

	if self._baselineName == lightingName then
		ApplyPipeline.syncLightingNameAttributes(self, ATTRS)
		return true
	end

	self._baselineName = lightingName
	Lighting:SetAttribute(ATTRS.baselineLighting, self._baselineName)
	_setLastError(nil)

	if LeaseStack.getWinningLease(self._leases) == nil then
		ApplyCoalesce.requestFullApply(self, _coalesceDeps, transitionTime)
		return true
	end
	ApplyPipeline.syncLightingNameAttributes(self, ATTRS)
	return true
end

--[[
	取得或刷新天气 lease（fail-closed）

	@param writerId string - 写者标识
	@param lightingName string - 天气配置名
	@param transitionTime number - 过渡时间（秒）
	@param priority number? - nil=Skill；Baseline/非法则拒绝
	@param force boolean? - true 时同名也重放；同 writer 过密 force 降级为非 force
	@param ttl number? - nil=默认；0=永不过期；>0=秒
	@return boolean - true=lease 已接受；落地见 AppliedName/Pending/LastError。false=拒绝
]]
function SystemLightingWeather.acquireLease(
	self: SystemLightingWeather,
	writerId: string,
	lightingName: string,
	transitionTime: number,
	priority: number?,
	force: boolean?,
	ttl: number?
): boolean
	if not _isReady(self) then
		return _rejectIfNotReady(self, "acquireLease")
	end
	if typeof(writerId) ~= "string" or writerId == "" then
		Log.warn("SystemLightingWeather: ACQUIRE 无效 writerId", writerId)
		_setLastError("ACQUIRE 无效 writerId")
		return false
	end
	if typeof(lightingName) ~= "string" or lightingName == "" then
		Log.warn("SystemLightingWeather: ACQUIRE 无效名称", lightingName)
		_setLastError("ACQUIRE 无效名称")
		return false
	end

	local prio = LeaseStack.resolvePriority(priority, _setLastError)
	if prio == nil then
		return false
	end

	if not ApplyPipeline.findLightingConfig(self, lightingName, ATTRS.lastError) then
		Log.warn("SystemLightingWeather: 缺少天气配置", lightingName)
		if self._configFolder == nil then
			_setLastError("缺少 LightingConfig 目录")
		elseif Lighting:GetAttribute(ATTRS.lastError) == nil then
			_setLastError("缺少天气配置: " .. lightingName)
		end
		return false
	end

	local existing = self._leases[writerId]
	if not existing then
		local maxLeases = WeatherMaxActiveLeases
		if typeof(maxLeases) ~= "number" or maxLeases < 1 then
			maxLeases = DEFAULT_MAX_ACTIVE_LEASES
		end
		if LeaseStack.countLeases(self._leases) >= maxLeases then
			Log.warn("SystemLightingWeather: ACQUIRE 超过 lease 上限", writerId, maxLeases)
			_setLastError("ACQUIRE 超过 lease 上限: " .. tostring(maxLeases))
			return false
		end
	end

	transitionTime = LightingTweenUtil.normalizeTransitionTime(transitionTime)
	local ttlArg: number? = nil
	if typeof(ttl) == "number" then
		ttlArg = ttl
	end

	local wantForce = force == true
	local forceMin = WeatherAcquireForceMinIntervalSec
	if typeof(forceMin) ~= "number" or forceMin < 0 then
		forceMin = FALLBACK_FORCE_MIN_SEC
	end
	if wantForce then
		local lastForceAt = self._forceAcquireAt[writerId]
		local now = time()
		if typeof(lastForceAt) == "number" and (now - lastForceAt) < forceMin then
			wantForce = false
			Log.print("SystemLightingWeather: ACQUIRE force 过密，降级为非 force", writerId)
		else
			self._forceAcquireAt[writerId] = now
		end
	end

	self._leaseOrderSeq += 1
	local now = time()
	local prevAcquiredAt = if existing and typeof(existing.acquiredAt) == "number" then existing.acquiredAt else now
	self._leases[writerId] = {
		name = lightingName,
		priority = prio,
		order = self._leaseOrderSeq,
		expiresAt = LeaseStack.resolveExpiresAt(prio, ttlArg),
		acquiredAt = prevAcquiredAt,
		writerId = writerId,
	}
	_setLastError(nil)

	if not wantForce and existing and existing.name == lightingName and existing.priority == prio then
		_scheduleLeaseSweep(self)
		return ApplyCoalesce.applyEffectiveIfChangedCoalesced(self, _coalesceDeps, transitionTime, false)
	end

	ApplyCoalesce.applyEffectiveIfChangedCoalesced(self, _coalesceDeps, transitionTime, wantForce)
	_scheduleLeaseSweep(self)
	return true
end

--[[
	释放天气 lease 并 reconcile（无 lease 视为成功；降级态 false）

	@param writerId string - 写者标识
	@param transitionTime number - 过渡时间（秒）
	@return boolean - true 已处理（含幂等无 lease）；降级态 false
]]
function SystemLightingWeather.releaseLease(self: SystemLightingWeather, writerId: string, transitionTime: number): boolean
	if not _isReady(self) then
		return _rejectIfNotReady(self, "releaseLease")
	end
	if not self._leases[writerId] then
		return true
	end
	self._leases[writerId] = nil
	self._forceAcquireAt[writerId] = nil
	self._staleWarnedWriters[writerId] = nil
	LeaseLifecycle.warnStaleLeases(self, _lifecycleDeps)
	ApplyCoalesce.applyEffectiveIfChangedCoalesced(
		self,
		_coalesceDeps,
		LightingTweenUtil.normalizeTransitionTime(transitionTime),
		false
	)
	_scheduleLeaseSweep(self)
	return true
end

--[[
	强制清空 lease（可选上限 priority）后 reconcile

	@param maxPriority number? - 仅清 priority<=max；nil=全部
	@param transitionTime number - 过渡时间（秒）
	@return boolean - true 已处理；降级态 false
]]
function SystemLightingWeather.forceClearLeases(
	self: SystemLightingWeather,
	maxPriority: number?,
	transitionTime: number
): boolean
	if not _isReady(self) then
		return _rejectIfNotReady(self, "forceClearLeases")
	end
	transitionTime = LightingTweenUtil.normalizeTransitionTime(transitionTime)
	local toRemove = {}
	for writerId, lease in self._leases do
		if maxPriority == nil or lease.priority <= maxPriority then
			table.insert(toRemove, writerId)
		end
	end
	if #toRemove == 0 then
		ApplyPipeline.syncLightingNameAttributes(self, ATTRS)
		return true
	end
	for _, writerId in toRemove do
		self._leases[writerId] = nil
		self._forceAcquireAt[writerId] = nil
		self._staleWarnedWriters[writerId] = nil
	end
	Log.print("SystemLightingWeather: FORCE_CLEAR 已执行", maxPriority, #toRemove)
	LeaseLifecycle.warnStaleLeases(self, _lifecycleDeps)
	ApplyCoalesce.applyEffectiveIfChangedCoalesced(self, _coalesceDeps, transitionTime, true)
	_scheduleLeaseSweep(self)
	return true
end

--[[
	强制重放当前生效天气 + overlay（绕过同名短路；经 coalesce）

	@param transitionTime number - 过渡时间（秒）
	@return boolean - 恒 true（已排队）；降级态 false
]]
function SystemLightingWeather.reapplyEffective(self: SystemLightingWeather, transitionTime: number): boolean
	if not _isReady(self) then
		return _rejectIfNotReady(self, "reapplyEffective")
	end
	ApplyCoalesce.requestFullApply(self, _coalesceDeps, LightingTweenUtil.normalizeTransitionTime(transitionTime))
	return true
end

--[[
	reconcile 单个效果通道（经同帧 coalesce；与全量 apply 合并，避免抢 applyGen）

	@param className string - 效果 ClassName
	@param transitionTime number - 过渡时间（秒）
	@return nil - 无返回值
]]
function SystemLightingWeather.reconcileChannel(
	self: SystemLightingWeather,
	className: string,
	transitionTime: number
)
	if not _isReady(self) then
		_rejectIfNotReady(self, "reconcileChannel")
		return
	end
	if typeof(className) ~= "string" or className == "" then
		Log.warn("SystemLightingWeather: reconcile 无效 className", className)
		_setLastError("reconcile 无效 className")
		return
	end
	ApplyCoalesce.requestReconcileChannel(
		self,
		_coalesceDeps,
		className,
		LightingTweenUtil.normalizeTransitionTime(transitionTime)
	)
end

--[[
	FX 租约释放后仅对齐 ColorCorrection

	@return nil - 无返回值
]]
function SystemLightingWeather.onFxCcBusyReleased(self: SystemLightingWeather)
	if not _isReady(self) then
		return
	end
	self:reconcileChannel(CC_CLASS_NAME, 0)
end

--[[
	扫描并释放过期 / 硬上限 lease，并检查无 TTL 过久告警

	@return nil - 无返回值
]]
function SystemLightingWeather.sweepExpiredLeases(self: SystemLightingWeather)
	LeaseLifecycle.sweepExpired(self, _lifecycleDeps, function(host)
		(host :: SystemLightingWeather):sweepExpiredLeases()
	end)
end

--[[
	设置自定义叠加态并增量 reconcile

	@param customName string - EnumMgr.LightingCustomState 名
	@param nowState boolean - 是否激活
	@param transitionTime number - 过渡时间（秒）
	@return boolean - true 已处理或已是目标态（幂等）；false 参数非法 / 未注册 / 缺模板 / 降级
]]
function SystemLightingWeather.setCustomStateAndReconcile(
	self: SystemLightingWeather,
	customName: string,
	nowState: boolean,
	transitionTime: number
): boolean
	if not _isReady(self) then
		return _rejectIfNotReady(self, "setCustomStateAndReconcile")
	end
	if typeof(customName) ~= "string" or typeof(nowState) ~= "boolean" then
		Log.warn("SystemLightingWeather: LIGHT_CUSTOM_CHANGE 参数无效", customName, nowState)
		_setLastError("LIGHT_CUSTOM_CHANGE 参数无效")
		return false
	end

	if not self._customState:hasState(customName) then
		Log.warn("SystemLightingWeather: LIGHT_CUSTOM_CHANGE 未注册状态", customName)
		_setLastError("LIGHT_CUSTOM_CHANGE 未注册: " .. customName)
		return false
	end

	if self._customState:isStateActive(customName) == nowState then
		return true
	end

	local className = self._customState:getStateClassName(customName)
	if not className then
		Log.warn("SystemLightingWeather: 自定义态缺少模板 ClassName", customName)
		_setLastError("自定义态缺少模板: " .. customName)
		return false
	end

	if not self._customState:setState(customName, nowState) then
		return false
	end

	self:reconcileChannel(className, LightingTweenUtil.normalizeTransitionTime(transitionTime))
	return true
end

--[[
	销毁子模块与单例

	@return nil - 无返回值
]]
function SystemLightingWeather.destroy(self: SystemLightingWeather)
	LeaseLifecycle.cancelSweep(self)
	ApplyCoalesce.cancelAndClear(self, ATTRS)
	self._forceAcquireAt = {}
	self._staleWarnedWriters = {}
	self._bootFailLogged = false
	QualityGate.disconnect(self._qualityGate)
	if self._lightingSystem then
		self._lightingSystem:destroy()
		self._lightingSystem = nil
	end
	if self._customState then
		self._customState:destroy()
		self._customState = nil
	end
	self._leases = {}
	self._degraded = false
	_didInitApply = false
	if ATTRS.bootReady then
		Lighting:SetAttribute(ATTRS.bootReady, false)
	end
	if ATTRS.appliedLighting then
		Lighting:SetAttribute(ATTRS.appliedLighting, nil)
	end
	if _singleton == self then
		_singleton = nil
	end
end

return SystemLightingWeather
