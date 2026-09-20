--[[
	Module: CharacterControl
	Description: 客户端角色 Control 薄层：Intent 采样、LockMask、Sprint Toggle/Hold、Jump Buffer/Coyote、Look/Interact 闸、TransferControlOwner。
	Author: 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-09-01

	================================================================================
	使用说明
	================================================================================

	【与其它模块边界】
	- 本模块：Intent / 输入锁 / Walk·Run / 跳跃策略 / Look·Interact 闸；向 CMS 声明 Modifier，不写 WalkSpeed、不播轨、不写 FOV。
	- CharacterMoveSpeed（CMS）：Attribute + Modifier 合成并唯一写 WalkSpeed / ExpectedWalkSpeed。
	- Animate：消费 ExpectedWalkSpeed + MoveDirection；ShiftLock 朝向写口在 Look 锁时让出。
	- CameraMode：跟拍模式栈；Look 锁不自动改 Mode，业务可 PushMode + Transfer 组合。
	- 技能位移「冲刺」NewRoll（Q）：经 CharacterMotion；与本模块 Locomotion Sprint（Walk/Run）无关。
	- ActionArbiter：管腿/朝向/相机占用；本模块不 Acquire。
	- PlayerModule.ControlModule：仅经内部 PlayerControlsBridge 引用计数 Enable/Disable；禁止业务直调 GetControls():Disable。

	【奔跑输入模式】
	- settingConf.RunMode（Control 分类 Choose）：0=一键切换（默认），1=长按奔跑。
	- Create 时读 GetSetting，并监听 player.Setting.RunMode 变更热切换。

	【Move 锁策略】
	- SpeedOnly（PushLock 默认）：仅 CMS hardLock → WalkSpeed=0；MoveDirection 仍可能非零。
	- DisableControls（Transfer 默认）：冻速 + ControlModule:Disable（清移动意图）；会关掉整个默认 Controls 输入（含 Keyboard 跳），故 Transfer 默认带 Jump 锁。
	- 显式覆盖：mask.MovePolicy = "SpeedOnly" | "DisableControls"。
	- 配置：GameConfig.CharacterControl「Move锁默认策略」/「Transfer移控策略」。

	【标准加载】
	local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	local CharacterControl = Utils.CharacterControl

	仅本地玩家角色由 CharacterManager Create；业务用 GetForCharacter。

	【示例 — 技能锁跳与冲刺】
	local ctrl = CharacterControl.GetForCharacter(character)
	if ctrl then
		ctrl:PushLock("Skill:DashStyleRoll", { Jump = true, Sprint = true })
		ctrl:PopLock("Skill:DashStyleRoll")
	end

	【示例 — 仅冻速（不关 Controls）】
	ctrl:PushLock("UI:Shop", { Move = true }) -- 默认 SpeedOnly
	-- 或显式：{ Move = true, MovePolicy = "SpeedOnly" }

	【示例 — 载具/过场真接管】
	ctrl:TransferControlOwner("Vehicle:Bike") -- 默认 FullLock + DisableControls
	-- ...
	ctrl:ReleaseControlOwner("Vehicle:Bike")

	【示例 — 交互边沿】
	local intent = ctrl:GetIntent() -- 返回字段浅拷贝，勿依赖改表回写
	if intent.interactPressed then
		-- 打开门 / 对话；Interact 锁生效时 GetIntent 已清边沿
	end

	【子模块】
	- ControlInstance / Constants / IntentSampler / LockMask / SprintMode / JumpPolicy / PlayerControlsBridge

	【配置】GameConfig.CharacterControl + settingConf.RunMode

	【Attribute】
	- IsControlLookLocked / IsControlInteractLocked（LocalPlayer；LockMask 聚合）
]]

local ControlInstance = require(script.ControlInstance)

export type IntentSnapshot = ControlInstance.IntentSnapshot
export type LockChannels = ControlInstance.LockChannels
export type LockMaskSpec = ControlInstance.LockMaskSpec
export type MovePolicy = ControlInstance.MovePolicy
export type GaitMode = ControlInstance.GaitMode
export type SprintInputMode = ControlInstance.SprintInputMode
export type MoveSpeedBind = ControlInstance.MoveSpeedBind
export type ApiKind = ControlInstance.ApiKind
export type CreateOptions = ControlInstance.CreateOptions
export type CharacterControlInstance = ControlInstance.CharacterControlInstance

local CharacterControl = {}

--[[
	查询已 Create 实例
	@param character Model - 角色模型
	@return CharacterControlInstance? - 已创建实例；未 Create 或不存在为 nil
]]
function CharacterControl.GetForCharacter(character: Model): CharacterControlInstance?
	return ControlInstance.get(character)
end

--[[
	创建角色级 Control（仅本地玩家角色应由 CharacterManager 调用；重复 Create 返回已有实例）
	@param character Model - 角色模型
	@param options CreateOptions? - 须含 moveSpeedBind（CharacterMoveSpeedBind）；enabled=false 时不创建
	@return CharacterControlInstance? - 新实例或已有实例；禁用/非本机/缺依赖时为 nil
]]
function CharacterControl.Create(character: Model, options: CreateOptions?): CharacterControlInstance?
	return ControlInstance.create(character, options)
end

return CharacterControl
