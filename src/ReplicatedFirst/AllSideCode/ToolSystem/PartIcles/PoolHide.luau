--[[
	Module: PoolHide
	Description: 池化视觉件的按类型隐藏 / 显示（不恢复渲染属性，由调用方 emit-setup 重写）
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- hide：Part/Model 先关 Trail 再传送到远处；Beam/PointLight 等 Enabled=false；Attachment no-op
	- show：对称翻回 Enabled/Visible；Trail 须等调用方写完新 CFrame 后再 restoreTrails
	- restoreTrails：从快照恢复 Trail.Enabled / Lifetime

	模块关系：
	- 仅被 Pool 调用。hide 不恢复 Size/CFrame/Color/Transparency（acquire 后由 emit 重写）
	- Trail 必须在传送前 disable，否则旧段在传送前后 Attachment 之间拉出可见拖尾
	- cancelNativeDescendants 抬代使 Particles.EnableEmit 的延迟闭包失效

	加载方式：
		local PoolHide = require(script.Parent.PoolHide)

	使用示例：
		PoolHide.hide(inst, "Part")
		PoolHide.show(inst, "Part")
		visual.CFrame = spawnCF
		PoolHide.restoreTrails(inst, "Part")
]]

local FAR_AWAY = Vector3.new(1e9, 1e9, 1e9)
local FAR_CFRAME = CFrame.new(FAR_AWAY)

local PoolHide = {}

--[[
	快照并关闭每个 Trail 后代；必须在传送前调用以免拖尾。
	同时把 Lifetime 置 0，让已有段立刻过期（Enabled=false 只停新段）。
	已有待处理快照则跳过，避免同帧 acquire→release 把作者值覆盖成瞬时 false。

	@param root Instance - 池化视觉根（Part / Model / Attachment / 单个 Trail）
]]
local function _disableTrails(root)
	if root:IsA("Trail") then
		pcall(function()
			if root:GetAttribute("_pooledTrailEnabled") == nil then
				root:SetAttribute("_pooledTrailEnabled", root.Enabled)
			end
			if root:GetAttribute("_pooledTrailLifetime") == nil then
				root:SetAttribute("_pooledTrailLifetime", root.Lifetime)
			end
			root.Lifetime = 0
			root.Enabled = false
		end)
		return
	end
	for _, desc in ipairs(root:GetDescendants()) do
		if desc:IsA("Trail") then
			pcall(function()
				if desc:GetAttribute("_pooledTrailEnabled") == nil then
					desc:SetAttribute("_pooledTrailEnabled", desc.Enabled)
				end
				if desc:GetAttribute("_pooledTrailLifetime") == nil then
					desc:SetAttribute("_pooledTrailLifetime", desc.Lifetime)
				end
				desc.Lifetime = 0
				desc.Enabled = false
			end)
		end
	end
end

--[[
	从快照恢复每个 Trail 的 Lifetime + Enabled，并清 Attribute 供下一轮。

	@param root Instance - 池化视觉根
]]
local function _restoreTrails(root)
	if root:IsA("Trail") then
		pcall(function()
			local priorLife = root:GetAttribute("_pooledTrailLifetime")
			if priorLife ~= nil then root.Lifetime = priorLife end
			root:SetAttribute("_pooledTrailLifetime", nil)
			local prior = root:GetAttribute("_pooledTrailEnabled")
			if prior ~= nil then root.Enabled = prior == true end
			root:SetAttribute("_pooledTrailEnabled", nil)
		end)
		return
	end
	for _, desc in ipairs(root:GetDescendants()) do
		if desc:IsA("Trail") then
			pcall(function()
				local priorLife = desc:GetAttribute("_pooledTrailLifetime")
				if priorLife ~= nil then desc.Lifetime = priorLife end
				desc:SetAttribute("_pooledTrailLifetime", nil)
				local prior = desc:GetAttribute("_pooledTrailEnabled")
				if prior ~= nil then desc.Enabled = prior == true end
				desc:SetAttribute("_pooledTrailEnabled", nil)
			end)
		end
	end
end

-- Bump cancel + duration gens + disable nested ParticleEmitter / Trail descendants.
-- Invalidates pending delayed starts + delayed-off closures from Particles.EnableEmit
-- so stale fires can't land on a reused pooled visual.
local CANCEL_GEN_ATTR = "_PartIcleNativeEmitGen"
local DURATION_GEN_ATTR = "_PartIcleNativeDurationGen"

--[[
	抬升嵌套 ParticleEmitter / Trail 的 cancel/duration 代，并 Enabled=false，
	使 EnableEmit 上未完成的延迟开关不会打到复用视觉上。

	@param root Instance - 池化视觉根
]]
local function _cancelNativeDescendants(root)
	for _, desc in ipairs(root:GetDescendants()) do
		if desc:IsA("ParticleEmitter") or desc:IsA("Trail") then
			pcall(function()
				local cancelCur = desc:GetAttribute(CANCEL_GEN_ATTR) or 0
				desc:SetAttribute(CANCEL_GEN_ATTR, cancelCur + 1)
				local durCur = desc:GetAttribute(DURATION_GEN_ATTR) or 0
				desc:SetAttribute(DURATION_GEN_ATTR, durCur + 1)
				desc.Enabled = false
			end)
		end
	end
