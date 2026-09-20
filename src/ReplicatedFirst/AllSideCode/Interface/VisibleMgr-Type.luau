--[[
	Module: VisibleMgr-Type
	Description: VisibleMgr 类型声明（完整使用说明见 ToolBasic/VisibleMgr.luau 文件头）
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01
]]

local VisibleMgr = {}

--[[
	关闭模型子树所有 BasePart 阴影

	@param obj Model - 目标模型
]]
function VisibleMgr.CloseShade(obj: Model)
end

--[[
	开启模型子树所有 BasePart 阴影

	@param obj Model - 目标模型
]]
function VisibleMgr.OpenShade(obj: Model)
end

--[[
	禁用模型子树所有 Trail

	@param obj Model - 目标模型
]]
function VisibleMgr.DisableTrail(obj: Model)
end

--[[
	禁用模型子树所有 ProximityPrompt

	@param obj Model - 目标模型
]]
function VisibleMgr.DisableProximityPrompt(obj: Model)
end

--[[
	禁用模型子树所有 ParticleEmitter

	@param obj Model - 目标模型
]]
function VisibleMgr.DisableParticle(obj: Model)
end

--[[
	将对象及其后代 BasePart 设为无质量

	@param obj Instance - 目标对象
]]
function VisibleMgr.MasslessAll(obj: Instance)
end

--[[
	关闭对象及其后代 BasePart 的 CanQuery

	@param obj Instance - 目标对象
]]
function VisibleMgr.UnQueryAll(obj: Instance)
end

--[[
	取消锚定对象及其后代 BasePart

	@param obj Instance - 目标对象
]]
function VisibleMgr.UnAnchoredAll(obj: Instance)
end

--[[
	锚定对象及其后代 BasePart

	@param obj Instance - 目标对象
]]
function VisibleMgr.AnchoredAll(obj: Instance)
end

--[[
	按 R15 部位分组乘算站立透明度

	@param obj Model - 角色模型
]]
function VisibleMgr.SetStandinTransparency(obj: Model)
end

--[[
	按百分比乘算对象及其后代 BasePart 的当前透明度

	@param obj Instance - 目标对象
	@param pst number? - 透明度百分比 0–100；nil 时默认 100
]]
function VisibleMgr.SetTransparency(obj: Instance, pst: number?)
end

--[[
	将对象及其后代 BasePart 设为完全透明

	@param obj Instance - 目标对象
]]
function VisibleMgr.UnTransparencyAll(obj: Instance)
end

--[[
	将对象及其后代 BasePart 设为完全不透明

	@param obj Instance - 目标对象
]]
function VisibleMgr.TransparencyAll(obj: Instance)
end

--[[
	将模型子树 Assembly 速度清零；玩家角色子树拒绝

	@param obj Instance - 目标模型或池化实例
	@return boolean - 已写入 true；无效或拒绝时 false
]]
function VisibleMgr.SpeedDown(obj: Instance): boolean
end

--[[
	仅保留模型子树 Y 轴速度；玩家角色子树拒绝

	@param obj Instance - 目标模型
	@return boolean - 已写入 true；无效或拒绝时 false
]]
function VisibleMgr.SpeedDownY(obj: Instance): boolean
end

--[[
	关闭对象及其后代 BasePart 的 CanTouch

	@param obj Instance - 目标对象
]]
function VisibleMgr.UnTouchAll(obj: Instance)
end

--[[
	关闭对象及其后代 BasePart 的 CanCollide 与 CanQuery

	@param obj Instance - 目标对象
]]
function VisibleMgr.UnCollideAll(obj: Instance)
end

--[[
	开启对象及其后代 BasePart 的 CanQuery

	@param obj Instance - 目标对象
]]
function VisibleMgr.QueryAll(obj: Instance)
end

--[[
	仅开启对象自身及其直接子级 BasePart 的 CanQuery

	@param obj Instance - 目标对象
]]
function VisibleMgr.QueryChildren(obj: Instance)
end

--[[
	开启对象及其后代 BasePart 的 CanCollide

	@param obj Instance - 目标对象
]]
function VisibleMgr.CollideAll(obj: Instance)
end

--[[
	递归淡出对象子树（Tween）

	@param obj Instance - 目标对象
	@param tran number? - 目标透明度；nil 时默认 1
]]
function VisibleMgr.fadeAllTween(obj: Instance, tran: number?)
end

--[[
	递归淡出对象子树（立即设置）

	@param obj Instance - 目标对象
	@param tran number? - 目标透明度；nil 时默认 1
]]
function VisibleMgr.fadeAll(obj: Instance, tran: number?)
end

