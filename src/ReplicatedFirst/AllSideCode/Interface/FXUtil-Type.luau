local module = {}

-- ============================================
-- 特效销毁函数 (Effect Destruction Functions)
-- ============================================

--[[
	缓慢删除特效组件（带淡出动画，最后销毁）
	@param instance: Instance | Model - 要删除的实例
	@param slowTime: number? - 淡出时间（可选，默认0.25，如果未指定会自动计算）
]]
function module.Slow_Destroy_Instance(instance: Instance | Model, slowTime: number?)
end

--[[
	缓慢消失特效组件（带淡出动画，不销毁）
	@param instance: Instance | Model - 要消失的实例
	@param slowTime: number? - 淡出时间（可选）
]]
function module.Slow_Disapear_Instance(instance: Instance | Model, slowTime: number?)
end

-- ============================================
-- 对象池函数 (Object Pool Functions)
-- ============================================

--[[
	从对象池获取实例
	@param instance: Instance - 实例模板
	@return Instance? - 从对象池获取的实例
]]
function module.GetInstance_From_Pool(instance: Instance): Instance?
end

--[[
	将实例返回到对象池
	@param instance: Instance - 要返回的实例
]]
function module.BackPool_Instance(instance: Instance)
end

-- ============================================
-- 数字处理函数 (Number Processing Functions)
-- ============================================

--[[
	数字筛选器（检查数字是否能被间隔整除）
	@param num: number - 要检查的数字
	@param interval: number - 间隔值
	@return boolean, number - 是否整除，下一个数字
]]
function module.Number_Filtrate(num: number, interval: number): (boolean, number)
end

-- ============================================
-- 粒子系统函数 (Particle System Functions)
-- ============================================

--[[
	缩放粒子发射器（缩放所有相关属性）
	@param particleEmitter: ParticleEmitter | {ParticleEmitter} - 粒子发射器或包含粒子发射器的表
	@param scale: number - 缩放比例
]]
function module.Scale_Particle(particleEmitter: ParticleEmitter | { ParticleEmitter }, scale: number)
end

--[[
	缩放粒子大小
	@param particleEmitter: ParticleEmitter | {ParticleEmitter} - 粒子发射器或包含粒子发射器的表
	@param scale: number - 缩放比例
]]
function module.Scale_Particle_Size(particleEmitter: ParticleEmitter | { ParticleEmitter }, scale: number)
end

--[[
	发射所有子对象的粒子
	@param instance: Model | ParticleEmitter - 模型或粒子发射器
	@param isCloseEnabled: boolean? - 是否关闭Enabled（可选）
]]
function module.Emit_Particles_Children(instance: Model | ParticleEmitter, isCloseEnabled: boolean?)
end

--[[
	发射所有后代对象的粒子（包括自身）
	@param instance: Model | ParticleEmitter - 模型或粒子发射器
	@param isCloseEnabled: boolean? - 是否关闭Enabled（可选）
]]
function module.Emit_Particles_GetDescendants(instance: Model | ParticleEmitter, isCloseEnabled: boolean?)
end

--[[
	用已缓存的 ParticleEmitter / Beam 单次爆发（不再 GetDescendants）
	@param emitters { ParticleEmitter } - 发射器列表
	@param beams { Beam }? - Beam 列表
	@param isCloseEnabled boolean? - 是否关闭粒子 Enabled
]]
function module.Emit_Particles_Cached(emitters: { ParticleEmitter }, beams: { Beam }?, isCloseEnabled: boolean?)
end

--[[
	停止所有粒子
	@param instance: Model | ParticleEmitter - 模型或粒子发射器
]]
function module.Stop_All_Particles(instance: Model | ParticleEmitter)
end

--[[
	启动所有粒子
	@param instance: Model | ParticleEmitter - 模型或粒子发射器
]]
function module.Start_All_Particles(instance: Model | ParticleEmitter)
end

