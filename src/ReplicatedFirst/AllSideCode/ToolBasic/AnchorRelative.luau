--[[
	Module: AnchorRelative
	Description: 施法锚点与局部位姿互转 — 框架级通用工具
	Author: 中台组
	Created: 2026-08-03
	Last Modified: 2026-08-03

	挂载：Utils.AnchorRelative（ToolBasic）。MA2/烘焙数据约定存 local，运行时再变世界坐标。

	约定：
	- 烘焙相机/特效/球轨迹一律存相对 anchor 的 local CFrame
	- 运行时：worldCF = anchorCF * localCF
	- anchorCF 由调用方提供（施法快照或跟随 HRP），本模块不持有状态

	加载：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local AnchorRelative = Utils.AnchorRelative
		local worldCF = AnchorRelative.ToWorld(releaseCF, KeyframeEval.EvalCFrame(keys, t))
]]

local AnchorRelative = {}

--[[
	局部位姿变换到世界
	@param anchorCF CFrame - 施法锚点（世界）
	@param localCF CFrame - 相对锚点的局部位姿
	@return CFrame - 世界位姿
]]
function AnchorRelative.ToWorld(anchorCF: CFrame, localCF: CFrame): CFrame
	return anchorCF * localCF
end

--[[
	世界位姿变换到相对锚点的 local
	@param anchorCF CFrame - 施法锚点（世界）
	@param worldCF CFrame - 世界位姿
	@return CFrame - 相对锚点的局部位姿
]]
function AnchorRelative.ToLocal(anchorCF: CFrame, worldCF: CFrame): CFrame
	return anchorCF:ToObjectSpace(worldCF)
end

return AnchorRelative