end

--[[
	按 kind 隐藏池化实例。无 Parent 时早退。

	@param instance Instance? - 池化视觉件
	@param kind string - "Part" | "Model" | "Beam" | "PointLight" | "Highlight" | "TrailEmitter" | "ImageLabel" | "Attachment"
]]
function PoolHide.hide(instance, kind)
	if not instance or not instance.Parent then return end

	if kind == "Part" then
		-- disableTrails must run BEFORE cancelNativeDescendants so the snapshot reads
		-- the authored Trail.Enabled instead of the about-to-be-disabled value.
		_disableTrails(instance)
		_cancelNativeDescendants(instance)
		if instance:IsA("BasePart") then
			pcall(function() instance.CFrame = FAR_CFRAME end)
		end

	elseif kind == "Model" then
		_disableTrails(instance)
		_cancelNativeDescendants(instance)
		pcall(function() instance:PivotTo(FAR_CFRAME) end)

	elseif kind == "Beam" then
		-- Snapshot Color + Transparency before disable so reacquire with an empty colorStates
		-- graph restores authored values instead of inheriting the prior cycle's last frame.
		pcall(function()
			if instance:GetAttribute("_pooledBeamColor") == nil then
				instance:SetAttribute("_pooledBeamColor", instance.Color)
			end
			if instance:GetAttribute("_pooledBeamTransparency") == nil then
				instance:SetAttribute("_pooledBeamTransparency", instance.Transparency)
			end
			instance.Enabled = false
		end)

	elseif kind == "PointLight" then
		pcall(function() instance.Enabled = false end)

	elseif kind == "Highlight" then
		pcall(function() instance.Enabled = false end)

	elseif kind == "TrailEmitter" then
		pcall(function() instance.Enabled = false end)

	elseif kind == "ImageLabel" then
		-- ImageLabel has no .Enabled; .Visible=false is the equivalent hide. Pool.release
		-- re-parents to workspace.Terrain.Part_IclesPooled  -  Roblox tolerates GUI under
		-- non-ScreenGui ancestors (just doesn't render until reparented back).
		pcall(function() instance.Visible = false end)

	elseif kind == "Attachment" then
		-- Attachment stays at its real-world pose; cancel native PE/Trail
		-- descendants so stale delayed starts can't re-emit on the pooled
		-- attachment after the custom visual died. disableTrails runs first
		-- so its snapshot reads the authored Trail.Enabled instead of the
		-- about-to-be-disabled value (mirrors Part / Model branches).
		_disableTrails(instance)
		_cancelNativeDescendants(instance)
	-- Visible is intentionally untouched: toggling diverges pooled vs fresh
	-- (Visible defaults false on authored Attachments, exposing a 3D cross gizmo).
	end
end

--[[
	按 kind 显示池化实例。Trail 恢复推迟到 restoreTrails（须先写新 CFrame）。

	@param instance Instance? - 池化视觉件
	@param kind string - 与 hide 相同的 kind 枚举
]]
function PoolHide.show(instance, kind)
	if not instance or not instance.Parent then return end
	-- Symmetric with hide: Beam/PointLight/Highlight/TrailEmitter Enabled flip kept self-contained in the pool contract.
	if kind == "Beam" then
		-- Restore authored Color + Transparency from snapshot before re-enable. Emit setup only
		-- writes Color/Transparency when a graph is non-empty (Emit.luau:582-583); without this
		-- restore, pooled Beams reused with no graph keep prior-cycle final-frame values.
		pcall(function()
			local priorColor = instance:GetAttribute("_pooledBeamColor")
			if priorColor ~= nil then instance.Color = priorColor end
			instance:SetAttribute("_pooledBeamColor", nil)
			local priorTrans = instance:GetAttribute("_pooledBeamTransparency")
			if priorTrans ~= nil then instance.Transparency = priorTrans end
			instance:SetAttribute("_pooledBeamTransparency", nil)
			instance.Enabled = true
		end)
	elseif kind == "PointLight" or kind == "Highlight" or kind == "TrailEmitter" then
		pcall(function() instance.Enabled = true end)
	elseif kind == "ImageLabel" then
		pcall(function() instance.Visible = true end)
	end
	-- Trail restore deferred to PoolHide.restoreTrails (caller sets new CFrame first).
end

--[[
	在写入新出生 CFrame 之后调用，从快照恢复 Trail。新鲜 clone 无 `_pooledTrailEnabled` 时 no-op。

	@param instance Instance? - 池化视觉件
	@param kind string - 仅 "Part" / "Model" / "Attachment" 会恢复 Trail
]]
function PoolHide.restoreTrails(instance, kind)
	if not instance or not instance.Parent then return end
	if kind == "Part" or kind == "Model" or kind == "Attachment" then
		_restoreTrails(instance)
	end
end

return PoolHide
