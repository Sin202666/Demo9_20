--[[
	Module: Timescale
	Description: Mixin：运行时覆盖活粒子与原生 ParticleEmitter 的时间倍率
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- SetTimescale(item, scale, duration, permanent)
	    scale      - 0=停时，<0=反向，>0=倍率
	    duration   - 恢复前秒数（permanent 时忽略）
	    permanent  - true 永不过期；false+duration=0 收成 ClearTimescale
	- ClearTimescale / AbsoluteSetTimescale / AbsoluteClearTimescale（递归，对齐 AbsoluteEnable）
	- _seedTsOverride：发射时把源节点 Attribute 拷到新 pData

	模块关系：
	- Transformed：写 `_tsOverride` + `_tsOverrideUntil`；走 _activeEmits；Update mixin 用 currentTime < _tsOverrideUntil
	- 原生 ParticleEmitter：直接写 .TimeScale；原值藏 `_origTimeScale`；`_tsGen` 作废过期 task.delay
	- 不写权威伤害/掉落

	加载方式：
		require(script.Parent.Timescale)(Particle)

	使用示例：
		Particle:SetTimescale(item, 0.5, 2, false)
		Particle:AbsoluteClearTimescale(root)
]]

return function(Particle)

	--[[
		发射点播种。源上过期 Attribute 无害：Update mixin 门闩会惰性过期。

		@param pData table - 新粒子运行时；写入 _tsOverride / _tsOverrideUntil
		@param src Instance? - 源节点；nil 早退
	]]
	function Particle._seedTsOverride(pData, src)
		if not src then return end
		pData._tsOverride = src:GetAttribute("_tsOverride")
		pData._tsOverrideUntil = src:GetAttribute("_tsOverrideUntil")
	end

	--[[
		原生 ParticleEmitter 路径：首次藏原值、写覆盖、按代调度恢复。

		@param pe ParticleEmitter - 原生发射器
		@param scale number - TimeScale 覆盖值
		@param duration number? - 恢复延迟秒；permanent 时忽略
		@param permanent boolean? - true 不调度恢复
	]]
	local function _setNativePE(pe, scale, duration, permanent)
		if pe:GetAttribute("_origTimeScale") == nil then
			pcall(function() pe:SetAttribute("_origTimeScale", pe.TimeScale) end)
		end
		pcall(function() pe.TimeScale = scale end)
		-- Generation token: bump invalidates any pending stale restore closure.
		local gen = (pe:GetAttribute("_tsGen") or 0) + 1
		pcall(function() pe:SetAttribute("_tsGen", gen) end)
		if permanent == true then return end
		task.delay(duration, function()
			if not pe.Parent then return end
			if pe:GetAttribute("_tsGen") ~= gen then return end
			local orig = pe:GetAttribute("_origTimeScale")
			if orig ~= nil then
				pcall(function() pe.TimeScale = orig end)
				pcall(function() pe:SetAttribute("_origTimeScale", nil) end)
			end
			pcall(function() pe:SetAttribute("_tsGen", nil) end)
		end)
	end

	--[[
		清掉原生 ParticleEmitter 的覆盖，恢复 `_origTimeScale`，并抬代作废未执行的 delay。

		@param pe ParticleEmitter - 原生发射器
	]]
	local function _clearNativePE(pe)
		local orig = pe:GetAttribute("_origTimeScale")
		if orig ~= nil then
			pcall(function() pe.TimeScale = orig end)
			pcall(function() pe:SetAttribute("_origTimeScale", nil) end)
		end
		-- Bump + clear gen so any pending task.delay closure from a prior timed call bails.
		local gen = (pe:GetAttribute("_tsGen") or 0) + 1
		pcall(function() pe:SetAttribute("_tsGen", gen) end)
		pcall(function() pe:SetAttribute("_tsGen", nil) end)
	end

	--[[
		对 Transformed 节点或原生 ParticleEmitter 施加时间覆盖。语义见文件头。

		@param item Instance? - 目标；nil 早退
		@param scale number - 倍率；非 number 早退
		@param duration number? - 持续秒；permanent 或无效时见文件头
		@param permanent boolean? - true 永不过期
	]]
	function Particle:SetTimescale(item, scale, duration, permanent)
		if not item then return end
		if typeof(scale) ~= "number" then return end
		local effectiveDuration
		if permanent == true then
			effectiveDuration = nil
		elseif typeof(duration) == "number" and duration > 0 then
			effectiveDuration = duration
		else
			self:ClearTimescale(item)
			return
		end
		if item:IsA("ParticleEmitter") then
			_setNativePE(item, scale, effectiveDuration, permanent)
			return
		end
		local until_ = (permanent == true) and math.huge or (os.clock() + effectiveDuration)
		pcall(function()
			item:SetAttribute("_tsOverride", scale)
			item:SetAttribute("_tsOverrideUntil", until_)
		end)
		local active = self._activeEmits
		for i = 1, #active do
			local pData = active[i]
			if pData and pData._sourceItem == item then
				pData._tsOverride = scale
				pData._tsOverrideUntil = until_
			end
		end
	end

	--[[
		去掉 Transformed 或原生 PE 上的时间覆盖。Transformed 回到 Graphs.Timescale，原生回到 `_origTimeScale`。

		@param item Instance? - 目标；nil 早退
	]]
	function Particle:ClearTimescale(item)
		if not item then return end
		if item:IsA("ParticleEmitter") then
			_clearNativePE(item)
			return
		end
		pcall(function()
			item:SetAttribute("_tsOverride", nil)
			item:SetAttribute("_tsOverrideUntil", nil)
		end)
		local active = self._activeEmits
		for i = 1, #active do
			local pData = active[i]
			if pData and pData._sourceItem == item then
				pData._tsOverride = nil
				pData._tsOverrideUntil = nil
			end
		end
	end

	--[[
		递归 SetTimescale，对齐 AbsoluteEnable。Transformed 与原生 PE 都是终端。
		BasePart 下未 Transformed 的 BasePart 子级跳过（与 AbsoluteEnable 相同剪枝）。

		@param item Instance? - 树根
		@param scale number - 倍率
		@param duration number? - 持续秒
		@param permanent boolean? - 是否永久
	]]
	function Particle:AbsoluteSetTimescale(item, scale, duration, permanent)
		if not item then return end
		if item:GetAttribute("Transformed") then
			self:SetTimescale(item, scale, duration, permanent)
			return
		end
		if item:IsA("ParticleEmitter") then
			self:SetTimescale(item, scale, duration, permanent)
			return
		end
		for _, child in item:GetChildren() do
			if item:IsA("BasePart") and child:IsA("BasePart") and not child:GetAttribute("Transformed") then
				continue
			end
			self:AbsoluteSetTimescale(child, scale, duration, permanent)
		end
	end

	--[[
		递归 ClearTimescale，覆盖 item 及其 Transformed 后代。

		@param item Instance? - 树根
	]]
	function Particle:AbsoluteClearTimescale(item)
		if not item then return end
		if item:GetAttribute("Transformed") then
			self:ClearTimescale(item)
			return
		end
		if item:IsA("ParticleEmitter") then
			self:ClearTimescale(item)
			return
		end
		for _, child in item:GetChildren() do
			if item:IsA("BasePart") and child:IsA("BasePart") and not child:GetAttribute("Transformed") then
				continue
			end
			self:AbsoluteClearTimescale(child)
		end
	end

end
