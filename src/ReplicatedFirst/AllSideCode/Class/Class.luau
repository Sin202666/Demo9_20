local Class = {}

--动画系统类型
export type BaseAnimateEnum = "Walk" | "Run" | "Idle" | "Jump" | "Fall" | "Swim" | "Climb" | "Land" | "LightLand" | "StartRun" | "StopRun" | "StartWalk" | "StopWalk"

--角色动作类
export type AnimateType = {
	Animator:Animator,
	CurrentBaseTrack:AnimationTrack,
}

--NPC对话类
export type Talk = {
    npcName: string,
    npcRootPart: Part,
    npcReplyUI: Frame,
    optionUI: Frame,
    optionListKey: string,
    talkKey: string,
    prompt: ProximityPrompt,
    isShowingReply: boolean,
    isTalking: boolean,
    isShowingTalk: boolean,
    isShowingOption: boolean,
    eventConnectTable: {ProximityPrompt:{RBXScriptConnection}},
    buttonConnectTable: {TextButton:{RBXScriptConnection}},
    talkConfig: {
        NPCTalkList: {string: {string: string}},
        ChatOptionContent: {string: {string: {string: string}}},
    },
    showNpcReply: (self: Talk, talkKey: string) -> nil,
    showOption: (self: Talk, optionListKey: string) -> nil,
    start: (self: Talk, startOptionListKey: string?, startTalkKey: string?) -> nil,
    stop: (self: Talk) -> nil,
    clear: (self: Talk) -> nil,
}

--RNG保底数据类
export type PityData  = {
    rngCount: number,          --累计抽取次数
    rarePity: {number:number}, --稀有度：已累计次数
    unitPity: {number:number}, --角色ID：已累计次数
}

export type RngConfig = {
	poolName: string,
	pool: {[number]: number},
	weight: {[number]: number},
	cost: number, --抽取货币类型
	price: number, --抽取货币数量
}

--RNG系统类
export type RngSystem = {
    poolName: string,
    rarePity: any,
    unitPity: any,
    config: RngConfig,
    updatePityConfig: (self: RngSystem, rarePityPityConfig: any, unitPityConfig: any) -> nil,
    roll: (self: RngSystem, nowPityData: PityData) -> (number, PityData),
    getCurrency: (self: RngSystem, rngCount: number) -> (number, number),
}

--命中检测数据类 用来创建Hitbox对象
export type HitboxData = {
    --hitbox所有者类型
    hitboxOwnerType: "Player" | "NPC",
    --hitbox所有者
    hitboxOwnerId: number,
    --命中检测索引
    hitboxIndex: number,
    --用作检测的部件名字（与SkillHitboxConfig.PartName对应）
    PartName: string,
    --检测对象的碰撞组
    collisionGroup: string,
    --激活范围
    ActiveRange: NumberRange,
    --命中特效名字
    EffectName: string,
    --命中音效名字
    SoundName: string,
    --技能名称
    skillName: string,
}

--Hitbox对象 命中检测的载体
export type Hitbox = {
    hitbox: BasePart,
    hitboxOwnerType: "Player" | "NPC",
    hitboxOwnerId: number,
    hitboxIndex: number,
    skillName: string,
    -- hitServer/hitClient 已迁移至 HitResolver，Hitbox 仅负责检测
    check: (self: Hitbox) -> {[Model]: BasePart},
    start: (self: Hitbox) -> nil,
    stop: (self: Hitbox) -> nil,
    resetCheckedParts: (self: Hitbox) -> nil,
    destroy: (self: Hitbox) -> nil,
}

--技能命中Box配置 在每个技能配置表中都有这个配置 来配置命中特效、音效、伤害率、物理效果等
export type SkillHitboxConfig = {
    HitboxIndex: number,
    PartName: string,
    CollisionGroup: string,
    EffectName: string,
    SoundName: string,
    DamageRate: number,
    PhysicsEffectName: string,
}

--玩家位置同步包
export type SynPlayerSpaceData = {
    posx: number,
    posy: number,
    posz: number,
    angx: number,
    angy: number,
    angz: number,
}

--[[
    技能权威状态（显式状态层）
    后续逐步将 isRunning/mainState/currentBaseSkillIndex 等隐式状态收敛到此
    非状态机重构，仅提供明确语义供逻辑判断
]]
export type BaseSkillState = "Idle" | "Running" | "Stopping" | "Finished" | "Interrupted"
export type GroupSkillState = "Idle" | "WaitingStart" | "RunningBaseSkill" | "WaitingDerive" | "Finished" | "Interrupted"

--组技能初始化数据包
export type GroupSkillInitData = {
    --角色类型
    characterType: "Player" | "NPC",
    --角色ID 玩家ID或怪物ID
    characterId: number,
    --技能名称
    skillName: string,
    --技能强度（用于尺寸、伤害等调整，默认 1）
    skillPower: number?,
    --技能纯度（默认 1）
    skillPurity: number?,
}

--技能输入数据包（用于组技能和基础技能）
export type SkillInputData = {
    --角色ID
    characterId: number,
    --角色类型
    characterType: "Player" | "NPC",
    --技能名称（基础技能名称，组技能时可为空）
    skillName: any,
    --技能释放位置
    releaseCF: CFrame,
    --技能释放目标位置
    targetCF: CFrame,
    --战斗种子（服务端权威生成，用于暴击/伤害浮动等；客户端仅接收同步）
    combatSeed: any,
    --移动方向字符串（Forward/Backward/Left/Right）
    moveDirectionStr: string?,
    --实例 ID（用于多实例精准同步）
    skillCastId: string?,
    baseSkillInstanceId: string?,
    activeBaseSkillIndex: number?,
    -- 内部用：跳过 BaseSkillServer 的 SynSkillEffect 发送（由 GroupSkillServer 统一发送）
    skipClientSync: boolean?,
    -- 追踪目标 id（权威）：客户端从 ReplicatedStorage.NowTargetCurrent 解析后上传，服务端/全客户端飞行中按 id 解析 HRP
    trackTargetId: any?,
    -- 一期表现预测：客户端生成，服务端校验通过后可作为本次 skillCastId，便于与 BaseSkillStarted 对齐
    clientPredictCastId: string?,
}

