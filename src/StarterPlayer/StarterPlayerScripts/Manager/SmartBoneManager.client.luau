--[[
	Module: SmartBoneManager
	Description: 客户端动态骨骼管理器，启动 SmartBone 物理模拟
	Author: Dev-Framework
	Created: 2026-07-03
	Last Modified: 2026-07-03

	功能：
	- 启动 Utils.SmartBone（SmartBone2），扫描 CollectionService 标签 "SmartBone" 的对象并运行模拟

	配置（GameConfig.SmartBone）：
	- 启用：false 时本 Manager 不运行

	依赖：
	- Utils.SmartBone：实现见 ClientSideCode/SystemModule/SmartBone

	场景约定（带 SmartBone 标签的根 MeshPart / BasePart）：
	- ActivationDistance number - 激活距离，超出后停止模拟
	- AnchorDepth number - 自根向下锚定深度
	- AnchorsRotate boolean - 根骨是否随其余骨骼旋转（位置/朝向是否锁定）
	- Constraint string - "Spring" | "Distance" | "Rope"
	- Damping / Stiffness / Elasticity / Inertia number - 阻尼、刚度、弹性、惯性
	- MatchWorkspaceWind boolean - 是否匹配工作区全局风向
	- WindInfluence / WindType string - 风影响与类型（Sine | Noise | Hybrid）
	- ColliderKey string - 碰撞器匹配键，空则与全部碰撞器交互
	- ThrottleDistance number - 按距离节流模拟的距离阈值
	- Gravity / Force Vector3 - 重力与附加力（世界空间）
	- UpdateRate number - 模拟帧率（次/秒）
	- Radius number - 骨骼碰撞半径
	- Roots string - 根 Bone 名称或 PinGroup 等组合名

	示例：
	- 给模型根 Part 打 CollectionService 标签 "SmartBone"，按需设置上述 Attribute 后由本 Manager 自动接管
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SystemGameConfig = Utils.SystemGameConfig

if SystemGameConfig.GetValue({ "SmartBone", "启用" }) == false then
	return
end

local SmartBone = Utils.SmartBone

-- ========================================
-- 初始化
-- ========================================
SmartBone.Start()