--[[
	启动粒子发射（帧事件控制）
	@param particleEmitter: ParticleEmitter - 粒子发射器
	@param duringTime: number? - 持续时间（可选）
]]
function module.Start_Emit(particleEmitter: ParticleEmitter, duringTime: number?)
end

--[[
	停止粒子发射（帧事件控制）
	@param particleEmitter: ParticleEmitter - 粒子发射器
]]
function module.Stop_Emit(particleEmitter: ParticleEmitter)
end

--[[
	开始所有粒子发射器发射（帧事件控制）
	@param instance: Model - 目标模型
	@param duringTime: number? - 持续时间（可选）
]]
function module.Start_All_Emit(instance: Model, duringTime: number?)
end

--[[
	停止所有粒子发射器发射（帧事件控制）
	@param instance: Model - 目标模型
]]
function module.Stop_All_Emit(instance: Model)
end

-- ============================================
-- 模型缩放函数 (Model Scale Functions)
-- ============================================

--[[
	简单部件缩放动画
	@param part: BasePart - 目标部件
	@param tweenTime: number - 动画时间
	@param goalSize: Vector3 - 目标大小
	@param easingStyle: Enum.EasingStyle? - 缓动样式（可选）
	@param easingDir: Enum.EasingDirection? - 缓动方向（可选）
]]
function module.BasePart_Size_Tween(part: BasePart, tweenTime: number, goalSize: Vector3, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?)
end

--[[
	缩放模型（递归缩放所有部件和附件）
	@param model: Model - 模型
	@param scale: number? - 缩放比例（可选，默认1）
	@return Model - 缩放后的模型
]]
function module.Scale_Model(model: Model, scale: number?): Model
end

--[[
	缩放模型（Tween动画）
	@param model: Model - 模型
	@param tweenTime: number - 动画时间
	@param scale: number - 缩放比例
	@param easingStyle: Enum.EasingStyle? - 缓动样式（可选）
	@param easingDir: Enum.EasingDirection? - 缓动方向（可选）
	@param canMove: boolean? - 是否可以移动（可选）
]]
function module.Scale_Model_Tween(model: Model, tweenTime: number, scale: number, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?, canMove: boolean?)
end

--[[
	设置模型缩放（使用GetScale/SetScale）
	@param model: Model - 模型
	@param scale: number - 缩放比例
]]
function module.Set_Scale_Model(model: Model, scale: number)
end

--[[
	设置模型缩放（Tween动画，使用GetScale/SetScale）
	@param model: Model - 模型
	@param tweenTime: number - 动画时间
	@param scale: number - 缩放比例
	@param easingStyle: Enum.EasingStyle? - 缓动样式（可选）
	@param easingDir: Enum.EasingDirection? - 缓动方向（可选）
	@param canMove: boolean? - 是否可以移动（可选）
]]
function module.Set_Scale_Model_Tween(model: Model, tweenTime: number, scale: number, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?, canMove: boolean?)
end

--[[
	模型缩放动画（从初始尺寸变换到最终尺寸，完成后调用回调）
	@param model: Model - 目标模型
	@param startScale: number - 初始缩放系数
	@param endScale: number - 最终缩放系数
	@param tweenTime: number - 变换时间（秒）
	@param easingStyle: Enum.EasingStyle? - 变换曲线（可选，默认 Linear）
	@param easingDir: Enum.EasingDirection? - 变换方向（可选，默认 In）
	@param callback: (() -> ())? - 完成回调（可选）
	@param canMove: boolean? - 是否允许外部控制位置（true=与 BezierCurve 等配合；false=固定位置，默认）
]]
function module.Model_Scale_Tween(model: Model, startScale: number, endScale: number, tweenTime: number, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?, callback: (() -> ())?, canMove: boolean?)
end