--SynSkillEffect 同步包（含 BaseSkillDerived 派生确认、HitConfirmed 命中确认）
export type SynSkillEffectData = {
    characterId: number,
    characterType: "Player" | "NPC",
    skillName: any,
    releaseCF: CFrame,
    targetCF: CFrame,
    combatSeed: any,
    moveDirectionStr: string?,
    skillCastId: string?,
    baseSkillInstanceId: string?,
    activeBaseSkillIndex: number?,
    -- BaseSkillDerived / BaseSkillStarted 专用
    eventType: string?,
    fromBaseSkillIndex: number?,
    toBaseSkillIndex: number?,
    breakLastSkill: boolean?,
    nextBaseSkillName: string?,
    -- BaseSkillStarted 专用（服务端确认驱动）
    slotIndex: number?,
    groupSkillName: string?,
    skillPower: number?,
    skillPurity: number?,
    -- HitConfirmed / ProjectileHitConfirmed 命中确认专用
    timelineTime: number?,
    hitPosition: Vector3?,
    targetId: any?,
    hitboxIndex: number?,
    hitType: "Enemy" | "Obstacle"?,  -- ProjectileHitConfirmed 专用
    -- 弹道追踪：与 SkillInputData.trackTargetId 一致，随 BaseSkillStarted / BaseSkillDerived 同步
    trackTargetId: any?,
}

--StopSkill 同步包（精准停止单实例）
export type StopSkillData = {
    characterId: number,
    characterType: "Player" | "NPC",
    skillName: string,
    skillCastId: string?,
    baseSkillInstanceId: string?,
    reason: "Finished" | "Interrupted" | "Replaced"?,
}

--技能攻击数据类（用于伤害计算）
export type SkillAttackData = {
    --攻击力面板
    attackPower: number,
    --暴击率（0-1）
    criticalRate: number,
    --暴击伤害倍率
    criticalDamage: number,
    --元素强化值
    elementEnhancement: number,
    --最终伤害加成（倍率）
    finalDamageBonus: number,
    --技能名称
    skillName: string,
    --Hitbox索引
    hitboxIndex: number,
}

--技能防御数据类（用于伤害计算）
export type SkillDefendData = {
    --元素抗性（0-1，表示抗性百分比）
    elementResistance: number,
    --元素种类
    elementType: string,
    --最终伤害减免（倍率）
    finalDamageReduction: number,
}

--组技能服务器类
export type GroupSkillServer = {
    authoritativeState: GroupSkillState?,   -- 显式权威状态，后续逐步替代隐式判断
    skillName: string,                       --查找对应技能组配置
    skillInputData: SkillInputData,     --保存技能输入数据
    nowTime: number,                         --当前时间
    skillPower: number,                      --技能强度
    skillPurity: number,                     --技能纯度
    skillPlaySpeed: number,                  --技能播放速度
    groupSkillCooldown: number,              --组技能冷却配置值
    groupSkillCooldownRemaining: number,     --剩余冷却时间，0 表示冷却完成
    groupSkillModule : any,                  --组技能模块
    groupSkillCooldownEvent: RBXScriptConnection, --组技能冷却倒计时事件
    groupSkillRuntimeEvent: RBXScriptConnection, --组技能运行事件
    requestRelease: (self: GroupSkillServer, skillInputData: SkillInputData) -> nil,  --请求释放组技能
    requestStop: (self: GroupSkillServer) -> nil,                                          --请求停止组技能
}

--组技能客户端类
export type GroupSkillClient = {
    authoritativeState: GroupSkillState?,   -- 显式权威状态，后续逐步替代隐式判断
    skillName: string,
    skillPower: number,
    skillPurity: number,
    characterId: number,
    characterType: "Player" | "NPC",
    isRunning: boolean,
    nowTime: number,
    skillInputData: SkillInputData,
    skillTimeFix: number,
    skillPlaySpeed: number,
    runningBaseSkillInstances: {BaseSkillClient},
    completedBaseSkillIndex: {number},
    activeBaseSkillIndex: number,
    skillRunData: {any},
    groupSkillRuntimeEvent: RBXScriptConnection,
    combatSeed: any,
    skillStartTimestamp: number,
    skillStart: (self: GroupSkillClient) -> nil,
}

--基础技能服务器类
export type BaseSkillServer = {
    authoritativeState: BaseSkillState?,   -- 显式权威状态，与 mainState 并存过渡
    skillName: string,
    skillInputData: SkillInputData,
    nowTime: number,
    skillTimeFix: number,
    skillPlaySpeed: number,
    skillMaterial: {any},
    skillModule: {any},
}

--基础技能客户端类
export type BaseSkillClient = {
    authoritativeState: BaseSkillState?,   -- 显式权威状态，与 mainState 并存过渡
    skillName: string,
    skillInputData: SkillInputData,
    nowTime: number,
    skillTimeFix: number,
    skillPlaySpeed: number,
    skillMaterial: {any},
    skillModule: {any},
    skillRunThread: thread,
    skillTimeUpdateEvent: RBXScriptConnection,
    skillStart: (self: BaseSkillClient) -> nil,
    skillRun: (self: BaseSkillClient) -> nil,
    skillInterrupt: (self: BaseSkillClient) -> nil,
    skillEnd: (self: BaseSkillClient) -> nil,
}

return Class