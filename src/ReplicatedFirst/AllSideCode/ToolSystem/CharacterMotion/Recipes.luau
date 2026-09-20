--[[
	Module: CharacterMotion.Recipes
	Description: 能力位移共享配方（客户端驱动 + 服包络同源 maxDistance）
	Author: 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-08-31

	maxDistance 估算：
	  有 speedKeys：分段梯形积分 avgFactor * planeSpeed * tweenDuration
	  无 keys：avgSpeed = planeSpeed * (1 + vectorEndFactor) / 2
	服侧再乘 ENVELOPE_SLACK，勿信客户端上报距离。

	NewRoll 长冲契约：
	  Forward Travel=0.4s / planeSpeed=80 / endFactor=0.12；
	  侧后 0.4|0.7s；collisionPolicy=SlideAlong；clearImpulsesOnBegin=true。
	客户端 maxDistance 硬封顶需 recipe.enforceMaxDistance=true；服包络仍用 maxDistance。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Copy = Utils.Copy

local Recipes = {}

--[[
	无 speedKeys 时按起止倍率梯形估算水平路程
	@param planeSpeed number - 峰值平面速
	@param tweenDuration number - 曲线时长（秒）
	@param vectorEndFactor number - 末速相对峰值倍率
	@return number - 估距（stud）
]]
local function _estimateMaxDist(planeSpeed: number, tweenDuration: number, vectorEndFactor: number): number
	local endF = if type(vectorEndFactor) == "number" then vectorEndFactor else 0
	local avg = planeSpeed * (1 + endF) * 0.5
	return avg * tweenDuration
end

--[[
	按 speedKeys 分段梯形积分估水平路程
	@param planeSpeed number - 峰值平面速
	@param tweenDuration number - 曲线时长
	@param speedKeys { { t: number, factor: number } }? - 已排序或未排序均可
	@param endFactorFallback number? - 无 keys 时回退
	@return number - 估距 stud
]]
local function _estimateMaxDistFromKeys(
	planeSpeed: number,
	tweenDuration: number,
	speedKeys: { { t: number, factor: number } }?,
	endFactorFallback: number?
): number
	if type(speedKeys) ~= "table" or #speedKeys == 0 then
		return _estimateMaxDist(planeSpeed, tweenDuration, endFactorFallback or 0)
	end
	local keys = table.clone(speedKeys)
	table.sort(keys, function(a, b)
		return a.t < b.t
	end)
	local integral = 0
	for i = 1, #keys - 1 do
		local a = keys[i]
		local b = keys[i + 1]
		local dt = b.t - a.t
		if dt > 0 then
			integral += (a.factor + b.factor) * 0.5 * dt
		end
	end
	if #keys == 1 then
		integral = keys[1].factor
	end
	return planeSpeed * integral * tweenDuration
end

--[[
	构造默认侧向/前后配方骨架（SlideAlong，不硬截断 maxDistance）
	@param planeSpeed number - 峰值平面速
	@param tweenDuration number - 曲线时长（秒）
	@param vectorEndFactor number - 末速相对峰值倍率
	@return table - PlanarRecipe 字段表
]]
local function _dir(planeSpeed: number, tweenDuration: number, vectorEndFactor: number)
	return {
		planeSpeed = planeSpeed,
		tweenDuration = tweenDuration,
		vectorEndFactor = vectorEndFactor,
		maxDistance = _estimateMaxDist(planeSpeed, tweenDuration, vectorEndFactor),
		verticalMode = "PreserveY",
		collisionPolicy = "SlideAlong",
		clearImpulsesOnBegin = true,
		enforceMaxDistance = false,
	}
end

--[[
	长冲 speedKeys：高开 → 略持 → 收到 endFactor
	@param endFactor number - 与 vectorEndFactor 对齐的尾倍率
	@return { { t: number, factor: number } } - 归一化速度关键帧（t∈[0,1]）
]]
local function _dashSpeedKeys(endFactor: number): { { t: number, factor: number } }
	return {
		{ t = 0, factor = 1 },
		{ t = 0.35, factor = 0.92 },
		{ t = 0.65, factor = 0.55 },
		{ t = 1, factor = endFactor },
	}
end

--[[
	侧后简化 keys（3 点）
	@param endFactor number - 与 vectorEndFactor 对齐的尾倍率
	@return { { t: number, factor: number } } - 归一化速度关键帧
]]
local function _shortSideSpeedKeys(endFactor: number): { { t: number, factor: number } }
	return {
		{ t = 0, factor = 1 },
		{ t = 0.5, factor = 0.45 },
		{ t = 1, factor = endFactor },
	}
end

--[[
	写入 speedKeys 并用积分刷新 maxDistance
	@param r table - PlanarRecipe 字段表（就地改 speedKeys / maxDistance）
	@param keys { { t: number, factor: number } } - 归一化速度关键帧
]]
local function _applySpeedKeys(r: any, keys: { { t: number, factor: number } })
	r.speedKeys = keys
	r.maxDistance = _estimateMaxDistFromKeys(r.planeSpeed, r.tweenDuration, keys, r.vectorEndFactor)
end

--[[
	冻结单条配方及其 speedKeys，防止调用方改坏共享表
	@param r table - PlanarRecipe 字段表
	@return table - 已 freeze 的同一张表
]]
local function _freezeRecipe(r: any)
	if type(r.speedKeys) == "table" then
		r.speedKeys = table.freeze(r.speedKeys)
	end
	return table.freeze(r)
end

Recipes.NewRoll = table.freeze({
	Forward = (function()
		local r = _dir(80, 0.4, 0.12)
		_applySpeedKeys(r, _dashSpeedKeys(0.12))
		return _freezeRecipe(r)
	end)(),
	Backward = (function()
		local r = _dir(65, 0.4, 0.05)
		_applySpeedKeys(r, _shortSideSpeedKeys(0.05))
		return _freezeRecipe(r)
	end)(),
	Left = (function()
		local r = _dir(70, 0.45, 0.05)
		_applySpeedKeys(r, _shortSideSpeedKeys(0.05))
		return _freezeRecipe(r)
	end)(),
	Right = (function()
		local r = _dir(70, 0.45, 0.05)
		_applySpeedKeys(r, _shortSideSpeedKeys(0.05))
		return _freezeRecipe(r)
	end)(),
})

--[[
	取配方深拷贝字段表（避免调用方改坏共享表）
	@param skillKey string - 如 "NewRoll"
	@param direction string - Forward|Backward|Left|Right
	@return table? - PlanarRecipe 深拷贝（planeSpeed / tweenDuration / speedKeys 等）；缺失为 nil
]]
function Recipes.Get(skillKey: string, direction: string): any?
	local pack = Recipes[skillKey]
	if type(pack) ~= "table" then
		return nil
	end
	local src = pack[direction] or pack.Forward
	if type(src) ~= "table" then
		return nil
	end
	-- 深拷贝，避免调用方改坏共享 speedKeys 等嵌套表
	return Copy.deepCopy(src)
end

--[[
	服包络用：该技能各向 maxDistance 的最大值（方向不可信时兜底）
	@param skillKey string - 如 "NewRoll"
	@return number - 最大水平位移估算；无配方时 0
]]
function Recipes.GetMaxDistanceCap(skillKey: string): number
	local pack = Recipes[skillKey]
	if type(pack) ~= "table" then
		return 0
	end
	local best = 0
	for _, cfg in pairs(pack) do
		if type(cfg) == "table" and type(cfg.maxDistance) == "number" then
			best = math.max(best, cfg.maxDistance)
		end
	end
	return best
end

return table.freeze(Recipes)