--[[
	Part 缩放动画（以 Part 的初始 Size 为基准，从 startScale 变换到 endScale，完成后调用回调）
	@param part: BasePart - 目标部件
	@param startScale: number - 初始缩放系数
	@param endScale: number - 最终缩放系数
	@param tweenTime: number - 变换时间（秒）
	@param easingStyle: Enum.EasingStyle? - 变换曲线（可选，默认 Linear）
	@param easingDir: Enum.EasingDirection? - 变换方向（可选，默认 In）
	@param callback: (() -> ())? - 完成回调（可选）
	@param isChangeAttachment: boolean? - 是否同时缩放 Attachment（可选，默认 false）
]]
function module.Part_Scale_Tween(part: BasePart, startScale: number, endScale: number, tweenTime: number, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?, callback: (() -> ())?, isChangeAttachment: boolean?)
end

--[[
	直接缩放BasePart
	@param part: BasePart - 目标部件
	@param scale: number - 缩放系数
	@param isChangeAttachment: boolean? - 是否同时缩放Attachment（可选）
]]
function module.Set_Scale_Basepart(part: BasePart, scale: number, isChangeAttachment: boolean?)
end

--[[
	直接缩放BasePart（Tween动画）
	@param part: BasePart - 目标部件
	@param tweenTime: number - 动画时间
	@param scale: number - 缩放系数
	@param easingStyle: Enum.EasingStyle? - 缓动样式（可选）
	@param easingDir: Enum.EasingDirection? - 缓动方向（可选）
	@param canMove: boolean? - 是否可以移动（可选）
	@param isChangeAttachment: boolean? - 是否同时缩放Attachment（可选）
]]
function module.Set_Scale_Basepart_Tween(part: BasePart, tweenTime: number, scale: number, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?, canMove: boolean?, isChangeAttachment: boolean?)
end

-- ============================================
-- 透明度和位置动画函数 (Transparency and Position Animation)
-- ============================================

--[[
	模型整体透明度动画
	@param instance: Model - 目标模型
	@param tweenTime: number? - 动画时间（可选，默认0.1）
	@param tweenValue: number - 目标透明度值
	@param easingStyle: Enum.EasingStyle? - 缓动样式（可选，默认Linear）
	@param easingDir: Enum.EasingDirection? - 缓动方向（可选，默认In）
]]
function module.Model_Transparency_Tween(instance: Model, tweenTime: number?, tweenValue: number, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?)
end

--[[
	模型CFrame动画
	@param model: Model - 目标模型
	@param tweenTime: number - 动画时间
	@param newCF: CFrame - 目标CFrame
	@param easingStyle: Enum.EasingStyle? - 缓动样式（可选）
	@param easingDir: Enum.EasingDirection? - 缓动方向（可选）
	@param canMove: boolean? - 是否允许移动（可选，默认false）
]]
function module.Set_CFrame_Model_Tween(model: Model, tweenTime: number, newCF: CFrame, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?, canMove: boolean?)
end

-- ============================================
-- 焊接相关函数 (Weld Functions)
-- ============================================

--[[
	焊接部件
	@param main: BasePart - 主部件
	@param weldPart: BasePart - 要焊接的部件
]]
function module.Weld(main: BasePart, weldPart: BasePart)
end

--[[
	取消焊接
	@param main: BasePart - 主部件
]]
function module.Unweld(main: BasePart)
end

-- ============================================
-- 模型控制函数 (Model Control Functions)
-- ============================================

--[[
	控制模型位置（帧事件控制）
	@param instance: Model - 目标模型
	@param func: (number) -> CFrame - 函数，接收时间参数，返回CFrame
]]
function module.Control_Model_CFrame(instance: Model, func: (number) -> CFrame)
end

--[[
	取消控制模型位置（帧事件控制）
	@param instance: Model - 目标模型
]]
function module.Uncontrol_Model_CFrame(instance: Model)
end

