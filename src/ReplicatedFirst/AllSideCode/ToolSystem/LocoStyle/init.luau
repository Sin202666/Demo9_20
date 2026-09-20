--[[
	Module: LocoStyle
	Description: 泛用 3C 基轨风格切换：StyleStack 合成 styleId，批量 bindBaseAction；不改 locomotion FSM。
	Author: 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-09-01

	能力：
	- SetBaseStyle / Apply：设置底层风格（source=__base__，priority=Base）
	- PushStyle / PopStyle：多 Driver 按 priority 合成最终 styleId（高优先覆盖；同优先后者覆盖）
	- 资源经 LocoStyleSets Resolve + Fallback Default；预热走 SkillPreloadUtil
	- Gate pauseBaseTracks 时推迟 rebind；解闸 FlushPending 后续播
	- 与技能：只动 Animate 基轨；Overlay/Override 仍由 ActionArbiter + AnimationLayer 负责

	Driver 接入约定：
	- 装备：PushStyle("Equip", styleId, LocoStyle.Priority.Equip)
	- 变身：PushStyle("Transform", styleId, LocoStyle.Priority.Transform)
	- 关卡强制：PushStyle("Level", styleId, LocoStyle.Priority.Level)
	- 离开时务必 PopStyle(同 source)，勿直接 Apply 抢写导致其它 Driver 丢失

	标准加载：
	local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	local LocoStyle = Utils.LocoStyle
	-- Animate/init 内 Create；业务：
	local ctrl = LocoStyle.GetForCharacter(character)
	if ctrl then
		ctrl:PushStyle("Equip", "Heavy", LocoStyle.Priority.Equip)
	end

	示例：
	1) 切底层风格：ctrl:SetBaseStyle("Heavy") 或 ctrl:Apply("Heavy")
	2) 临时覆盖：ctrl:PushStyle("Transform", "Heavy", LocoStyle.Priority.Transform)
	   结束：ctrl:PopStyle("Transform")
	3) 重置：ctrl:Reset() → 清栈并回到 Default

	边界：
	- 仅 Animate/init 调用 Create；其它模块 GetForCharacter（弱表）；未 Create 返回 nil
	- 移速仍归 CharacterMoveSpeed；本模块不写 WalkSpeed
	- Stance / CharacterKit 不在本模块范围

	子模块：
	- StyleInstance.luau  角色级控制器工厂（Create / GetForCharacter）
]]

-- ========================================
-- 模块引用
-- ========================================

local StyleInstance = require(script.StyleInstance)

-- ========================================
-- 模块定义
-- ========================================

export type PriorityBand = StyleInstance.PriorityBand
export type CreateDeps = StyleInstance.CreateDeps
export type LocoStyleController = StyleInstance.LocoStyleController

local LocoStyle = {}

LocoStyle.Priority = StyleInstance.Priority

-- ========================================
-- 公共函数
-- ========================================

--[[
	创建角色级 LocoStyle 控制器（仅 Animate/init 调用）
	@param character Model - 角色
	@param deps CreateDeps - animate（bindBaseAction/resumeBaseAction/invalidateBasePose/BaseActionEnabled）、arbiter（GetSnapshot/OnChanged）、resyncAfterBaseUnpause、可选 footStepMarkersFor
	@return LocoStyleController - 角色级控制器（重复 Create 返回已有实例）
]]
function LocoStyle.Create(character: Model, deps: CreateDeps): LocoStyleController
	return StyleInstance.create(character, deps)
end

--[[
	查询已 Create 的实例；未创建返回 nil
	@param character Model - 角色
	@return LocoStyleController? - 已 Create 的实例；未创建为 nil
]]
function LocoStyle.GetForCharacter(character: Model): LocoStyleController?
	return StyleInstance.get(character)
end

return LocoStyle