--[[
	递归显示对象子树并恢复 LastTransparency

	@param obj Instance - 目标对象
]]
function VisibleMgr.showAll(obj: Instance)
end

--[[
	将对象及其后代 BasePart 设为宠物物理

	@param obj Instance - 目标对象
]]
function VisibleMgr.SetPetMass(obj: Instance)
end

--[[
	为对象及其全部后代写入 type Attribute

	@param obj Instance - 目标对象
	@param tp number - 类型编号
]]
function VisibleMgr.AddItemType(obj: Instance, tp: number)
end

--[[
	设置对象的 onlyID Attribute

	@param obj Instance - 目标对象
	@param onlyID number - 唯一 ID
]]
function VisibleMgr.SetOnlyID(obj: Instance, onlyID: number)
end

--[[
	读取对象的 onlyID Attribute

	@param obj Instance - 目标对象
	@return number? - 唯一 ID；无效或未设置时 nil
]]
function VisibleMgr.GetOnlyID(obj: Instance): number?
end

--[[
	为对象及其全部后代写入 OwnerID Attribute

	@param obj Instance - 目标对象
	@param ownerID number - 所有者 ID
]]
function VisibleMgr.AddOwnerID(obj: Instance, ownerID: number)
end

--[[
	设置对象及其后代 BasePart 的 CollisionGroup

	@param obj Instance - 目标对象
	@param collideID string - 碰撞组名
]]
function VisibleMgr.SetCollideID(obj: Instance, collideID: string)
end

--[[
	设置对象及其后代 BasePart 的碰撞组为 Player

	@param obj Instance - 目标对象
]]
function VisibleMgr.SetPlayerCollideID(obj: Instance)
end

--[[
	设置对象及其后代 BasePart 的碰撞组为 Default

	@param obj Instance - 目标对象
]]
function VisibleMgr.SetCollideIDDefault(obj: Instance)
end

--[[
	焊接模型内部 BasePart 到指定锚点

	@param model Instance - 目标模型或单个 BasePart
	@param primary BasePart - 焊接锚点
]]
function VisibleMgr.Weld(model: Instance, primary: BasePart)
end

--[[
	焊接模型自身到 PrimaryPart

	@param model Model - 目标模型
]]
function VisibleMgr.SelfWeld(model: Model)
end

--[[
	彩虹粒子 Heartbeat 色相渐变

	@param particle ParticleEmitter - 粒子发射器
	@param speed number? - 色相变化速度倍率，默认 1
]]
function VisibleMgr.RainBowParticle(particle: ParticleEmitter, speed: number?)
end

--[[
	秘密粒子 Heartbeat 色相渐变

	@param particle ParticleEmitter - 粒子发射器
	@param speed number? - 色相变化速度倍率，默认 1
]]
function VisibleMgr.SecretParticle(particle: ParticleEmitter, speed: number?)
end

--[[
	渐隐角色模型（跳过 HumanoidRootPart）

	@param model Model - 角色模型
	@param transparency number? - 目标透明度，默认 1
	@param tweenTime number? - 变化时间（秒），默认 0.5
	@param easingStyle Enum.EasingStyle? - 缓动曲线，默认 Quad
	@param easingDir Enum.EasingDirection? - 缓动方向，默认 Out
]]
function VisibleMgr.FadeCharacterModel(
	model: Model,
	transparency: number?,
	tweenTime: number?,
	easingStyle: Enum.EasingStyle?,
	easingDir: Enum.EasingDirection?
)
end

--[[
	从渐隐恢复角色模型

	@param model Model - 角色模型
	@param tweenTime number? - 变化时间（秒），默认 0.5
	@param easingStyle Enum.EasingStyle? - 缓动曲线，默认 Quad
	@param easingDir Enum.EasingDirection? - 缓动方向，默认 Out
]]
function VisibleMgr.UnFadeCharacterModel(
	model: Model,
	tweenTime: number?,
	easingStyle: Enum.EasingStyle?,
	easingDir: Enum.EasingDirection?
)
end

--[[
	将 root 子树当前视觉状态写入 Init* Attribute

	@param root Instance - 模型或特效根节点
]]
function VisibleMgr.SnapshotDefaultVisualState(root: Instance)
end

--[[
	从 template 同步 Init* Attribute 到 model

	@param model Instance - 池化实例
	@param template Instance - 资源模板
]]
function VisibleMgr.SyncDefaultVisualSnapshotFromTemplate(model: Instance, template: Instance)
end

--[[
	按 Init* Attribute 恢复 root 子树默认视觉状态

	@param root Instance - 模型或特效根节点
]]
function VisibleMgr.RestoreDefaultVisualState(root: Instance)
end

return VisibleMgr
