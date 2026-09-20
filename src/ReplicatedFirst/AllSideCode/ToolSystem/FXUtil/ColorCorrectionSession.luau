--[[
	Module: FXUtil/ColorCorrectionSession
	Description: ColorCorrection 写会话共享层 — resolve / 快照 / 还原 / FXUtilCcBusy 租约 / 代际中断
	Author: LinAoyu
	Created: 2026-08-04
	Last Modified: 2026-08-04

	供 ColorCorrection（旧栈）与 ColorCorrectionCurve 共用。
	租约：Lighting.FXUtilCcBusy；升起时递增 FXUtilCcBusyGen，清除 busy 时保留 Gen（Manager 下降沿防抖）。
	访问：require(script.Parent.ColorCorrectionSession)；对外 IsColorCorrectionBusy 经 Install 挂到 FXUtil。

	结束语义：
	- 自然结束（restoreOnEnd=true / FinishCurve restore）：销毁 Temp（若有），不写过期 snap；
	  SetBusy(false) 后由 LightingManager 下降沿 reconcile 到天气+overlay 期望态。
	- Abort(true) / RestoreHolding / Reset：显式 ApplyRestore 到进 FX 前快照，再清 busy。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Lighting = Utils.Lighting
local Log = Utils.Log

local Session = {}

Session.FXUTIL_CC_TEMP_NAME = "FXUtil_ColorCorrection_Temp"
Session.BUSY_ATTR = "FXUtilCcBusy"
Session.BUSY_GEN_ATTR = "FXUtilCcBusyGen"

export type CcSnapshot = {
	Brightness: number,
	Contrast: number,
	Saturation: number,
	TintColor: Color3,
	Enabled: boolean,
}

Session.restoreSnapshot = nil :: CcSnapshot?
Session.targetEffect = nil :: ColorCorrectionEffect?
Session.ownedTemporary = false
Session.keyframeConn = nil :: RBXScriptConnection?
Session.keyframeSeq = 0

Session.curveConn = nil :: RBXScriptConnection?
Session.curvePlaying = false
Session.curveOnComplete = nil :: (() -> ())?
Session.curveSnap = nil :: CcSnapshot?
Session.curveOwnedTemp = false
Session.curveEffect = nil :: ColorCorrectionEffect?
-- restoreOnEnd=false 自然结束后：快照仍在，等待 Abort(true)
Session.curveHolding = false

--[[
	读取 FX 是否占用 ColorCorrection（Lighting Attribute）。
	@return boolean - true 表示占用中
]]
function Session.IsBusy(): boolean
	return Lighting:GetAttribute(Session.BUSY_ATTR) == true
end

--[[
	设置 / 清除租约 Attribute。
	busy=true 时递增 FXUtilCcBusyGen（供 LightingManager 下降沿防抖）；
	busy=false 时清除 FXUtilCcBusy，保留 Gen。
	@param busy boolean - true 置 busy；false 清除 busy Attribute
]]
function Session.SetBusy(busy: boolean)
	if busy then
		local prevGen = Lighting:GetAttribute(Session.BUSY_GEN_ATTR)
		local nextGen = (typeof(prevGen) == "number" and prevGen or 0) + 1
		Lighting:SetAttribute(Session.BUSY_GEN_ATTR, nextGen)
		Lighting:SetAttribute(Session.BUSY_ATTR, true)
	else
		Lighting:SetAttribute(Session.BUSY_ATTR, nil)
	end
end

--[[
	解析天气 ColorCorrection；忽略本模块 Temp；无命名实例时不回落到 Temp。
	@return ColorCorrectionEffect?
]]
function Session.ResolveEffect(): ColorCorrectionEffect?
	local named = Lighting:FindFirstChild("ColorCorrection")
	if named and named:IsA("ColorCorrectionEffect") then
		return named
	end
	for _, child in Lighting:GetChildren() do
		if child:IsA("ColorCorrectionEffect") and child.Name ~= Session.FXUTIL_CC_TEMP_NAME then
			return child
		end
	end
	return nil
end

--[[
	捕获 effect 属性快照。
	@param effect ColorCorrectionEffect - 目标滤镜
	@return CcSnapshot - 快照
]]
function Session.CaptureSnapshot(effect: ColorCorrectionEffect): CcSnapshot
	return {
		Brightness = effect.Brightness,
		Contrast = effect.Contrast,
		Saturation = effect.Saturation,
		TintColor = effect.TintColor,
		Enabled = effect.Enabled,
	}
end

--[[
	从快照还原 effect；临时实例则销毁。
	@param effect ColorCorrectionEffect - 目标滤镜
	@param snap CcSnapshot? - 开始前快照
	@param ownedTemp boolean - 是否为本模块创建的临时实例
]]
function Session.ApplyRestore(effect: ColorCorrectionEffect, snap: CcSnapshot?, ownedTemp: boolean)
	if not effect.Parent then
		return
	end
	if ownedTemp then
		effect:Destroy()
		return
	end
	if snap then
		effect.Brightness = snap.Brightness
		effect.Contrast = snap.Contrast
		effect.Saturation = snap.Saturation
		effect.TintColor = snap.TintColor
		effect.Enabled = snap.Enabled
	end
end

--[[
	清除写目标引用（不还原、不改 busy）。
]]
function Session.ClearWriteTarget()
	Session.restoreSnapshot = nil
	Session.targetEffect = nil
	Session.ownedTemporary = false
end

--[[
	还原写会话并释放租约（Holding 一并清掉）。
	@param restore boolean - 是否还原快照 / 销毁 Temp
]]
function Session.ReleaseWriteSession(restore: boolean)
	local effect = Session.targetEffect
	local snap = Session.restoreSnapshot
	local ownedTemp = Session.ownedTemporary

	if restore and effect then
		Session.ApplyRestore(effect, snap, ownedTemp)
	end

	Session.ClearWriteTarget()
	Session.curveHolding = false
	Session.curveSnap = nil
	Session.curveEffect = nil
	Session.curveOwnedTemp = false
	Session.SetBusy(false)
end

--[[
	结束 Play 曲线会话（断连 + 可选收口）。
	@param restore boolean - true：自然结束路径（毁 Temp、不写 snap、降 busy 供 Manager reconcile）
	@param callComplete boolean - 是否触发 onComplete
	@param keepHolding boolean - true：不还原时进入 Holding 并保持 busy
]]
function Session.FinishCurve(restore: boolean, callComplete: boolean, keepHolding: boolean?)
	if Session.curveConn then
		Session.curveConn:Disconnect()
		Session.curveConn = nil
	end
	local wasPlaying = Session.curvePlaying
	local effect = Session.curveEffect
	local ownedTemp = Session.curveOwnedTemp
	local onComplete = Session.curveOnComplete

	Session.curvePlaying = false
	Session.curveOnComplete = nil

	if restore then
		-- 自然结束：不写过期 snap，交给 LightingManager reconcile
		if ownedTemp and effect and effect.Parent then
			effect:Destroy()
		end
		if Session.targetEffect == effect or ownedTemp then
			Session.ClearWriteTarget()
		end
		Session.curveSnap = nil
		Session.curveEffect = nil
		Session.curveOwnedTemp = false
		Session.curveHolding = false
		Session.SetBusy(false)
	elseif keepHolding then
		-- 末键保持：快照留到 Abort(true)；租约保持
		Session.curveHolding = true
	else
		Session.curveSnap = nil
		Session.curveEffect = nil
		Session.curveOwnedTemp = false
		Session.curveHolding = false
		-- 中断且不还原：busy 由后续 BeginWrite / Reset 接管；无后续则由调用方 Abort/Reset
	end

	if callComplete and wasPlaying and type(onComplete) == "function" then
		task.defer(function()
			local ok, err = pcall(onComplete)
			if not ok then
				Log.warn("[FXUtil] PlayColorCorrectionCurve onComplete:", err)
			end
		end)
	end
end

--[[
	中断 Tween / Play（不还原）。Holding 残留引用一并清掉（由新会话接管）。
]]
function Session.AbortKeyframeAnim()
	if Session.keyframeConn then
		Session.keyframeConn:Disconnect()
		Session.keyframeConn = nil
	end
	if Session.curvePlaying or Session.curveConn then
		Session.FinishCurve(false, false, false)
	else
		Session.curveSnap = nil
		Session.curveEffect = nil
		Session.curveOnComplete = nil
		Session.curveOwnedTemp = false
		Session.curveHolding = false
	end
	Session.keyframeSeq += 1
end

--[[
	解析或创建 Temp，建立写会话并 Acquire 租约。
	@param abortAnim boolean - 是否先中断进行中的动画
	@return ColorCorrectionEffect - 目标
	@return CcSnapshot - 本次会话快照（Temp 为默认身份值）
	@return boolean - ownedTemp
	@return boolean - createdTemp
]]
function Session.BeginWriteSession(abortAnim: boolean): (ColorCorrectionEffect, CcSnapshot, boolean, boolean)
	if abortAnim then
		Session.AbortKeyframeAnim()
	end

	local effect = Session.ResolveEffect()
	local createdTemp = false
	if not effect then
		effect = Instance.new("ColorCorrectionEffect")
		effect.Name = Session.FXUTIL_CC_TEMP_NAME
		effect.Parent = Lighting
		createdTemp = true
		Session.ownedTemporary = true
		Session.restoreSnapshot = nil
	elseif Session.targetEffect ~= effect then
		Session.restoreSnapshot = nil
		Session.ownedTemporary = false
	end

	Session.targetEffect = effect

	local snap: CcSnapshot
	if createdTemp then
		snap = {
			Brightness = 0,
			Contrast = 0,
			Saturation = 0,
			TintColor = Color3.new(1, 1, 1),
			Enabled = true,
		}
	else
		if Session.restoreSnapshot == nil then
			Session.restoreSnapshot = Session.CaptureSnapshot(effect)
		end
		snap = Session.restoreSnapshot :: CcSnapshot
	end

	Session.SetBusy(true)
	return effect, snap, Session.ownedTemporary or createdTemp, createdTemp
end

--[[
	Holding 态下 Abort(true) 还原并释放租约（自然结束 bump seq 后仍可调用）。
	@param effectFallback ColorCorrectionEffect - 会话创建时的 effect
	@param snapFallback CcSnapshot - 会话快照
	@return boolean - 是否执行了 Holding 还原
]]
function Session.RestoreHolding(effectFallback: ColorCorrectionEffect, snapFallback: CcSnapshot): boolean
	if Session.curvePlaying or Session.curveConn then
		return false
	end
	if not Session.curveHolding and Session.curveSnap == nil and Session.curveEffect == nil then
		return false
	end

	local effectRef = Session.curveEffect or effectFallback
	local snapRef = Session.curveSnap or snapFallback
	local owned = Session.curveOwnedTemp
	if effectRef and effectRef.Parent then
		Session.ApplyRestore(effectRef, snapRef, owned)
	end
	if Session.targetEffect == effectRef then
		Session.ClearWriteTarget()
	end
	Session.curveSnap = nil
	Session.curveEffect = nil
	Session.curveOwnedTemp = false
	Session.curveHolding = false
	Session.SetBusy(false)
	return true
end

--[[
	将 IsColorCorrectionBusy 挂到 FXUtil。
	@param FXUtil table - FXUtil 模块表
]]
function Session.Install(FXUtil: { [string]: any })
	--[[
		查询 FX 是否占用 Lighting ColorCorrection（租约）。
		@return boolean - true 表示占用中
	]]
	function FXUtil.IsColorCorrectionBusy(): boolean
		return Session.IsBusy()
	end
end

return Session
