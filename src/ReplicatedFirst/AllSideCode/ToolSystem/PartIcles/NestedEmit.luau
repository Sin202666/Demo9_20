--[[
	Module: NestedEmit
	Description: 嵌套 Transformed Part-Icles 的源树遍历分发（只走 SOURCE RenderTemplate）
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- walk：遍历源 RT，每个 Transformed 叶子经 particle:EnableEmit 发射（link=clonedRoot）
	- walkWithScale：在 walk 基础上把祖先 Model 的 scale 链节点转发给每个 Transformed 子节点

	模块关系：
	- 只走 SOURCE RenderTemplate，绝不 clone 嵌套源子树
	- EnableEmit 的 link 分支负责初始位姿与逐帧跟踪
	- parentAlive 在父 pData 回收时取消嵌套闭包
	- _parentCloneMap 转发 Pool 的 source→clone 映射，供嵌套 Trail/Beam 重绑 Attachment0/1
	- Emit / EmitModel 调用；EmitModel 用 walkWithScale 注册 _parentScaleMap

	加载方式：
		local NestedEmit = require(script.Parent.NestedEmit)

	使用示例：
		NestedEmit.walk(particle, sourceRT, clonedRoot, parentAlive, emitCtx)
		NestedEmit.walkWithScale(particle, sourceRT, clonedRoot, parentAlive, emitCtx, inheritedScale, pData)
]]

local Pool = require(script.Parent.Pool)

local NestedEmit = {}

--[[
	遍历源 RT，对每个 Transformed 叶子调用 EnableEmit。onNode 为可选发射前钩子。

	@param particle table - PartIcles 实例，须有 EnableEmit(node, clonedRoot, descCtx)
	@param sourceRT Instance - 源 RenderTemplate 根，不 clone
	@param clonedRoot Instance - 已克隆的父视觉根，作为 link 传给 EnableEmit
	@param parentAlive (() -> boolean)? - 父粒子仍存活谓词；写入 descCtx._parentAlive
	@param emitCtx table? - 可选发射上下文；转发 ChainCtx / EmitIndex / EmitCount
	@param onNode ((Instance) -> ())? - 发射前钩子；EmitModel 用来登记 _parentScaleMap
]]
function NestedEmit.walk(particle, sourceRT, clonedRoot, parentAlive, emitCtx, onNode)
	local parentCloneMap = Pool._cloneMaps and Pool._cloneMaps[clonedRoot]
	--[[
		递归访问节点：Transformed 则发射并停止下钻，否则遍历子级。

		@param node Instance - 当前源节点
	]]
	local function _visit(node)
		if node:GetAttribute("Transformed") then
			if onNode then onNode(node) end
			local descCtx = {}
			if emitCtx then
				descCtx.ChainCtx  = emitCtx.ChainCtx
				descCtx.EmitIndex = emitCtx.EmitIndex
				descCtx.EmitCount = emitCtx.EmitCount
			end
			descCtx._parentAlive = parentAlive
			descCtx._parentCloneMap = parentCloneMap
			particle:EnableEmit(node, clonedRoot, descCtx)
			return
		end
		for _, child in node:GetChildren() do _visit(child) end
	end
	_visit(sourceRT)
end

--[[
	与 walk 相同，但把继承的 parent-scale 链节点转发给每个 Transformed 子节点。
	Part/Attachment 原样下传同一节点；Model 自建链式节点（见 EmitModel）。
	inheritedScale 为 nil 时退化为普通 walk（顶层发射器无可转发）。
	盖印的源 key 写入 pData._scaleMapKeys 供清理。

	@param particle table - PartIcles 实例；会惰性创建 _parentScaleMap
	@param sourceRT Instance - 源 RenderTemplate 根
	@param clonedRoot Instance - 已克隆父视觉根
	@param parentAlive (() -> boolean)? - 父粒子仍存活谓词
	@param emitCtx table? - 可选发射上下文；字段同 walk
	@param inheritedScale table? - 祖先 scale 链节点（含 Graph/Seed/StartTime 等）；nil 则走 walk
	@param pData table - 父粒子运行时表；写入 _scaleMapKeys = { Instance, ... }
]]
function NestedEmit.walkWithScale(particle, sourceRT, clonedRoot, parentAlive, emitCtx, inheritedScale, pData)
	if not inheritedScale then
		NestedEmit.walk(particle, sourceRT, clonedRoot, parentAlive, emitCtx)
		return
	end
	particle._parentScaleMap = particle._parentScaleMap or {}
	local keys = {}
	NestedEmit.walk(particle, sourceRT, clonedRoot, parentAlive, emitCtx, function(node)
		particle._parentScaleMap[node] = inheritedScale
		keys[#keys + 1] = node
	end)
	pData._scaleMapKeys = keys
end

return NestedEmit
