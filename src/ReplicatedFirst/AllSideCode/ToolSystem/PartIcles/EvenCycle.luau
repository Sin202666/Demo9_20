--[[
	Module: EvenCycle
	Description: Rate 模式下 EvenDistribution 的滚动周期数学（位置 / 旋转）
	Author: 林奥宇
	Created: 2024-01-01
	Last Modified: 2026-09-01

	功能：
	- resolve / isSet：从 NumberRange 属性采样有符号周期长度 N
	- step / advance：每属性前进一步；wrap 时重采样
	- evenFlags：读 PartIcleProperties 上 Pos/Rot Even 开关
	- clear / ensureIds：停发清槽；给旧存档补 _EvenCycleId

	模块关系：
	- N 的符号决定方向：正=正向 idx 走 1..|N|，负=反向 |N|..1；0 或默认零区间回退 cfg.Rate（正向）
	- store 按稳定 emitter id 分槽，离散 burst 与嵌套再发射共用同一周期
	- Lifecycle 在停发时 clear；Transform 新变换时打 id，ensureIds 只补历史存档

	加载方式：
		local EvenCycle = require(script.Parent.EvenCycle)

	使用示例：
		EvenCycle.ensureIds(item)
		local posIdx, posAbs, rotIdx, rotAbs = EvenCycle.advance(store, key, config, rate, hasPos, hasRot)
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local HttpService = Utils.HttpService

local EvenCycle = {}

--[[
	从 PartIcleProperties 上的 NumberRange 周期属性采样 N。保号取整。
	非 NumberRange 或 [0,0] 时回退 math.max(1, floor(fallbackRate or 12))。

	@param config Instance? - 带 Attribute 的 Configuration；nil 走回退
	@param attrName string - 属性名（PositionEvenCycle / RotationEvenCycle）
	@param fallbackRate number? - 回退速率；nil 视为 12
	@return number - 非零整数 N（可负）
]]
function EvenCycle.resolve(config, attrName, fallbackRate)
	local r = config and config:GetAttribute(attrName)
	if typeof(r) ~= "NumberRange" or (r.Min == 0 and r.Max == 0) then
		return math.max(1, math.floor(fallbackRate or 12))
	end
	local n = r.Min + (r.Max - r.Min) * math.random()
	n = math.floor(n + (n >= 0 and 0.5 or -0.5))
	if n == 0 then return math.max(1, math.floor(fallbackRate or 12)) end
	return n
end

--[[
	单属性周期前进一步。wrap 或首次（absN==0 或 idx==0）时重采样 signedN，
	并按方向把 idx 置 1（正向）或 |N|（反向）。

	@param idx number - 当前步（1-based）；0 表示未初始化
	@param signedN number - 当前有符号周期长度
	@param config Instance? - 周期属性所在 Configuration
	@param attrName string - 周期属性名
	@param fallbackRate number? - resolve 回退速率
	@return number - 步进后的 idx
	@return number - 可能重采样后的 signedN
	@return number - abs(signedN)
]]
function EvenCycle.step(idx, signedN, config, attrName, fallbackRate)
	local absN = math.abs(signedN)
	--[[
		重采样周期并按方向重置 idx。闭包写回外层 idx / signedN / absN。
	]]
	local function _reroll()
		signedN = EvenCycle.resolve(config, attrName, fallbackRate)
		absN = math.abs(signedN)
		if signedN > 0 then idx = 1 else idx = absN end
	end
	if absN == 0 or idx == 0 then
		_reroll()
	elseif signedN > 0 then
		idx = idx + 1
		if idx > absN then _reroll() end
	else
		idx = idx - 1
		if idx < 1 then _reroll() end
	end
	return idx, signedN, absN
end

--[[
	读 Position / Rotation EvenDistribution 是否打开（PartIcleProperties 标志）。

	@param config Instance? - PartIcleProperties；nil 返回 false, false
	@return boolean - 任一 PosX/Y/ZEven 为 true
	@return boolean - 任一 RotX/Y/ZEven 为 true
]]
function EvenCycle.evenFlags(config)
	if not config then return false, false end
	local hasPos = (config:GetAttribute("PosXEven") or config:GetAttribute("PosYEven") or config:GetAttribute("PosZEven")) == true
	local hasRot = (config:GetAttribute("RotXEven") or config:GetAttribute("RotYEven") or config:GetAttribute("RotZEven")) == true
	return hasPos, hasRot
end

--[[
	按发射器稳定 id 持久步进。store[key] = {posIdx, posSignedN, rotIdx, rotSignedN}。
	仅当对应 Even 打开且周期属性显式设置时才滚动 offset。首发分配槽，稳态原地复用（热循环零分配）。

	@param store table - { [any]: {number, number, number, number} } 发射器 id → 四元组槽
	@param key any - 稳定发射器 id（通常 _EvenCycleId 字符串）
	@param config Instance? - PartIcleProperties
	@param currentRate number - 当前 Rate，作 resolve 回退
	@param hasPosEven boolean - 位置 Even 是否打开
	@param hasRotEven boolean - 旋转 Even 是否打开
	@return number - 位置 idx（未滚则为 0）
	@return number - 位置 |N|
	@return number - 旋转 idx
	@return number - 旋转 |N|
]]
function EvenCycle.advance(store, key, config, currentRate, hasPosEven, hasRotEven)
	local slot = store[key]
	if not slot then
		slot = { 0, 0, 0, 0 }
		store[key] = slot
	end
	local posIdx, posAbs, rotIdx, rotAbs = 0, 0, 0, 0
	-- Only roll (offset) when the cycle is EXPLICITLY set; unset = plain even spread.
	if hasPosEven and EvenCycle.isSet(config, "PositionEvenCycle") then
		slot[1], slot[2], posAbs = EvenCycle.step(slot[1], slot[2], config, "PositionEvenCycle", currentRate)
		posIdx = slot[1]
	end
	if hasRotEven and EvenCycle.isSet(config, "RotationEvenCycle") then
		slot[3], slot[4], rotAbs = EvenCycle.step(slot[3], slot[4], config, "RotationEvenCycle", currentRate)
		rotIdx = slot[3]
	end
	return posIdx, posAbs, rotIdx, rotAbs
end

--[[
	周期 NumberRange 属性是否存在且非零（用户显式设置过）。

	@param config Instance? - 带 Attribute 的实例
	@param attrName string - 属性名
	@return boolean - 是 NumberRange 且 Min/Max 不全为 0
]]
function EvenCycle.isSet(config, attrName)
	local r = config and config:GetAttribute(attrName)
	return typeof(r) == "NumberRange" and not (r.Min == 0 and r.Max == 0)
end

--[[
	丢掉某 key 的周期状态，下次发射从 idx 1 重来。完整停发时调用。

	@param store table? - advance 使用的槽表；nil 则无操作
	@param key any - 要清除的发射器 id；nil 则无操作
]]
function EvenCycle.clear(store, key)
	if store and key ~= nil then
		store[key] = nil
	end
end

--[[
	为 id 出现前就变换过的发射器补打 `_EvenCycleId`：源 item + RenderTemplate 下
	所有 Transformed 后代（嵌套发射器被 clone 后继承同一 id）。已盖印则 no-op。
	新变换在 Transform 时打 id；本函数只补历史存档。

	@param item Instance - 源发射器节点
]]
function EvenCycle.ensureIds(item)
	if item:GetAttribute("_EvenCycleId") then return end
	pcall(function() item:SetAttribute("_EvenCycleId", HttpService:GenerateGUID(false)) end)
	local rt = item:FindFirstChild("RenderTemplate")
	if not rt then return end
	for _, desc in ipairs(rt:GetDescendants()) do
		if desc:GetAttribute("Transformed") and not desc:GetAttribute("_EvenCycleId") then
			pcall(function() desc:SetAttribute("_EvenCycleId", HttpService:GenerateGUID(false)) end)
		end
	end
end

return EvenCycle