--[[
	控制模型位置（帧事件备用控制）
	@param instance: Model - 目标模型
	@param func: (number) -> CFrame - 函数，接收时间参数，返回CFrame
]]
function module.Control_Model_CFrame_Standby(instance: Model, func: (number) -> CFrame)
end

--[[
	取消控制模型位置（帧事件备用控制）
	@param instance: Model - 目标模型
]]
function module.Uncontrol_Model_CFrame_Standby(instance: Model)
end

--[[
	控制附件位置（帧事件控制）
	@param instance: Attachment - 目标附件
	@param func: (number) -> CFrame - 函数，接收时间参数，返回CFrame
]]
function module.Control_Attachment_CFrame(instance: Attachment, func: (number) -> CFrame)
end

--[[
	取消控制附件位置（帧事件控制）
	@param instance: Attachment - 目标附件
]]
function module.Uncontrol_Attachment_CFrame(instance: Attachment)
end

-- ============================================
-- 淡入淡出函数 (Fade Functions)
-- ============================================

--[[
	模型逐渐消失（淡出）
	@param instance: Model - 目标模型
	@param fadeTime: number? - 淡出时间（可选，默认0.1）
]]
function module.Model_Fade(instance: Model, fadeTime: number?)
end

--[[
	模型逐渐显示（淡入）
	@param instance: Model - 目标模型
	@param fadeTime: number? - 淡入时间（可选，默认0.1）
	@param easingStyle: Enum.EasingStyle? - 缓动样式（可选，默认Linear）
	@param easingDir: Enum.EasingDirection? - 缓动方向（可选，默认In）
	@param transValue: number? - 目标透明度值（可选，默认0）
]]
function module.Model_Fade_In(instance: Model, fadeTime: number?, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?, transValue: number?)
end

--[[
	光束/轨迹淡入淡出动画
	@param beam: Beam | Trail - 光束或轨迹对象
	@param tweenTime: number? - 动画时间（可选，默认0.1）
	@param transparency: NumberSequence - 目标透明度序列
	@param easingStyle: Enum.EasingStyle? - 缓动样式（可选）
	@param easingDir: Enum.EasingDirection? - 缓动方向（可选）
]]
function module.Beam_Object_Fade(beam: Beam | Trail, tweenTime: number?, transparency: NumberSequence, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?)
end

--[[
	Beam 对象渐隐至完全透明，完成后禁用并恢复原始透明度
	@param beam: Beam - 目标 Beam 对象
	@param tweenTime: number - 动画时长（秒）
	@param easingStyle: Enum.EasingStyle? - 变化曲线（可选，默认 Linear）
	@param easingDir: Enum.EasingDirection? - 变化方向（可选，默认 In）
]]
function module.Beam_Fade_To_Transparent_Then_Disable(beam: Beam, tweenTime: number, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?)
end

--[[
	Beam 对象从完全透明渐显至原始透明度
	先将 Beam 设为完全透明，再在指定时间内按指定曲线逐渐恢复到开始时的透明度
	@param beam: Beam - 目标 Beam 对象
	@param tweenTime: number - 动画时长（秒）
	@param easingStyle: Enum.EasingStyle? - 变化曲线（可选，默认 Linear）
	@param easingDir: Enum.EasingDirection? - 变化方向（可选，默认 In）
]]
function module.Beam_Fade_From_Transparent(beam: Beam, tweenTime: number, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?)
end

-- ============================================
-- 统一操作函数 (Unified Operation Functions)
-- ============================================

--[[
	统一结算技能攻击效果
	@param target: Model - 目标模型
	@param hitPoint: Vector3? - 命中点位置（可选）
]]
function module.Settle_Skill_Effect(target: Model, hitPoint: Vector3?)
end

--[[
	统一结算技能攻击效果（多次）
	@param target: Model - 目标模型
	@param settleTimes: number - 结算次数
	@param settleDelay: number? - 结算延迟（可选）
]]
function module.Settle_Skill_All_Effects(target: Model, settleTimes: number, settleDelay: number?)
end

