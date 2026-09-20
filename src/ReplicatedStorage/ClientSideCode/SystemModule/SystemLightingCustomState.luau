--[[
	Module: SystemLightingCustomState
	Description: 自定义大气效果状态机，按权重在同类型效果间择优
	Author: 林奥宇
	Created: 2026-01-23
	Last Modified: 2026-08-31

	功能：
	- 注册并管理 UI 模糊、对话模糊等特殊 Lighting 叠加状态
	- 同 ClassName 的多个激活状态按 StateHighWeight / StateLowWeight / StateName 择优

	配置：
	- REGISTER_STATE_DEFS 只登记状态名（EnumMgr.LightingCustomState）与缺省权重
	- 资源模板：ReplicatedStorage.Assets.LightingStates 下与 StateObjectName 同名的 Instance
	- 权重优先读模板 Attribute：StateHighWeight / StateLowWeight；缺省回退注册表
	- createForOwner 时 Clone 模板（Parent=nil）；运行时只用克隆体，避免改 Assets 原件影响运行
	- Assets / LightingStates 缺失时 fail-soft：空状态表，单例仍可创建；hasState/setState 自然失败
	- Assets 热改需重建状态机才生效

	写入入口（仅 SystemLightingWeather）：
	- tryApplyWinningOverlay / applyAllWinningOverlays 为唯一对外写入路径
	- tryApplyWinningOverlay 三态：applied（已写）/ held（有优胜但跳过写，禁止回退天气）/ none（无优胜）
	- applyAllWinningOverlays 返回 OverlayBatchSummary（含 held / skipReason / overlayTop）
	- 内部克隆模板不外泄；写入目标为 SystemLighting 托管的运行时 Instance
	- 业务勿直接 new / setState（仅 Weather 调用）

	单例：
	- 合法创建仅 Weather 调用 createForOwner("SystemLightingWeather")
	- 业务 Utils.SystemLightingCustomState.new 恒返回 nil（硬闸门，不回已有单例）

	使用（业务经 Bindable / Weather，勿直调本模块）：
	local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	Utils.NetWork.FireBindable(
		Utils.NetMsg.LIGHT_CUSTOM_CHANGE,
		Utils.EnumMgr.LightingCustomState.UiBlur,
		true,
		0.2
	)
	-- 或仅 Manager 侧：weather:setCustomStateAndReconcile(name, true, 0.2)
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log
local ReplicatedStorage = Utils.ReplicatedStorage
local EnumMgr = Utils.EnumMgr

local LightingApplyResult = EnumMgr.LightingApplyResult

export type CustomState = {
	StateName: string,
	IsActive: boolean,
	StateHighWeight: number,
	StateLowWeight: number,
	StateObjectName: string,
	StateObject: Instance?,
}

export type OverlayApplyResult = "applied" | "held" | "none"

export type OverlayBatchSummary = {
	hasHeld: boolean,
	heldMessage: string?,
	skipReason: string?,
	overlayTop: string?,
}

-- Lighting 门面最小接口（避免循环依赖）
export type LightingApplyTarget = {
	applyEffectFromInstance: (self: LightingApplyTarget, effectInstance: Instance, transitionTime: number) -> (boolean, string),
}

export type SystemLightingCustomState = {
	createForOwner: (ownerKey: string) -> SystemLightingCustomState?,
	new: () -> SystemLightingCustomState?,
	setState: (self: SystemLightingCustomState, stateName: string, newState: boolean) -> boolean,
	isStateActive: (self: SystemLightingCustomState, stateName: string) -> boolean,
	hasState: (self: SystemLightingCustomState, stateName: string) -> boolean,
	getStateClassName: (self: SystemLightingCustomState, stateName: string) -> string?,
	getOverlayTopNames: (self: SystemLightingCustomState) -> string?,
	tryApplyWinningOverlay: (
		self: SystemLightingCustomState,
		lightingSystem: LightingApplyTarget,
		className: string,
		transitionTime: number
	) -> (OverlayApplyResult, string?),
	applyAllWinningOverlays: (
		self: SystemLightingCustomState,
		lightingSystem: LightingApplyTarget,
		transitionTime: number
	) -> OverlayBatchSummary,
	destroy: (self: SystemLightingCustomState) -> nil,
}

-- ========================================
-- 常量
-- ========================================
local OWNER_KEY = "SystemLightingWeather"

local LightingCustomState = EnumMgr.LightingCustomState

-- 缺省权重；运行时以资产 Attribute 覆盖
local REGISTER_STATE_DEFS: { CustomState } = {
	{
		StateName = LightingCustomState.UiBlur,
		IsActive = false,
		StateHighWeight = 100,
		StateLowWeight = 0,
		StateObjectName = LightingCustomState.UiBlur,
		StateObject = nil,
	},
	{
		StateName = LightingCustomState.NpcDialogBlur,
		IsActive = false,
		StateHighWeight = 90,
		StateLowWeight = 0,
		StateObjectName = LightingCustomState.NpcDialogBlur,
		StateObject = nil,
	},
}

-- ========================================
-- 模块定义
-- ========================================
local SystemLightingCustomState = {}
SystemLightingCustomState.__index = SystemLightingCustomState

local _singleton: SystemLightingCustomState? = nil

-- ========================================
-- 私有函数
-- ========================================
--[[
	克隆注册表条目，避免 createForOwner 污染模块级 REGISTER_STATE_DEFS

	@param stateDef CustomState - 注册表中的状态定义
	@return CustomState - 独立副本
]]
local function _cloneStateDef(stateDef: CustomState): CustomState
	return {
		StateName = stateDef.StateName,
		IsActive = stateDef.IsActive,
		StateHighWeight = stateDef.StateHighWeight,
		StateLowWeight = stateDef.StateLowWeight,
		StateObjectName = stateDef.StateObjectName,
		StateObject = stateDef.StateObject,
	}
end

--[[
	从模板 Attribute 读取权重；类型不符时回退缺省

	@param inst Instance - 克隆模板
	@param attrName string - Attribute 名
	@param fallback number - 缺省权重
	@return number - 有效权重
]]
local function _readWeightAttr(inst: Instance, attrName: string, fallback: number): number
	local v = inst:GetAttribute(attrName)
	if typeof(v) == "number" then
		return v
	end
	return fallback
end

--[[
	比较两个激活态谁胜出（高权重 > 低权重 > 状态名字典序）

	@param a CustomState - 候选 A
	@param b CustomState - 候选 B
	@return boolean - true 表示 a 应替换 b
]]
local function _shouldReplaceWinner(a: CustomState, b: CustomState): boolean
	if a.StateHighWeight > b.StateHighWeight then
		return true
	end
	if a.StateHighWeight < b.StateHighWeight then
		return false
	end
	if a.StateLowWeight > b.StateLowWeight then
		return true
	end
	if a.StateLowWeight < b.StateLowWeight then
		return false
	end
	return a.StateName > b.StateName
end

--[[
	按 ClassName 收集当前激活态中的优胜者

	@param self SystemLightingCustomState - 状态机
	@return {[string]: CustomState} - ClassName -> 优胜 state
]]
local function _collectWinners(self: SystemLightingCustomState): { [string]: CustomState }
	local winners: { [string]: CustomState } = {}

	for _, state in self._states do
		if state.IsActive and state.StateObject then
			local className = state.StateObject.ClassName
			local current = winners[className]
			if not current or _shouldReplaceWinner(state, current) then
				winners[className] = state
			end
		end
	end

	return winners
end

--[[
	将优胜状态名拼成调试 Attribute 文案

	@param winners {[string]: CustomState} - 优胜表
	@return string? - 逗号拼接；无优胜为 nil
]]
local function _formatOverlayTop(winners: { [string]: CustomState }): string?
	local names = {}
	for _, state in winners do
		table.insert(names, state.StateName)
	end
	if #names == 0 then
		return nil
	end
	table.sort(names)
	return table.concat(names, ",")
end

--[[
	将 applyEffectFromInstance 结果映射为三态与 SkipReason

	Ok 且已写 → applied；其余结果码一律 held（SkipReason 即 LightingApplyResult 本身）

	@param ok boolean - 是否已写
	@param resultCode string - EnumMgr.LightingApplyResult
	@return OverlayApplyResult - applied / held（调用方已确认有 winner）
	@return string? - SkipReason（held 时为 resultCode）
]]
local function _classifyApplyOutcome(ok: boolean, resultCode: string): (OverlayApplyResult, string?)
	if ok and resultCode == LightingApplyResult.Ok then
		return "applied", nil
	end
	return "held", resultCode
end

--[[
	解析 LightingStates 资源目录；缺失时 fail-soft 返回 nil

	@return Folder? - 状态模板目录
]]
local function _findLightingStatesFolder(): Folder?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then
		Log.warn("SystemLightingCustomState: 缺少 ReplicatedStorage.Assets，自定义态降级")
		return nil
	end
	local folder = assets:FindFirstChild("LightingStates")
	if not folder or not folder:IsA("Folder") then
		Log.warn("SystemLightingCustomState: 缺少 Assets.LightingStates，自定义态降级")
		return nil
	end
	return folder :: Folder
end

--[[
	创建单例实例（仅 createForOwner 合法路径调用）

	@return SystemLightingCustomState - 状态机实例
]]
local function _createInstance(): SystemLightingCustomState
	local self = setmetatable({}, SystemLightingCustomState)
	self._states = {}
	self._ownedClones = {}

	local lightingStatesFolder = _findLightingStatesFolder()
	if lightingStatesFolder then
		for _, stateDef in REGISTER_STATE_DEFS do
			local state = _cloneStateDef(stateDef)
			local assetObject = lightingStatesFolder:FindFirstChild(state.StateObjectName)
			if assetObject then
				local cloned = assetObject:Clone()
				cloned.Parent = nil
				state.StateHighWeight = _readWeightAttr(cloned, "StateHighWeight", stateDef.StateHighWeight)
				state.StateLowWeight = _readWeightAttr(cloned, "StateLowWeight", stateDef.StateLowWeight)
				state.StateObject = cloned
				table.insert(self._ownedClones, cloned)
				self._states[state.StateName] = state
			else
				Log.warn("SystemLightingCustomState: 缺少状态对象", state.StateName)
			end
		end
	end

	_singleton = self
	return self
end

-- ========================================
-- 公共函数
-- ========================================
--[[
	Weather 专用：校验 ownerKey 后创建或返回单例

	@param ownerKey string - 必须为 "SystemLightingWeather"
	@return SystemLightingCustomState? - 实例；非法 key 为 nil
]]
function SystemLightingCustomState.createForOwner(ownerKey: string): SystemLightingCustomState?
	if ownerKey ~= OWNER_KEY then
		Log.warn("SystemLightingCustomState: createForOwner 非法 ownerKey，拒绝创建", ownerKey)
		return nil
	end
	if _singleton then
		Log.warn("SystemLightingCustomState: createForOwner 重复调用，返回已有单例")
		return _singleton
	end
	return _createInstance()
end

--[[
	兼容入口（业务禁用）：恒返回 nil；请经 SystemLightingWeather.createForOwner

	@return nil - 始终 nil（硬闸门，即使已有单例也不返回）
]]
function SystemLightingCustomState.new(): SystemLightingCustomState?
	Log.warn("SystemLightingCustomState: 禁止业务 new；请经 SystemLightingWeather / LightingManager Bindable")
	return nil
end

--[[
	设置指定状态的激活标记（仅 Weather）

	@param stateName string - 状态名称（建议 EnumMgr.LightingCustomState.*）
	@param newState boolean - 是否激活
	@return boolean - true 已写入；false 未注册该状态
]]
function SystemLightingCustomState.setState(
	self: SystemLightingCustomState,
	stateName: string,
	newState: boolean
): boolean
	local state = self._states[stateName]
	if not state then
		Log.warn("SystemLightingCustomState: setState 未知状态", stateName)
		return false
	end

	state.IsActive = newState
	return true
end

--[[
	查询状态是否已注册

	@param stateName string - 状态名称
	@return boolean - 是否存在于内部状态表
]]
function SystemLightingCustomState.hasState(self: SystemLightingCustomState, stateName: string): boolean
	return self._states[stateName] ~= nil
end

--[[
	查询指定状态当前是否激活

	@param stateName string - 状态名称
	@return boolean - 已激活为 true；未注册或未激活为 false
]]
function SystemLightingCustomState.isStateActive(self: SystemLightingCustomState, stateName: string): boolean
	local state = self._states[stateName]
	return state ~= nil and state.IsActive == true
end

--[[
	查询状态模板的 ClassName（用于增量 reconcile）

	@param stateName string - 状态名称
	@return string? - ClassName；未注册或无模板时 nil
]]
function SystemLightingCustomState.getStateClassName(self: SystemLightingCustomState, stateName: string): string?
	local state = self._states[stateName]
	if state and state.StateObject then
		return state.StateObject.ClassName
	end
	return nil
end

--[[
	当前全部优胜 overlay 的状态名（调试 Attribute LightingOverlayTop）

	@return string? - 逗号拼接；无优胜为 nil
]]
function SystemLightingCustomState.getOverlayTopNames(self: SystemLightingCustomState): string?
	return _formatOverlayTop(_collectWinners(self))
end

--[[
	Weather 专用：将指定 ClassName 的优胜 overlay 写入 Lighting 门面

	@param lightingSystem LightingApplyTarget - SystemLighting（或兼容 applyEffectFromInstance 的对象）
	@param className string - 效果 ClassName（如 "BlurEffect"）
	@param transitionTime number - 过渡时间（秒）
	@return OverlayApplyResult - applied 已写；held 有优胜但跳过写（禁止回退天气）；none 无优胜
	@return string? - held 时的 SkipReason（FxBusy / QualitySkip / ChannelError 等）
]]
function SystemLightingCustomState.tryApplyWinningOverlay(
	self: SystemLightingCustomState,
	lightingSystem: LightingApplyTarget,
	className: string,
	transitionTime: number
): (OverlayApplyResult, string?)
	local winners = _collectWinners(self)
	local state = winners[className]
	if not state or not state.StateObject then
		return "none", nil
	end

	local ok, resultCode = lightingSystem:applyEffectFromInstance(state.StateObject, transitionTime)
	local outcome, skipReason = _classifyApplyOutcome(ok, resultCode)
	if outcome == "held"
		and skipReason ~= LightingApplyResult.FxBusy
		and skipReason ~= LightingApplyResult.QualitySkip
	then
		Log.warn("SystemLightingCustomState: overlay apply 失败，held", className, resultCode)
	end
	return outcome, skipReason
end

--[[
	Weather 专用：将当前全部优胜 overlay 写入 Lighting 门面（与 tryApply 相同三态）

	@param lightingSystem LightingApplyTarget - SystemLighting（或兼容对象）
	@param transitionTime number - 过渡时间（秒）
	@return OverlayBatchSummary - hasHeld / heldMessage / skipReason / overlayTop
]]
function SystemLightingCustomState.applyAllWinningOverlays(
	self: SystemLightingCustomState,
	lightingSystem: LightingApplyTarget,
	transitionTime: number
): OverlayBatchSummary
	local winners = _collectWinners(self)
	local summary: OverlayBatchSummary = {
		hasHeld = false,
		heldMessage = nil,
		skipReason = nil,
		overlayTop = _formatOverlayTop(winners),
	}

	for className, state in winners do
		if state.StateObject then
			local ok, resultCode = lightingSystem:applyEffectFromInstance(state.StateObject, transitionTime)
			local outcome, skipReason = _classifyApplyOutcome(ok, resultCode)
			if outcome == "held" then
				summary.hasHeld = true
				if summary.heldMessage == nil then
					summary.heldMessage = "overlay held: " .. className
					summary.skipReason = skipReason
				end
				if skipReason ~= LightingApplyResult.FxBusy
					and skipReason ~= LightingApplyResult.QualitySkip
				then
					Log.warn("SystemLightingCustomState: overlay apply 失败，held", className, resultCode)
				end
			end
		end
	end

	return summary
end

--[[
	清空内部状态并销毁克隆模板，释放单例引用

	@return nil - 无返回值
]]
function SystemLightingCustomState.destroy(self: SystemLightingCustomState)
	for _, clone in self._ownedClones do
		if clone then
			clone:Destroy()
		end
	end
	self._ownedClones = {}
	self._states = {}
	if _singleton == self then
		_singleton = nil
	end
end

return SystemLightingCustomState
