--[[
	Module: FXUtil/SkillBuffDotVfx
	Description: DoT / 元素附着挂身 FX
	Author: LinAoyu
	Created: 2024-01-01
	Last Modified: 2026-07-02
]]

return function(FXUtil)

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

local VisibleMgr = Utils.VisibleMgr
local PlayEffectInternal = require(script.Parent.PlayEffectInternal)
local AssetPaths = Utils.AssetPaths

local SKILL_BUFF_ATTACH_PART_NAMES = {
	"HumanoidRootPart",
	"Torso",
	"UpperTorso",
	"LowerTorso",
	"Hitbox",
	"Root",
	"Main",
}

--[[
	在 Monster/Summons/CanBroke 等目录中按 monsterId 查找防守方实例
	@param folder Instance?
	@param monsterId string
	@return Instance?
]]
local function _findDefenderInstInFolder(folder: Instance?, monsterId: string): Instance?
	if not folder then
		return nil
	end
	local direct = folder:FindFirstChild(monsterId)
	if direct and (direct:IsA("Model") or direct:IsA("BasePart")) then
		return direct
	end
	for _, d in folder:GetDescendants() do
		if (d:IsA("Model") or d:IsA("BasePart")) and d.Name == monsterId then
			return d
		end
	end
	return nil
end

--[[
	解析 DoT 挂身 FX 的防守方 Character/Model
	@param defenderUserId number?
	@param monsterId string?
	@return Instance?
]]
local function _resolveDotDefenderTarget(defenderUserId: number?, monsterId: string?): Instance?
	if type(defenderUserId) == "number" then
		local plr = Players:GetPlayerByUserId(defenderUserId)
		return plr and plr.Character or nil
	end
	if type(monsterId) == "string" and monsterId ~= "" then
		local inst = _findDefenderInstInFolder(workspace:FindFirstChild("Monster"), monsterId)
		if inst then
			return inst
		end
		inst = _findDefenderInstInFolder(workspace:FindFirstChild("Summons"), monsterId)
		if inst then
			return inst
		end
		for _, tagged in CollectionService:GetTagged("CanBroke") do
			if tagged.Name == monsterId and (tagged:IsA("Model") or tagged:IsA("BasePart")) then
				return tagged
			end
		end
	end
	return nil
end

--[[
	解析挂身 FX 焊接用的 BasePart（优先配置名列表）
	@param target Instance
	@return BasePart?
]]
local function _resolveSkillBuffDefenderAttachPart(target: Instance): BasePart?
	if target:IsA("BasePart") then
		return target
	end
	if not target:IsA("Model") then
		return nil
	end
	local model = target :: Model
	for _, name in SKILL_BUFF_ATTACH_PART_NAMES do
		local p = model:FindFirstChild(name)
		if p and p:IsA("BasePart") then
			return p
		end
	end
	if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then
		return model.PrimaryPart
	end
	local best: BasePart? = nil
	local bestVol = 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			local vol = d.Size.X * d.Size.Y * d.Size.Z
			if vol > bestVol then
				bestVol = vol
				best = d
			end
		end
	end
	return best
end

--[[ PrimaryPart 优先，无则首 Part；失败返回 false。]]
local function _weldSkillFxModelToWorldPart(fx: Model, worldPart: BasePart): boolean
	return FXUtil.WeldFxModelToBasePart(fx, worldPart)
end

type SkillBuffDotVfxHandle = {
	cancelled: boolean,
	fx: Model,
	dieConn: RBXScriptConnection?,
	renewGen: number,
}

local skillBuffDotVfxByKey: { [string]: SkillBuffDotVfxHandle } = {}

--[[
	DoT 挂身 FX 缓存键（玩家 userId 或怪物 id + vfxName）
	@param defenderUserId number?
	@param monsterId string?
	@param vfxName string
	@return string?
]]
local function _skillBuffDotVfxCacheKey(defenderUserId: number?, monsterId: string?, vfxName: string): string?
	if type(vfxName) ~= "string" or vfxName == "" then
		return nil
	end
	if type(defenderUserId) == "number" then
		return "p" .. tostring(defenderUserId) .. "_" .. vfxName
	end
	if type(monsterId) == "string" and monsterId ~= "" then
		return "m" .. monsterId .. "_" .. vfxName
	end
	return nil