--[[
	统一命中效果
	@param effectName: string - 效果名称
	@param cf: CFrame | BasePart - 位置或部件
	@param soundName: string? - 音效名称（可选）
]]
function module.Hit_Effect(effectName: string, cf: CFrame | BasePart, soundName: string?)
end

--[[
	延迟销毁实例
	@param instance: Instance - 要销毁的实例
	@param delayTime: number? - 延迟时间（可选，默认0）
]]
function module.Debris(instance: Instance, delayTime: number?)
end

--[[
	播放音效
	@param data: {[string]: any} - 音效数据
	@param soundName: string - 音效名称
	@param playTimes: number? - 播放次数（可选）
	@param playDis: number? - 播放距离（可选）
	@param pos: Vector3? - 播放位置（可选）
	@param isFadeIn: boolean? - 是否淡入（可选）
	@param fadeTime: number? - 淡入时间（可选）
	@param maxNum: number? - 最大数量（可选）
]]
function module.PlaySound(data: {[string]: any}, soundName: string, playTimes: number?, playDis: number?, pos: Vector3?, isFadeIn: boolean?, fadeTime: number?, maxNum: number?)
end

--[[
	播放特效（仅客户端；服务端无操作）
	@param effectName string
	@param cf BasePart | CFrame
	@param emitTime number?
	@param effectType number? 1-5
	@param offset CFrame?
	@param scale number?
	@param playOpts PlayEffectOpts?
	@return Instance?
]]
export type PlayEffectOpts = {
	resourceCategory: string?,
	usePool: boolean?,
	parent: Instance?,
}

function module.PlayEffect(
	effectName: string,
	cf: BasePart | CFrame,
	emitTime: number?,
	effectType: number?,
	offset: CFrame?,
	scale: number?,
	playOpts: PlayEffectOpts?
): Instance?
end

function module.Emit_Particles_GetDescendants_NoDelay(instance: Model | ParticleEmitter, isCloseEnabled: boolean?)
end

function module.SetEmittersTrailsBeamsEnabled(root: Instance, enabled: boolean)
end

function module.EmitOnceThenEnableContinuous(root: Instance)
end

function module.OffEnableVfx(root: Instance)
end

function module.SetEnableNameVfx(root: Instance, enabled: boolean)
end

function module.HideModelBasePartsStopEmit(model: Model)
end

function module.CollectModelBaseParts(root: Instance): { BasePart }
end

function module.SetAllBasePartsSize(root: Instance, size: Vector3)
end

function module.SetAllBasePartsTransparency(root: Instance, transparency: number)
end

function module.PivotModelOnGroundAtWorldY(model: Model, groundWorldPos: Vector3)
end

function module.EmitBurstEmitInName(root: Instance, closeEnabled: boolean?)
end

function module.WireAllBeamsBetweenAttachments(rootA: Instance, rootB: Instance, attachmentNameA: string, attachmentNameB: string)
end

function module.FadeEmittersTrailsBeamsTransparencyOverTime(root: Instance, duration: number, onComplete: (() -> ())?)
end

function module.Start_All_Trail(instance: Instance)
end

function module.CloneNumberSequence(seq: NumberSequence): NumberSequence
end

function module.SampleNumberSequence(seq: NumberSequence, timePos: number): number
end

function module.BuildBeamTransparencyCut(orig: NumberSequence, cutoff: number): NumberSequence
end

function module.Beam_Reveal_From_Left(beam: Beam, revealTime: number, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?)
end

function module.PreparePooledModelForReuse(model: Model, template: Model?)
end

function module.ResetPooledModelBeforeBackPool(model: Model)
end

function module.ReturnPooledModelToPool(model: Model)
end

function module.PrepEffectForWorldShared(effect: Instance, usePoolModel: boolean)
end

