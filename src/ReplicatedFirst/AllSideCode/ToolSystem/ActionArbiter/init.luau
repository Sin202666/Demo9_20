--[[
	Module: ActionArbiter
	Description: 角色动作表现仲裁（LocomotionGate）：谁抑制 loco、谁写朝向、谁接管相机。
	Author: 林奥宇
	Created: 2026-07-28
	Last Modified: 2026-09-01

	================================================================================
	使用说明
	================================================================================

	【决策约定（本版）】
	1. suppressLoco / pauseBaseTracks：所有活跃 claim 做 OR（任一要冻腿则冻）。
	2. facingOwner / cameraOwner / activeOwnerId：取 priority 最高（同分后 Acquire）那条。
	3. Acquire 可传 blendPolicy（Override/Overlay/FacingOnly/React）展开默认字段；显式字段覆盖展开结果。
	4. AnimationModule 仅 opt-in actionClaim，默认不自动占闸。
	5. 仅 Animate/init 调用 Create；其它模块 GetForCharacter（弱表）；未 Create 返回 nil。

	【BlendPolicy】
	- Override：冻 loco + 冻基轨 + facing External（翻滚/全身大招）
	- Overlay：不停腿 + facing External（移动中上身技能；资源须未键腿）
	- FacingOnly：仅抢朝向
	- React：不停腿、不声明朝向（短受击）

	【与 Animate Jump/Land 分层】
	- Land/LightLand 绑定 AnimationPriority.Action，装饰 Idle 轨盖不住落地。
	- 业务要取消落地：须 PlayAnim Priority≥Action，并 actionClaim（Override 或显式 suppress）；
	  禁止用 Idle 播攻击/受击却期望盖掉落地。
	- Gate 保护窗不能挡「不走 Acquire 的 Idle 轨」；抗 Idle 靠 Animator Priority。

	【获取】
	local ActionArbiter = Utils.ActionArbiter
	local arbiter = ActionArbiter.Create(character, { localPlayer = LocalPlayer })
	local token = arbiter:Acquire({
	  ownerId = "Skill:FireSlash",
	  priority = ActionArbiter.Priority.Skill,
	  blendPolicy = ActionArbiter.BlendPolicy.Overlay,
	})
	arbiter:Release(token)

	【与移速边界】
	WalkSpeed / RELEASE_SKILL_STATE / Bind Modifier 栈仍属 CharacterMoveSpeed（MoveSynthesis）；
	Gate 只管动画/朝向/相机表现占用。Skill 占闸由 SkillActionLock 直调 Acquire（引用计数）；Attribute Bridge 仅 JetPacking / FacingOverride。

	【子模块】
	- Constants.luau    优先级、BlendPolicy 与 Owner 常量
	- Bridge.luau       遗留 Attribute 兼容映射
	- GateInstance.luau 角色级闸实例（Create 工厂）
]]

local Constants = require(script.Constants)
local GateInstance = require(script.GateInstance)

export type FacingOwner = "Animate" | "External" | "None"
export type CameraOwner = "Default" | "External" | "None"
export type BlendPolicyName = "Override" | "Overlay" | "FacingOnly" | "React"

export type AcquireOptions = {
	ownerId: string,
	priority: number,
	blendPolicy: string?,
	suppressLoco: boolean?,
	pauseBaseTracks: boolean?,
	facingOwner: FacingOwner?,
	cameraOwner: CameraOwner?,
	reason: string?,
	ttlSeconds: number?,
}

export type GateSnapshot = {
	suppressLoco: boolean,
	pauseBaseTracks: boolean,
	facingOwner: FacingOwner,
	cameraOwner: CameraOwner,
	activeOwnerId: string?,
	activeOwners: { string },
	reason: string?,
}

export type CreateOptions = {
	localPlayer: Player?,
	enableAttributeBridge: boolean?,
	enableJetPacking: boolean?,
	enableFacingOverride: boolean?,
	enableSkillActionLock: boolean?,
}

export type ActionArbiterInstance = {
	Acquire: (self: ActionArbiterInstance, options: AcquireOptions) -> string,
	Release: (self: ActionArbiterInstance, token: string) -> boolean,
	ReleaseByOwner: (self: ActionArbiterInstance, ownerId: string) -> boolean,
	GetSnapshot: (self: ActionArbiterInstance) -> GateSnapshot,
	IsLocoSuppressed: (self: ActionArbiterInstance) -> boolean,
	GetFacingOwner: (self: ActionArbiterInstance) -> FacingOwner,
	GetCameraOwner: (self: ActionArbiterInstance) -> CameraOwner,
	OnChanged: (self: ActionArbiterInstance, callback: (GateSnapshot) -> ()) -> () -> (),
	destroy: (self: ActionArbiterInstance) -> (),
	Character: Model,
}

export type ExpandedBlendPolicy = {
	suppressLoco: boolean,
	pauseBaseTracks: boolean,
	facingOwner: FacingOwner?,
}

local ActionArbiter = {}
ActionArbiter.Priority = Constants.Priority
ActionArbiter.BlendPolicy = Constants.BlendPolicy
ActionArbiter.FacingOwner = Constants.FacingOwner
ActionArbiter.CameraOwner = Constants.CameraOwner
ActionArbiter.BridgeOwnerId = Constants.BridgeOwnerId

--[[
	展开 BlendPolicy 为默认闸字段（未知名回落 Override）
	@param policyName string? - BlendPolicy 名
	@return ExpandedBlendPolicy - suppressLoco / pauseBaseTracks / facingOwner 默认展开
]]
function ActionArbiter.ExpandBlendPolicy(policyName: string?): ExpandedBlendPolicy
	local name = if type(policyName) == "string" and policyName ~= "" then policyName else Constants.BlendPolicy.Override
	local defaults = Constants.BlendPolicyDefaults[name]
	if not defaults then
		defaults = Constants.BlendPolicyDefaults.Override
	end
	return {
		suppressLoco = defaults.suppressLoco == true,
		pauseBaseTracks = defaults.pauseBaseTracks == true,
		facingOwner = defaults.facingOwner :: FacingOwner?,
	}
end

--[[
	创建角色级仲裁实例（仅 Animate 应调用；重复 Create 返回已有实例）
	@param character Model - 角色模型
	@param options CreateOptions? - Bridge / LocalPlayer 等
	@return ActionArbiterInstance - 仲裁实例
]]
function ActionArbiter.Create(character: Model, options: CreateOptions?): ActionArbiterInstance
	return GateInstance.create(character, options, ActionArbiter.ExpandBlendPolicy)
end

--[[
	查询已 Create 的实例；未创建返回 nil（不偷偷新建）
	@param character Model - 角色
	@return ActionArbiterInstance? - 仲裁实例
]]
function ActionArbiter.GetForCharacter(character: Model): ActionArbiterInstance?
	return GateInstance.get(character)
end

return ActionArbiter