end

--[[
	对象池 VFX 停播、拆焊并归还
	@param fx Model?
]]
local function _cleanupSkillBuffDotVfxPooled(fx: Model?)
	if not fx then
		return
	end
	PlayEffectInternal.destroyFxWeldConstraintsRecursive(fx)
	VisibleMgr.UnAnchoredAll(fx)
	PlayEffectInternal.stopPooledVfxAndRecycle(fx)
end

--[[
	取消并清理 DoT 挂身 FX 句柄
	@param cacheKey string?
	@param handle SkillBuffDotVfxHandle
]]
local function _cancelSkillBuffDotVfxHandle(cacheKey: string?, handle: SkillBuffDotVfxHandle)
	if not handle or handle.cancelled then
		return
	end
	handle.cancelled = true
	if handle.dieConn then
		handle.dieConn:Disconnect()
		handle.dieConn = nil
	end
	_cleanupSkillBuffDotVfxPooled(handle.fx)
	if cacheKey then
		local cur = skillBuffDotVfxByKey[cacheKey]
		if cur == handle then
			skillBuffDotVfxByKey[cacheKey] = nil
		end
	end
end

--[[
	按画质策略发射 DoT 挂身粒子（lite：单次；否则持续）
	@param fx Model
	@param liteVfx boolean
]]
local function _emitSkillBuffDotVfx(fx: Model, liteVfx: boolean)
	if liteVfx then
		FXUtil.Emit_Particles_GetDescendants(fx, true)
	else
		FXUtil.EmitOnceThenEnableContinuous(fx)
	end
end

--[[
	到期后回收 DoT 挂身 FX（支持 renewGen 续期）
	@param cacheKey string?
	@param handle SkillBuffDotVfxHandle
	@param dur number
	@param liteVfx boolean
]]
local function _scheduleSkillBuffDotVfxExpire(
	cacheKey: string?,
	handle: SkillBuffDotVfxHandle,
	dur: number,
	liteVfx: boolean
)
	handle.renewGen = (handle.renewGen or 0) + 1
	local gen = handle.renewGen
	task.spawn(function()
		local waitDur = if liteVfx then math.min(dur, 4) else dur
		task.wait(waitDur)
		if handle.cancelled or handle.renewGen ~= gen then
			return
		end
		local cur = cacheKey and skillBuffDotVfxByKey[cacheKey]
		if cur ~= handle then
			return
		end
		_cancelSkillBuffDotVfxHandle(cacheKey, handle)
	end)
end

--[[
	绑定目标死亡/离树时自动回收挂身 FX
	@param target Instance
	@param cacheKey string?
	@param handle SkillBuffDotVfxHandle
]]
local function _bindSkillBuffDotVfxLifecycle(target: Instance, cacheKey: string?, handle: SkillBuffDotVfxHandle)
	if handle.dieConn then
		handle.dieConn:Disconnect()
		handle.dieConn = nil
	end
	if target:IsA("Model") then
		local hum = target:FindFirstChildOfClass("Humanoid")
		if hum then
			handle.dieConn = hum.Died:Connect(function()
				_cancelSkillBuffDotVfxHandle(cacheKey, handle)
			end)
			return
		end
	end
	handle.dieConn = target.AncestryChanged:Connect(function()
		if not target.Parent then
			_cancelSkillBuffDotVfxHandle(cacheKey, handle)
		end
	end)
end

--[[
	同目标同名 FX 续期：重焊挂点并刷新到期计时
	@return boolean 是否续期成功
]]
local function _tryRenewSkillBuffDotVfxHandle(
	prev: SkillBuffDotVfxHandle,
	cacheKey: string?,
	attachPart: BasePart,
	dur: number,
	liteVfx: boolean
): boolean
	if prev.cancelled or not prev.fx or not prev.fx.Parent then
		return false
	end
	if not _weldSkillFxModelToWorldPart(prev.fx, attachPart) then
		return false
	end
	_emitSkillBuffDotVfx(prev.fx, liteVfx)
	_scheduleSkillBuffDotVfxExpire(cacheKey, prev, dur, liteVfx)
	return true