function module.WeldFxModelToBasePart(fx: Model, worldPart: BasePart, pivotOffset: CFrame?): boolean
end

function module.CloneModelResEffectModel(effectName: string): Model?
end

function module.PlayModelResSkillBuffDotHitFx(vfxName: string, defenderUserId: number?, monsterId: string?, durationSec: number?)
end

function module.StopModelResSkillBuffDotHitFx(vfxName: string, defenderUserId: number?, monsterId: string?)
end

function module.GetGroundAlignedCF(planarPos: Vector3, flatHint: Vector3, rayTag: string?, rayUpOffset: number?, groundLift: number?): CFrame?
end

function module.FadeModel_KeepTrails(model: Instance, beamFadeTime: number?, destroyAfter: number?)
end

function module.Instance_Transparency_Tween(root: Instance, tweenTime: number?, tweenValue: number, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?)
end

function module.Instance_Color_Tween(root: Instance, tweenTime: number, goalColor: Color3, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?)
end

function module.Pivot_Instance_CF_Lerp_Heartbeat(root: Instance, goalCF: CFrame, duration: number, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?)
end

function module.Get_Model_Volume(model: Model): number
end

function module.Protect_Model_Volume(model: Model, maxVolume: number): boolean
end

function module.Model_Parabola_Scale_Tween(
	model: Model,
	startScale: number,
	endScale: number,
	tweenTime: number,
	startPos: Vector3,
	endPos: Vector3,
	apexHeight: number,
	easingStyle: Enum.EasingStyle?,
	easingDir: Enum.EasingDirection?,
	callback: (() -> ())?
)
end

--[[
	传入两个Attachment 控制这两个Attachment的CFrame从CFrame.new(0,0,0)到offset位置在时间轴上进行插值，使用TweenService进行插值
	@param attachment1 Attachment - 附件1
	@param attachment2 Attachment - 附件2
	@param offset Vector3 - 偏移
	@param time number - 时间
]]
function module.Tween_Attachment_CFrame(attachment1: Attachment, attachment2: Attachment, time: number,offset: Vector3, easingStyle: Enum.EasingStyle?, easingDir: Enum.EasingDirection?)
end

--[[
	对传入的实例进行Tween动画 
	@param instance Instance - 实例
	@tweenInfo TweenInfo - 动画信息
]]
function module.Tween_Instance(instance: Instance, tweenInfo: TweenInfo, properties: {[string]: any})
end

--[[
	瞬时设置 ColorCorrection（无动画）。
	@deprecated 新演出请用 PlayColorCorrectionCurve
	@param brightness number - 亮度
	@param tintColor Color3 - 色调
	@param saturation number? - 饱和度；nil 则不改
]]
function module.Set_ColorCorrection(brightness: number, tintColor: Color3, saturation: number?)
end

--[[
	还原 Set/Tween/Play 快照或销毁 Temp，并清除 FXUtilCcBusy 租约。
]]
function module.Reset_ColorCorrection()
end

--[[
	旧版 {time,value}+Enum easing 关键帧 Tween（无 Contrast）。
	@deprecated 新演出请用 PlayColorCorrectionCurve
	@param data {[string]: any} - brightness/tintColor/saturation 通道；可选 onComplete
]]
function module.Tween_ColorCorrection(data: { [string]: any })
end

--[[
	查询 FX 是否占用 Lighting ColorCorrection（Attribute FXUtilCcBusy）。
	@return boolean - true 表示占用中；期间 SystemLighting 跳过写 Instance
]]
function module.IsColorCorrectionBusy(): boolean
end

export type NumberKey = {
	t: number,
	v: number,
	ease: string?,
	easeDir: string?,
}

export type ColorCorrectionCurveChannels = {
	saturation: { NumberKey }?,
	contrast: { NumberKey }?,
	brightness: { NumberKey }?,
}

