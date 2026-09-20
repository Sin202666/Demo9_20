--[[
	Module: FXUtil/PhasedVfxTree
	Description: 整棵特效树挂锚点 + 分阶段 Enable/Emit/Trail 开关 + 统一 Teardown（通用 FX 原语）
	Author: 中台组
	Created: 2026-08-03
	Last Modified: 2026-08-03

	泛用：任意「整树挂载 + cueMap 驱动」的技能/表现均可复用；不内置具体技能 cue 名。
	访问：Utils.FXUtil.MountPhasedVfxTree（不占 Utils 顶层键）。

	示例：
		local handle = FXUtil.MountPhasedVfxTree(template, {
			anchorCF = releaseCF,
			parent = workspace,
			cueMap = {
				Absorb = { { path = "2空中爆发/2_1起跳吸收", op = "EmitBurst" } },
				TrailOn = { { op = "TrailEnable" } },
			},
		})
		handle.FireCue("Absorb")
		handle.SetTrailWindow(true)
		handle.Teardown()
]]

return function(FXUtil)

export type PhasedVfxOp = {
	-- 相对 root 的路径，"/" 分隔；空则作用于整树
	path: string?,
	-- 在 path 解析结果下再 FindFirstChild(instanceName)
	instanceName: string?,
	-- Enable/Disable=整树 PE/Trail/Beam；EmitBurst=名字含 emit 爆发；
	-- EmitDescendants=Emit_Particles_GetDescendants；TrailEnable/TrailDisable=仅 Trail；
	-- EnableNameVfx/OffEnableVfx=名字含 enable 的可持续层
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

type _Internal = {
	root: Instance,
	cueMap: { [string]: { PhasedVfxOp } },
	weld: WeldConstraint?,
	usePool: boolean,
	alive: boolean,
}

--[[
	按 "/" 路径解析子实例
	@param root Instance - 树根
	@param path string? - 相对路径
	@return Instance? - 解析结果
]]
local function _resolvePath(root: Instance, path: string?): Instance?
	if not path or path == "" then
		return root
	end
	local cur: Instance? = root
	for segment in string.gmatch(path, "[^/]+") do
		if not cur then
			return nil
		end
		cur = cur:FindFirstChild(segment)
	end
	return cur
end

--[[
	解析 Op 目标实例
	@param root Instance - 树根
	@param op PhasedVfxOp - 单条操作
	@return Instance? - 目标
]]
local function _resolveTarget(root: Instance, op: PhasedVfxOp): Instance?
	local base = _resolvePath(root, op.path)
	if not base then
		return nil
	end
	if op.instanceName and op.instanceName ~= "" then
		return base:FindFirstChild(op.instanceName, true)
	end
	return base
end

--[[
	对目标执行单条 Op
	@param root Instance - 树根（部分 op 需要）
	@param op PhasedVfxOp - 操作
]]
local function _applyOp(root: Instance, op: PhasedVfxOp)
	local target = _resolveTarget(root, op) or root
	local name = op.op
	if name == "Enable" then
		FXUtil.SetEmittersTrailsBeamsEnabled(target, true)
	elseif name == "Disable" then
		FXUtil.SetEmittersTrailsBeamsEnabled(target, false)
	elseif name == "EmitBurst" then
		FXUtil.EmitBurstEmitInName(target, true)
	elseif name == "EmitDescendants" then
		if target:IsA("ParticleEmitter") then
			FXUtil.Emit_Particles_GetDescendants(target :: any, true)
		else
			-- Folder / Model / BasePart：对整棵子树爆发（1蓄力 下多个特效）
			FXUtil.Emit_Particles_GetDescendants(target :: any, true)
		end
	elseif name == "EmitOnceThenEnable" then
		FXUtil.EmitOnceThenEnableContinuous(target)
	elseif name == "TrailEnable" or name == "TrailDisable" then
		local enabled = name == "TrailEnable"
		if target:IsA("Trail") then
			target.Enabled = enabled
		end
		for _, d in target:GetDescendants() do
			if d:IsA("Trail") then
				d.Enabled = enabled
			end
		end
	elseif name == "EnableNameVfx" then
		FXUtil.SetEnableNameVfx(target, true)
	elseif name == "OffEnableVfx" then
		FXUtil.OffEnableVfx(target)
	end
end

--[[
	将模型/部件对齐到锚点，并可选焊接到 attachPart
	@param root Instance - 特效根
	@param anchorCF CFrame? - 世界锚点
	@param attachPart BasePart? - 跟随焊接目标
	@return WeldConstraint? - 若创建了焊接则返回
]]
local function _mountTransform(root: Instance, anchorCF: CFrame?, attachPart: BasePart?): WeldConstraint?
	local cf = anchorCF
	if not cf and attachPart then
		cf = attachPart.CFrame
	end
	if cf then
		if root:IsA("Model") then
			(root :: Model):PivotTo(cf)
		elseif root:IsA("BasePart") then
			(root :: BasePart).CFrame = cf
		end
	end

	if not attachPart then
		return nil
	end

	local primary: BasePart? = nil
	if root:IsA("Model") then
		primary = (root :: Model).PrimaryPart
		if not primary then
			for _, d in root:GetDescendants() do
				if d:IsA("BasePart") then
					primary = d
					break
				end
			end
		end
	elseif root:IsA("BasePart") then
		primary = root
	end
	if not primary then
		return nil
	end

	primary.Anchored = false
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = attachPart
	weld.Part1 = primary
	weld.Parent = primary
	return weld
end

--[[
	挂载整棵特效树到锚点，并绑定分阶段 cueMap
	@param source Instance - 模板或已克隆实例
	@param opts PhasedVfxMountOpts - 锚点/父级/cueMap/是否 Clone/是否对象池
	@return PhasedVfxHandle? - 句柄；source 非法时 nil
]]
function FXUtil.MountPhasedVfxTree(source: Instance, opts: PhasedVfxMountOpts?): PhasedVfxHandle?
	if not source then
		return nil
	end
	opts = opts or {}

	local usePool = opts.usePool == true
	local shouldClone = if opts.clone ~= nil then opts.clone else true
	local root: Instance? = nil

	if usePool and source:IsA("Model") then
		root = FXUtil.GetInstance_From_Pool(source)
	elseif shouldClone then
		root = source:Clone()
	else
		root = source
	end
	if not root then
		return nil
	end

	-- 初始全关，避免未到 cue 就冒烟
	FXUtil.SetEmittersTrailsBeamsEnabled(root, false)
	FXUtil.OffEnableVfx(root)

	local parent = opts.parent or workspace
	root.Parent = parent
	local weld = _mountTransform(root, opts.anchorCF, opts.attachPart)

	local internal: _Internal = {
		root = root,
		cueMap = opts.cueMap or {},
		weld = weld,
		usePool = usePool,
		alive = true,
	}

	local handle: PhasedVfxHandle
	handle = {
		root = root,
		FireCue = function(cueName: string): boolean
			if not internal.alive then
				return false
			end
			local ops = internal.cueMap[cueName]
			if not ops then
				return false
			end
			for _, op in ops do
				_applyOp(internal.root, op)
			end
			return true
		end,
		ApplyOps = function(ops: { PhasedVfxOp })
			if not internal.alive then
				return
			end
			for _, op in ops do
				_applyOp(internal.root, op)
			end
		end,
		SetTrailWindow = function(enabled: boolean)
			if not internal.alive then
				return
			end
			_applyOp(internal.root, { op = if enabled then "TrailEnable" else "TrailDisable" })
		end,
		Teardown = function(delaySec: number?)
			if not internal.alive then
				return
			end
			internal.alive = false
			local function cleanup()
				if internal.weld then
					internal.weld:Destroy()
					internal.weld = nil
				end
				if internal.root.Parent then
					FXUtil.OffEnableVfx(internal.root)
					FXUtil.SetEmittersTrailsBeamsEnabled(internal.root, false)
					if internal.root:IsA("Model") then
						FXUtil.Stop_All_Emit(internal.root)
					end
					if internal.usePool and internal.root:IsA("Model") then
						FXUtil.BackPool_Instance(internal.root)
					else
						internal.root:Destroy()
					end
				end
			end
			local waitSec = delaySec or 0
			if waitSec > 0 then
				task.delay(waitSec, cleanup)
			else
				cleanup()
			end
		end,
	}

	return handle
end

end
