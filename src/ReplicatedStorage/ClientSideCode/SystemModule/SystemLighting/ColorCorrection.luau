--[[
	Module: ColorCorrection
	Description: 管理 ColorCorrectionEffect 参数与显隐
	Author: 林奥宇
	Created: 2026-01-23
	Last Modified: 2026-08-31

	功能：
	- 从模板 Instance 读取并 tween Brightness / Contrast / TintColor / Saturation
	- 与 FXUtil 协作：Lighting.Attribute FXUtilCcBusy=true 时跳过写 Instance / Enabled，
	  避免天气过渡覆盖技能滤镜曲线（逻辑字段仍更新；busy 释放后由 LightingManager
	  监听下降沿 + FXUtilCcBusyGen 代际防抖，仅 reconcile ColorCorrection）
	- applyGen：Completed 时校验，过期意图不清理当前 Tween 引用
	- 关闭通道不做属性 Tween：先即时写目标属性，再 Enabled=false
	- setColorCorrectionParams / hide / show 显式返回 EnumMgr.LightingApplyResult（Ok / FxBusy）

	写者优先级（相对本通道）：FxLease > CustomOverlay > WeatherBase
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local InsMgr = Utils.InsMgr
local Lighting = Utils.Lighting
local LightingTweenUtil = Utils.LightingTweenUtil
local EnumMgr = Utils.EnumMgr
local EffectChannelUtil = require(script.Parent.EffectChannelUtil)

local FXUTIL_CC_BUSY_ATTR = "FXUtilCcBusy"
local LightingApplyResult = EnumMgr.LightingApplyResult

export type ColorCorrection = {
	Instance: ColorCorrectionEffect,
	Brightness: number,
	Contrast: number,
	TintColor: Color3,
	Saturation: number,
	TransitionTween: Tween?,
	_fxBusyConn: RBXScriptConnection?,
	_lastApplyGen: number?,
	new: (self: ColorCorrection) -> ColorCorrection,
	setColorCorrectionParams: (
		self: ColorCorrection,
		newColorCorrection: ColorCorrectionEffect,
		transitionTime: number,
		applyGen: number?
	) -> string,
	hide: (self: ColorCorrection) -> string,
	show: (self: ColorCorrection) -> string,
	destroy: (self: ColorCorrection) -> nil,
}

local ColorCorrection = {}
ColorCorrection.__index = ColorCorrection

-- ========================================
-- 私有函数
-- ========================================
--[[
	FX 是否占用 ColorCorrection（租约）

	@return boolean - true 表示 FXUtil 占用中
]]
local function _isFxCcBusy(): boolean
	return Lighting:GetAttribute(FXUTIL_CC_BUSY_ATTR) == true
end

--[[
	销毁进行中的过渡 Tween

	@param self ColorCorrection - 本模块实例
	@return nil - 无返回值
]]
local function _cancelTransitionTween(self: ColorCorrection)
	LightingTweenUtil.cancelTween(self.TransitionTween)
	self.TransitionTween = nil
end

--[[
	直接写入 Instance 四属性（不经 Tween）

	@param self ColorCorrection - 本模块实例
	@param newColorCorrection ColorCorrectionEffect - 模板源
	@return nil - 无返回值
]]
local function _setColorCorrectionParams(self: ColorCorrection, newColorCorrection: ColorCorrectionEffect)
	self.Instance.Brightness = newColorCorrection.Brightness
	self.Instance.Contrast = newColorCorrection.Contrast
	self.Instance.TintColor = newColorCorrection.TintColor
	self.Instance.Saturation = newColorCorrection.Saturation
end

-- ========================================
-- 公共函数
-- ========================================
--[[
	初始化 ColorCorrection；监听 FX 租约升起时停天气 Tween

	@return ColorCorrection - 模块实例
]]
function ColorCorrection.new()
	local self = setmetatable({}, ColorCorrection)
	self.Instance = InsMgr.GetIns("ColorCorrection", "ColorCorrectionEffect", Lighting)
	self.Brightness = 0
	self.Contrast = 0
	self.TintColor = Color3.new(1, 1, 1)
	self.Saturation = 0
	self.TransitionTween = nil
	self._lastApplyGen = nil
	-- FX 租约升起时立刻停掉进行中的天气 Tween，避免与曲线互盖
	self._fxBusyConn = Lighting:GetAttributeChangedSignal(FXUTIL_CC_BUSY_ATTR):Connect(function()
		if _isFxCcBusy() then
			_cancelTransitionTween(self)
		end
	end)
	return self
end

--[[
	设置 ColorCorrection 相关参数

	@param newColorCorrection ColorCorrectionEffect - 参数模板
	@param transitionTime number - 过渡时间（秒）；0 为立即生效
	@param applyGen number? - Weather 生效意图代际
	@return string - EnumMgr.LightingApplyResult：Ok 已写/启动 Tween；FxBusy 因租约跳过写（逻辑字段仍更新）
]]
function ColorCorrection.setColorCorrectionParams(
	self: ColorCorrection,
	newColorCorrection: ColorCorrectionEffect,
	transitionTime: number,
	applyGen: number?
): string
	transitionTime = LightingTweenUtil.normalizeTransitionTime(transitionTime)
	self.Brightness = newColorCorrection.Brightness
	self.Contrast = newColorCorrection.Contrast
	self.TintColor = newColorCorrection.TintColor
	self.Saturation = newColorCorrection.Saturation

	_cancelTransitionTween(self)

	-- 租约占用：只保留逻辑字段，不写 Instance（避免与 FX 曲线互盖）
	if _isFxCcBusy() then
		return LightingApplyResult.FxBusy
	end

	self._lastApplyGen = applyGen

	if not EffectChannelUtil.beginEnabledWrite(self, newColorCorrection.Enabled, function()
		_setColorCorrectionParams(self, newColorCorrection)
	end) then
		return LightingApplyResult.Ok
	end

	local capturedGen = applyGen
	self.TransitionTween = LightingTweenUtil.playOrApply(
		nil,
		self.Instance,
		transitionTime,
		{
			Brightness = self.Brightness,
			Contrast = self.Contrast,
			TintColor = self.TintColor,
			Saturation = self.Saturation,
		},
		function()
			_setColorCorrectionParams(self, newColorCorrection)
		end,
		function()
			if capturedGen ~= nil and self._lastApplyGen ~= capturedGen then
				return
			end
			self.TransitionTween = nil
		end
	)

	return LightingApplyResult.Ok
end

--[[
	隐藏 ColorCorrection（Enabled=false）

	@return string - EnumMgr.LightingApplyResult：Ok 已 hide；FxBusy 因租约跳过
]]
function ColorCorrection.hide(self: ColorCorrection): string
	if _isFxCcBusy() then
		return LightingApplyResult.FxBusy
	end
	EffectChannelUtil.hideEnabledEffect(self)
	return LightingApplyResult.Ok
end

--[[
	显示 ColorCorrection（Enabled=true）

	@return string - EnumMgr.LightingApplyResult：Ok 已 show；FxBusy 因租约跳过
]]
function ColorCorrection.show(self: ColorCorrection): string
	if _isFxCcBusy() then
		return LightingApplyResult.FxBusy
	end
	self.Instance.Enabled = true
	return LightingApplyResult.Ok
end

--[[
	销毁模块，断开租约监听并停止 Tween；FX 租约占用时不改 Enabled，避免打断技能滤镜

	@return nil - 无返回值
]]
function ColorCorrection.destroy(self: ColorCorrection)
	_cancelTransitionTween(self)
	if self._fxBusyConn then
		self._fxBusyConn:Disconnect()
		self._fxBusyConn = nil
	end
	if not _isFxCcBusy() then
		self.Instance.Enabled = false
	end
end

return ColorCorrection
