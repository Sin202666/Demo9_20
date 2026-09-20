--[[
	Module: FXUtil
	Description: 特效工具模块 — 粒子、模型、动画、音效、滤镜等
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-08-04

	功能：
	- 特效销毁：缓慢删除、消失特效组件
	- 对象池：从对象池获取和返回对象
	- 粒子系统：粒子发射器控制、缩放、发射等
	- 模型操作：缩放、动画、透明度、位置控制等
	- 特效播放：统一特效播放接口
	- 音效播放：音效播放管理
	- ColorCorrection 滤镜与关键帧动画（曲线优先；旧 Tween Deprecated）
	- 贝塞尔曲线、石块爆发、残影、闪电特效

	子模块：
	- ModelFade.luau         模型与 Beam/Trail 淡入淡出
	- NumberSequence.luau    NumberSequence 工具与 Beam 渐显
	- ParticleScale.luau     粒子缩放与数字筛选
	- ParticleEmit.luau      粒子单次爆发发射
	- ParticleControl.luau   粒子/Trail/Beam 开关与渐隐
	- ModelScale.luau        模型缩放与体积保护
	- ModelTransform.luau    透明度/颜色/CFrame 控制与焊接
	- ColorCorrectionSession.luau  CC 写会话 / FXUtilCcBusy 租约
	- ColorCorrection.luau   ColorCorrection 旧栈（Deprecated）
	- ColorCorrectionCurve.luau  ColorCorrection 烘焙曲线
	- TweenUtil.luau         通用 Tween 与抛物线动画
	- ObjectPool.luau        特效对象池借还
	- EffectDestruction.luau 特效缓慢销毁与消失
	- Resource.luau          Debris 与音效
	- PlayEffectPrep.luau    PlayEffect 预处理与挂身焊接
	- SkillBuffDotVfx.luau   DoT 挂身 FX
	- PlayEffect.luau        统一特效播放
	- SkillSettle.luau       技能结算与受击特效
	- GroundAlign.luau       贴地对齐 CFrame
	- LayeredFade.luau       分层消失（保留 Trail）
	- BezierUtil.luau        贝塞尔数学工具
	- BezierAnimBasic.luau   贝塞尔基础曲线动画
	- BezierAnimLookAt.luau  LookAt/缩放/跟随动画
	- BezierAnimMulti.luau   多阶贝塞尔与控制点生成
	- BezierAnim.luau        贝塞尔动画聚合入口
	- BezierCurve.luau       贝塞尔曲线模块聚合入口
	- PlayEffectInternal.luau PlayEffect/DoT 内部工具（非公共 API）
	- BurstStone.luau        石块冲击波/飞石/地裂
	- GhostShadow.luau       残影视觉暂留
	- Lightning.luau         闪电链效果
	- PartIcles.luau         PartIcles 引擎门面（与原生 Emit_* 并存）
	- BeamWidthCurve.luau    Beam Width0/1 关键帧曲线
	- PhasedVfxTree.luau     整树挂锚 + 分阶段 Enable/Emit

	粒子路径约定：
	- 原生 PE/Beam/Trail → Emit_Particles_* / Start_All_Emit / SetEmittersTrailsBeamsEnabled
	- PartIcles（Transformed）→ FXUtil.PartIcles 或 Utils.PartIcles（同一门面）
	- 对象池短期隔离：FXUtil 池与 PartIcles 引擎池勿混还
]]

-- ========================================
-- 模块定义
-- ========================================
local FXUtil = {}

export type PlayEffectOpts = {
	resourceCategory: string?,
	usePool: boolean?,
	parent: Instance?,
}

-- ========================================
-- 子模块加载（顺序依赖：被调用的 API 须先注册）
-- ========================================
local LOAD_ORDER = {
	script.ModelFade,
	script.NumberSequence,
	script.ParticleScale,
	script.ParticleEmit,
	script.ParticleControl,
	script.ModelScale,
	script.ModelTransform,
	script.ColorCorrection,
	script.ColorCorrectionCurve,
	script.TweenUtil,
	script.ObjectPool,
	script.EffectDestruction,
	script.Resource,
	script.PlayEffectPrep,
	script.SkillBuffDotVfx,
	script.PlayEffect,
	script.SkillSettle,
	script.GroundAlign,
	script.LayeredFade,
	script.BeamWidthCurve,
	script.PhasedVfxTree,
}

for _, loader in LOAD_ORDER do
	require(loader)(FXUtil)
end

-- ========================================
-- 独立子模块（嵌套命名空间，保持原 API 表结构）
-- ========================================
FXUtil.BezierCurve = require(script.BezierCurve)
FXUtil.BurstStone = require(script.BurstStone)
FXUtil.GhostShadow = require(script.GhostShadow)
FXUtil.Lightning = require(script.Lightning)
FXUtil.PartIcles = require(script.PartIcles)

return FXUtil