end

--[[
	低画质或纯触屏设备使用 lite 单次粒子策略
	@return boolean
]]
local function _shouldUseLiteSkillBuffDotVfx(): boolean
	local GetData = Utils.GetData
	local lp = Utils.LocalPlayer or Players.LocalPlayer
	if GetData and lp and GetData.GetSetting(lp, "GraphicsQuality") == 0 then
		return true
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return true
	end
	return false
end

--[[ 客户端：DoT / 元素附着 — 对象池、Weld 到挂点；同目标同名刷新时原地续期+重焊（避免回池后错位）；durationSec 缺省 5。
	低画质 / 纯触屏：仅单次 Emit，不挂持续粒子。]]
function FXUtil.PlayModelResSkillBuffDotHitFx(vfxName: string, defenderUserId: number?, monsterId: string?, durationSec: number?)
	if RunService:IsServer() then
		return
	end
	if type(vfxName) ~= "string" or vfxName == "" then
		return
	end
	local dur = tonumber(durationSec)
	if not dur or dur <= 0 or dur ~= dur then
		dur = 5
	end
	local targetInst = _resolveDotDefenderTarget(defenderUserId, monsterId)
	if not targetInst or not targetInst.Parent then
		return
	end
	local attachPart = _resolveSkillBuffDefenderAttachPart(targetInst)
	if not attachPart or not attachPart.Parent then
		return
	end
	local skillRes = AssetPaths.Resolve("ModelRes/Skill", AssetPaths.Scope.Shared)
	local template = skillRes and skillRes:FindFirstChild(vfxName)
	if not template or not template:IsA("Model") then
		return
	end
	local cacheKey = _skillBuffDotVfxCacheKey(defenderUserId, monsterId, vfxName)
	local liteVfx = _shouldUseLiteSkillBuffDotVfx()
	local prev = cacheKey and skillBuffDotVfxByKey[cacheKey]
	if prev and _tryRenewSkillBuffDotVfxHandle(prev, cacheKey, attachPart, dur, liteVfx) then
		return
	end
	if prev then
		_cancelSkillBuffDotVfxHandle(cacheKey, prev)
	end
	local fx = FXUtil.GetInstance_From_Pool(template)
	if not fx or not fx:IsA("Model") then
		return
	end
	local ResRestore = Utils.ResRestore
	if ResRestore and ResRestore.Restore then
		ResRestore.Restore(fx)
	end
	local handle: SkillBuffDotVfxHandle = { cancelled = false, fx = fx, dieConn = nil, renewGen = 0 }
	if cacheKey then
		skillBuffDotVfxByKey[cacheKey] = handle
	end

	PlayEffectInternal.prepEffectModelForWorldShared(fx, true)
	fx.Parent = workspace.Debris
	if not _weldSkillFxModelToWorldPart(fx, attachPart) then
		_cancelSkillBuffDotVfxHandle(cacheKey, handle)
		return
	end

	_bindSkillBuffDotVfxLifecycle(targetInst, cacheKey, handle)
	_emitSkillBuffDotVfx(fx, liteVfx)
	_scheduleSkillBuffDotVfxExpire(cacheKey, handle, dur, liteVfx)
end

--[[ 客户端：离区或清除环境 DoT 时立刻回收灼烧挂身 FX。]]
function FXUtil.StopModelResSkillBuffDotHitFx(vfxName: string, defenderUserId: number?, monsterId: string?)
	if RunService:IsServer() then
		return
	end
	if type(vfxName) ~= "string" or vfxName == "" then
		return
	end
	local cacheKey = _skillBuffDotVfxCacheKey(defenderUserId, monsterId, vfxName)
	if not cacheKey then
		return
	end
	local handle = skillBuffDotVfxByKey[cacheKey]
	if handle then
		_cancelSkillBuffDotVfxHandle(cacheKey, handle)
	end
end
end
