--[[
	Module: PartIcles.LinkService
	Description: 独立 CFrame 追踪：把 BasePart/Model/Attachment 按 LinkMode 钉到目标
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- Activate / Deactivate：启停每帧追踪循环
	- Link / Clear / IsLinked：绑定、解除、查询
	- 与粒子运行时同一套 LinkMode 分发，但不发射粒子

	mode: "Weld" | "Follow" | "Pivot" | "WeldWithoutRotation"（未知回退 Weld）
	duration: 可选秒数；nil 表示直到 Clear。目标或 part1 销毁、到期会自动清。
	Link 时快照 Anchored 并强制 true，避免物理与每帧写 CFrame 打架；Clear/到期还原。

	客户端用 PreRender（与 Lifecycle LOOP_YIELD_EVENT 一致）；服务端用 Heartbeat。

	加载：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local LinkService = require(...) -- 由 PartIcles 导出或内部 require
		LinkService:Activate()
		LinkService:Link(part1, target, "Weld", 2)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService
local Log = Utils.Log
local Constants = require(script.Parent.PartConstants)

-- Resume in PreRender on client (after physics + attachment-transform propagation
-- complete; matches the Lifecycle.luau LOOP_YIELD_EVENT choice). Heartbeat on server
-- since PreRender is client-only.
local TICK_EVENT = RunService:IsClient() and RunService.PreRender or RunService.Heartbeat

local LinkService = {}

LinkService._active = false
LinkService._connection = nil
LinkService._links = {}
LinkService._anchorSnapshot = {}
LinkService._warnedNotActive = false

local VALID_MODES = {
	Weld = true,
	Follow = true,
	Pivot = true,
	WeldWithoutRotation = true,
}

--[[
	读取 part1 当前世界 CFrame。
	@param part1 BasePart | Model | Attachment - 被钉物体
	@return CFrame - Model 用 GetPivot；Attachment 用 WorldCFrame；其余用 CFrame
]]
local function _readPart1CF(part1)
	if part1:IsA("Model") then
		local ok, cf = pcall(part1.GetPivot, part1)
		if ok and cf then return cf end
		return CFrame.new()
	end
	if part1:IsA("Attachment") then return part1.WorldCFrame end
	return part1.CFrame
end

--[[
	分类 part1，供 _tick 选择写入口。
	@param part1 Instance - 被钉物体
	@return string - "Model" | "Attachment" | "Part"
]]
local function _classifyPart1(part1)
	if part1:IsA("Model") then return "Model" end
	if part1:IsA("Attachment") then return "Attachment" end
	return "Part"
end

--[[
	快照原 Anchored 并强制 true。Attachment 无 Anchored 返回 nil。
	Model 返回 {[BasePart]=prior}，避免 PivotTo 只推 PrimaryPart 时其余件自由落体。
	@param part1 BasePart | Model | Attachment - 被钉物体
	@return boolean | table | nil - BasePart 为 bool；Model 为 {[BasePart]=boolean}；Attachment 为 nil
]]
function LinkService:_captureAndAnchor(part1)
	if part1:IsA("BasePart") then
		local prior = part1.Anchored
		part1.Anchored = true
		return prior
	end
	if part1:IsA("Model") then
		local snapshot = {}
		for _, desc in ipairs(part1:GetDescendants()) do
			if desc:IsA("BasePart") then
				snapshot[desc] = desc.Anchored
				desc.Anchored = true
			end
		end
		return snapshot
	end
	return nil
end

--[[
	按 Link 时快照还原 Anchored。
	@param part1 Instance - 被钉物体
	@return () - 无返回值
]]
function LinkService:_restoreAnchor(part1)
	local prior = self._anchorSnapshot[part1]
	self._anchorSnapshot[part1] = nil
	if prior == nil then return end
	if part1:IsA("BasePart") and part1.Parent then
		part1.Anchored = prior
		return
	end
	if part1:IsA("Model") and type(prior) == "table" then
		for desc, priorAnchored in pairs(prior) do
			if desc.Parent then desc.Anchored = priorAnchored end
		end
	end
end

--[[
	启动每帧追踪循环。幂等。
	@return () - 无返回值
]]
function LinkService:Activate()
	if self._active then return end
	self._active = true
	self._connection = TICK_EVENT:Connect(function(dt)
		self:_tick(dt)
	end)
end

--[[
	停止追踪并清空全部链接，还原各 part1 的 Anchored。
	@return () - 无返回值
]]
function LinkService:Deactivate()
	if not self._active then return end
	self._active = false
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
	for part1 in pairs(self._links) do
		self._links[part1] = nil
		self:_restoreAnchor(part1)
	end
end

--[[
	每帧把 part1 的 CFrame 按 mode 钉到 target。duration 到期自动 Clear；nil 直到 Clear。
	@param part1 BasePart | Model | Attachment - 被钉物体
	@param target Instance - BasePart / Model / Attachment / Bone / Camera
	@param mode string - Weld / Follow / Pivot / WeldWithoutRotation；非法回退 Weld
	@param duration number? - 秒；nil 表示无限
	@return () - 无返回值
]]
function LinkService:Link(part1, target, mode, duration)
	if not part1 or not target then return end
	if part1 == target then return end
	if not (part1:IsA("BasePart") or part1:IsA("Model") or part1:IsA("Attachment")) then return end
	if not part1.Parent or not target.Parent then return end
	if not VALID_MODES[mode] then mode = "Weld" end
	if not self._active and not self._warnedNotActive then
		self._warnedNotActive = true
		Log.warn("[Part-Icles LinkService] Link called before Activate(); the link won't update until you call LinkService:Activate(). This warning fires once.")
	end

	local targetCF = Constants.resolveLinkCFrame(target)
	local part1CF = _readPart1CF(part1)

	-- Snapshot Anchored on first Link only; re-Link of same part1 keeps the original
	-- prior-state so a Clear after multiple Links restores the truly-authored value.
	if self._anchorSnapshot[part1] == nil and not self._links[part1] then
		self._anchorSnapshot[part1] = self:_captureAndAnchor(part1)
	else
		-- Re-arm anchor flag in case user toggled it between Link calls.
		self:_captureAndAnchor(part1)
	end

	self._links[part1] = {
		target = target,
		mode = mode,
		offsetCF = targetCF:ToObjectSpace(part1CF),
		rotation = part1CF.Rotation,
		expiresAt = duration and (os.clock() + duration) or nil,
		partKind = _classifyPart1(part1),
	}
end

--[[
	停止追踪 part1 并还原 Anchored。未链接则空操作。
	@param part1 Instance - 被钉物体
	@return () - 无返回值
]]
function LinkService:Clear(part1)
	if not self._links[part1] then return end
	self._links[part1] = nil
	self:_restoreAnchor(part1)
end

--[[
	查询 part1 是否有活动链接。
	@param part1 Instance - 被钉物体
	@return boolean - 有活动条目为 true
]]
function LinkService:IsLinked(part1)
	return self._links[part1] ~= nil
end

--[[
	每帧推进：到期/销毁则 Clear，否则按 mode 写 CFrame / PivotTo。
	@param dt number - 帧间隔（本实现未用于积分，仅签名对齐）
	@return () - 无返回值
]]
function LinkService:_tick(dt)
	local now = os.clock()
	for part1, entry in pairs(self._links) do
		if not part1.Parent or not entry.target.Parent then
			self:Clear(part1)
		elseif entry.expiresAt and now >= entry.expiresAt then
			self:Clear(part1)
		else
			local targetCF = Constants.resolveLinkCFrame(entry.target)
			local newCF
			if entry.mode == "Weld" then
				newCF = targetCF * entry.offsetCF
			else
				-- Follow / Pivot / WeldWithoutRotation: position tracks the linked offset,
				-- rotation stays at the authored snapshot. WWR's mesh-frame variant from
				-- the particle pipeline doesn't apply outside emit; v1 treats it as Follow.
				newCF = CFrame.new((targetCF * entry.offsetCF).Position) * entry.rotation
			end
			if entry.partKind == "Model" then
				pcall(function() part1:PivotTo(newCF) end)
			elseif entry.partKind == "Attachment" then
				local parent = part1.Parent
				if parent and parent:IsA("BasePart") then
					part1.CFrame = parent.CFrame:ToObjectSpace(newCF)
				end
			else
				part1.CFrame = newCF
			end
		end
	end
end

return LinkService