export type ColorCorrectionCurveOpts = {
	restoreOnEnd: boolean?,
	onComplete: (() -> ())?,
	-- true：不自建 Heartbeat 计时，由 handle.Update(elapsed) 驱动（与技能绝对时间轴对齐）
	manualUpdate: boolean?,
}

export type ColorCorrectionCurveHandle = {
	Abort: (restore: boolean?) -> (),
	IsPlaying: () -> boolean,
	-- restoreOnEnd=false 自然结束后为 true，直至 Abort(true)
	IsHolding: () -> boolean,
	-- manualUpdate 时由外部每帧传入绝对时间（秒）；非 manual 时为空操作
	Update: (elapsed: number) -> (),
}

--[[
	播放 ColorCorrection 烘焙曲线（KeyframeEval {t,v}；含 Contrast；占用 FXUtilCcBusy 租约）
	@param channels ColorCorrectionCurveChannels - saturation / contrast / brightness（至少一路非空）
	@param opts ColorCorrectionCurveOpts? - restoreOnEnd 默认 true；manualUpdate；onComplete
	@return ColorCorrectionCurveHandle? - 句柄；无有效通道时 nil
]]
function module.PlayColorCorrectionCurve(
	channels: ColorCorrectionCurveChannels,
	opts: ColorCorrectionCurveOpts?
): ColorCorrectionCurveHandle?
end

export type BeamWidthCurveOpts = {
	restoreOnEnd: boolean?,
	keepWidth1: boolean?,
	onComplete: (() -> ())?,
}

export type BeamWidthCurveHandle = {
	Abort: (restore: boolean?) -> (),
	IsPlaying: () -> boolean,
}

--[[
	播放 Beam Width0/Width1 关键帧曲线
	@param beams Beam | { Beam } - 目标 Beam
	@param width0Keys { NumberKey } - Width0 关键帧（秒）
	@param width1Keys { NumberKey }? - Width1；nil 时与 Width0 共用（keepWidth1 时忽略）
	@param opts BeamWidthCurveOpts? - restoreOnEnd / keepWidth1 / onComplete
	@return BeamWidthCurveHandle? - 句柄
]]
function module.PlayBeamWidthCurve(
	beams: Beam | { Beam },
	width0Keys: { NumberKey },
	width1Keys: { NumberKey }?,
	opts: BeamWidthCurveOpts?
): BeamWidthCurveHandle?
end

--[[
	中断所有 Width 曲线
	@param restore boolean? - true 时还原快照 Width
]]
function module.AbortAllBeamWidthCurves(restore: boolean?)
end

export type PhasedVfxOp = {
	path: string?,
	instanceName: string?,
	op: string,
}

export type PhasedVfxMountOpts = {
	anchorCF: CFrame?,
	attachPart: BasePart?,
	parent: Instance?,
	clone: boolean?,
	usePool: boolean?,
	cueMap: { [string]: { PhasedVfxOp } }?,
}

export type PhasedVfxHandle = {
	root: Instance,
	FireCue: (cueName: string) -> boolean,
	ApplyOps: (ops: { PhasedVfxOp }) -> (),
	SetTrailWindow: (enabled: boolean) -> (),
	Teardown: (delaySec: number?) -> (),
}

--[[
	挂载整棵特效树到锚点，并绑定分阶段 cueMap
	@param source Instance - 模板或已克隆实例
	@param opts PhasedVfxMountOpts? - 锚点/父级/cueMap
	@return PhasedVfxHandle? - 句柄
]]
function module.MountPhasedVfxTree(source: Instance, opts: PhasedVfxMountOpts?): PhasedVfxHandle?
end

-- 嵌套命名空间（详见 BezierCurve-Type / BurstStone-Type 等）
export type BezierCurveNamespace = { [string]: any }
export type BurstStoneNamespace = { [string]: any }
export type GhostShadowNamespace = { [string]: any }
export type LightningNamespace = { [string]: any }
export type PartIclesNamespace = { [string]: any }

return module
