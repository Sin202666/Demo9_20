--[[
	Module: TipsRenderer
	Description: 客户端提示 UI 渲染（创建、动画、回收；短时同内容合并为「文案 xN」）
	Author: 林奥宇
	Created: 2026-07-02
	Last Modified: 2026-09-01

	注意：本模块含客户端副作用（操作 PlayerGui），仅客户端 require。
	服务端误调会 Log.warn 并 return，不会写 UI。

	功能：
	- createTip / templateTip：多段或模板单句提示条
	- showFromServerTemplate：服务端 Type 表 → TipsTemplateBuilder → 展示
	- 同指纹 Tip 仍在展示中再次到达时：不新建条，改为「原文案 xN」并刷新 DISPLAY_DURATION
	- 展示文案为已翻译字符串写入 TextLabel（不绑 SetText）；切语言后当前条不会自动刷新

	与兄弟模块：
	- TipsModule：网络 / Bindable 路由（业务调用方入口）
	- TipsManager：监听 SHOW_TIPS* 后调用本模块
	- TipsConfig / TipsTemplateBuilder：样式常量与服务端 Type 构建

	【引入】
	local TipsRenderer = Utils.TipsRenderer

	【示例】
	TipsRenderer.templateTip(TranslationHelper.TranslateByKey("领取成功"), TipsConfig.TEMPLATE_NORMAL)
	TipsRenderer.showFromServerTemplate({ Type = TipsConfig.SERVER_TEMPLATE_REWARD, ID = 1001, Count = 5 })
	TipsRenderer.destroy()  -- 重置/离开时取消收起计时并归还对象池
]]

-- ========================================
-- Requires
-- ========================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local TipsConfig = require(script.Parent.TipsConfig)
local TipsTemplateBuilder = require(script.Parent.TipsTemplateBuilder)

local Players = Utils.Players
local RunService = Utils.RunService
local TweenService = Utils.TweenService
local InsMgr = Utils.InsMgr
local UIMgr = Utils.UIMgr
local ObjectPoolUtil = Utils.ObjectPoolUtil
local Log = Utils.Log
local TextService = game:GetService("TextService")

-- ========================================
-- Module definition
-- ========================================

local TipsRenderer = {}

-- ========================================
-- Types & private variables
-- ========================================

type ActiveTipEntry = {
	fingerprint: string,
	baseText: string,
	count: number,
	bgFrame: Frame,
	hideToken: number,
	styleData: { [string]: any },
}

local _layoutIndex = 0
local _isClientReady = false
local _localPlayer: Player? = nil
local _hidingFrames: { [Frame]: boolean } = {}
local _activeTips: { [string]: ActiveTipEntry } = {}
local _frameToFingerprint: { [Frame]: string } = {}
local _cachedTipsFrame: Frame? = nil

-- ========================================
-- Client init helpers
-- ========================================

--[[
	确保仅在客户端初始化运行时状态
	@return boolean - 客户端且初始化成功为 true；服务端调用为 false
]]
local function _ensureClientReady(): boolean
	if not RunService:IsClient() then
		Log.warn("TipsRenderer 仅客户端可用")
		return false
	end

	if _isClientReady then
		return true
	end

	_localPlayer = Players.LocalPlayer
	_isClientReady = true
	return true
end

--[[
	获取 PlayerGui 下 Tips 条容器 Frame（命中后缓存，Parent 丢失时重解析）
	@return Frame? - TipsGui.NewTipsFrame；PlayerGui 或节点缺失时 nil
]]
local function _getTipsFrame(): Frame?
	if _cachedTipsFrame and _cachedTipsFrame.Parent then
		return _cachedTipsFrame
	end
	_cachedTipsFrame = nil

	if not _ensureClientReady() or not _localPlayer then
		return nil
	end

	local playerGui = _localPlayer:FindFirstChild("PlayerGui")
	if not playerGui then
		return nil
	end

	local tipGui = playerGui:FindFirstChild("TipsGui")
	if not tipGui then
		return nil
	end

	local tipsFrame = tipGui:FindFirstChild("NewTipsFrame") :: Frame?
	if tipsFrame then
		_cachedTipsFrame = tipsFrame
	end
	return tipsFrame
end

--[[
	获取背景条内承载 TextLabel 的内容 Frame
	@param bgFrame Frame - 对象池取出的背景条
	@return Frame? - 名为 Frame 的子节点
]]
local function _getContentFrame(bgFrame: Frame): Frame?
	return bgFrame:FindFirstChild("Frame") :: Frame?
end

--[[
	遍历内容区内的 TextLabel（条内通常 1～3 个，非战斗热路径）
	@param contentFrame Frame - 背景条内 Frame
	@param visitor (TextLabel) -> () - 对每个标签的回调
	@return nil - 无返回值
]]
local function _forEachTextLabel(contentFrame: Frame, visitor: (TextLabel) -> ())
	for _, child in contentFrame:GetChildren() do
		if child:IsA("TextLabel") then
			visitor(child)
		end
	end
end

-- ========================================
-- Stack / identity
-- ========================================

--[[
	由多段 tipData 生成合并指纹、原文案与首段样式
	@param tipData {any} - 文本段配置数组
	@return string - 指纹（文案 + 样式，避免正误样式互并）
	@return string - 拼接后的原文案（不含 xN）
	@return { [string]: any } - 首段样式浅拷贝，合并展示时复用
]]
local function _buildTipIdentity(tipData: { any }): (string, string, { [string]: any })
	local textParts: { string } = {}
	local styleParts: { string } = {}

	for _, seg in ipairs(tipData) do
		local text = tostring(seg.Text or "")
		table.insert(textParts, text)
		table.insert(
			styleParts,
			tostring(seg.UIGradientString or "") .. ":" .. tostring(seg.TextSize or "") .. ":" .. tostring(seg.Font)
		)
	end

	local baseText = table.concat(textParts, "")
	local fingerprint = baseText .. "\0" .. table.concat(styleParts, "|")
	local styleData: { [string]: any } = {}
	local firstSeg = tipData[1]
	if firstSeg then
		for key, value in pairs(firstSeg) do
			styleData[key] = value
		end
	end
	return fingerprint, baseText, styleData
end

--[[
	组装展示文案：count==1 为原文，否则「原文 xN」
	@param baseText string - 原文案
	@param count number - 累计次数
	@return string - UI 展示文案
]]
local function _formatStackedText(baseText: string, count: number): string
	if count <= 1 then
		return baseText
	end
	return baseText .. TipsConfig.STACK_COUNT_PREFIX .. tostring(count)
end

--[[
	解除背景条与活跃合并表的关联（开始收起时调用）
	@param bgFrame Frame - 提示背景条
	@return nil - 无返回值
]]
local function _clearActiveForFrame(bgFrame: Frame)
	local fingerprint = _frameToFingerprint[bgFrame]
	if not fingerprint then
		return
	end

	local entry = _activeTips[fingerprint]
	if entry and entry.bgFrame == bgFrame then
		_activeTips[fingerprint] = nil
	end
	_frameToFingerprint[bgFrame] = nil
end

-- ========================================
-- Animation
-- ========================================

--[[
	播放 Size Tween（Back Out），完成后 Destroy Tween
	@param instance GuiObject - 背景条或 TextLabel
	@param duration number - 时长，取 TipsConfig.TWEEN_*
	@param targetSize UDim2 - 目标 Size
	@param onCompleted (() -> ())? - 完成后回调；nil 则只销毁 Tween
	@return nil - 无返回值
]]
local function _tweenSize(instance: GuiObject, duration: number, targetSize: UDim2, onCompleted: (() -> ())?)
	local tween = TweenService:Create(
		instance,
		TweenInfo.new(duration, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = targetSize }
	)
	tween.Completed:Once(function()
		tween:Destroy()
		if onCompleted then
			onCompleted()
		end
	end)
	tween:Play()
end

--[[
	播放提示条展开动画（高度与 TextLabel 渐入）
	@param frame Frame - 已挂载到 NewTipsFrame 的背景条实例
	@return nil - 无返回值
]]
local function _showTween(frame: Frame)
	local frameSize = frame.Size
	frame.Size = UDim2.new(frameSize.X.Scale, frameSize.X.Offset, 0, 0)
	_tweenSize(frame, TipsConfig.TWEEN_SHOW_DURATION, frameSize)

	local contentFrame = _getContentFrame(frame)
	if not contentFrame then
		return
	end

	_forEachTextLabel(contentFrame, function(child)
		child.TextScaled = true
		local labelSize = child.Size
		child.Size = UDim2.new(labelSize.X.Scale, labelSize.X.Offset, 0, 0)
		_tweenSize(child, TipsConfig.TWEEN_TEXT_DURATION, labelSize)
	end)
end

--[[
	播放收起动画并回收到对象池（幂等，重复调用安全）
	@param frame Frame - 待回收的背景条实例
	@return nil - 已在收起中时直接 return
]]
local function _hideTween(frame: Frame)
	if _hidingFrames[frame] then
		return
	end
	_hidingFrames[frame] = true
	_clearActiveForFrame(frame)

	local frameSize = UDim2.new(frame.Size.X.Scale, frame.Size.X.Offset, 0, 0)
	_tweenSize(frame, TipsConfig.TWEEN_SHOW_DURATION, frameSize, function()
		_hidingFrames[frame] = nil

		local innerFrame = _getContentFrame(frame)
		if innerFrame then
			_forEachTextLabel(innerFrame, function(child)
				ObjectPoolUtil.backToPool(child)
			end)
		end

		ObjectPoolUtil.backToPool(frame)
	end)

	local innerFrame = _getContentFrame(frame)
	if not innerFrame then
		return
	end

	_forEachTextLabel(innerFrame, function(child)
		child.TextScaled = true
		local labelSize = child.Size
		local shrinkSize = UDim2.new(labelSize.X.Scale, labelSize.X.Offset, 0, 0)
		_tweenSize(child, TipsConfig.TWEEN_TEXT_DURATION, shrinkSize)
	end)
end

--[[
	超出 MAX_SHOW_NUMBER 时按 LayoutOrder 回收最早提示（含正在收起的条）
	@return nil - 未超限时无操作
]]
local function _hideIfFull()
	local frameList: { Frame } = {}

	for frame in pairs(_frameToFingerprint) do
		table.insert(frameList, frame)
	end
	for frame in pairs(_hidingFrames) do
		table.insert(frameList, frame)
	end

	if #frameList <= TipsConfig.MAX_SHOW_NUMBER then
		return
	end

	table.sort(frameList, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)

	for i = 1, #frameList - TipsConfig.MAX_SHOW_NUMBER do
		_hideTween(frameList[i])
	end
end

-- ========================================
-- UI creation
-- ========================================

--[[
	按文本测量结果设置 TextLabel 宽度
	@param textLabel TextLabel - 已设置 Text / TextSize / Font 的标签
	@return nil - 无返回值
]]
local function _setTextSize(textLabel: TextLabel)
	local bounds: Vector2 = TextService:GetTextSize(
		textLabel.Text,
		textLabel.TextSize,
		textLabel.Font,
		TipsConfig.TEXT_BOUNDS
	)
	bounds = bounds + Vector2.new(1, 1)
	textLabel.Size = UDim2.new(0, bounds.X, textLabel.Size.Y.Scale, textLabel.TextSize)
end

--[[
	从对象池创建一条提示的背景条（含 UICorner、内部 UIListLayout）
	@return Frame? - 背景条实例；池模板缺失时 nil
]]
local function _createBgFrame(): Frame?
	local bgTemplate = TipsConfig.getPoolTemplate(TipsConfig.POOL_BG_TEMP)
	if not bgTemplate then
		return nil
	end

	local bgFrame: Frame = ObjectPoolUtil.getObjectFromPool(bgTemplate)
	if not bgFrame then
		return nil
	end

	bgFrame.Transparency = 1
	bgFrame.BackgroundColor3 = TipsConfig.STROKE_COLOR
	bgFrame.Size = UDim2.new(1, 0, TipsConfig.BG_HEIGHT_SCALE, 0)

	InsMgr.GetIns("UICorner", "UICorner", bgFrame)

	local contentFrame = _getContentFrame(bgFrame)
	if contentFrame then
		local uiList: UIListLayout = InsMgr.GetIns("UIListLayout", "UIListLayout", contentFrame)
		uiList.Padding = UDim.new(0, TipsConfig.LIST_PADDING_PX)
		uiList.HorizontalAlignment = Enum.HorizontalAlignment.Center
		uiList.VerticalAlignment = Enum.VerticalAlignment.Center
		uiList.FillDirection = Enum.FillDirection.Horizontal
	end

	return bgFrame
end

--[[
	从对象池创建单个文本段标签
	@param textData { [string]: any } - 文本段配置：Text、TextSize、Font、UIGradientString、UIStorke 等
	@return TextLabel? - 文本标签实例；池模板缺失时 nil
]]
local function _createText(textData: { [string]: any }): TextLabel?
	local textTemplate = TipsConfig.getPoolTemplate(TipsConfig.POOL_TEXT_TEMP)
	if not textTemplate then
		return nil
	end

	local textLabel: TextLabel = ObjectPoolUtil.getObjectFromPool(textTemplate)
	if not textLabel then
		return nil
	end

	textLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	textLabel.Text = textData.Text or ""
	textLabel.Font = textData.Font or TipsConfig.DEFAULT_FONT
	textLabel.TextScaled = false
	textLabel.TextWrapped = false
	textLabel.AutomaticSize = Enum.AutomaticSize.None
	textLabel.TextSize = textData.TextSize or TipsConfig.TEXT_SIZE_DEFAULT
	textLabel.BackgroundTransparency = 1

	local uiStroke: UIStroke = InsMgr.GetIns("UIStroke", "UIStroke", textLabel)
	if textData.UIStorke and textData.UIStorke > 0 then
		uiStroke.Thickness = textData.UIStorke or TipsConfig.DEFAULT_STROKE_THICKNESS
		uiStroke.Transparency = textData.UIStorkeTransparency or 0
		uiStroke.Color = textData.UIStorkeColor or TipsConfig.STROKE_COLOR
		uiStroke.Enabled = true
	else
		uiStroke.Enabled = false
	end

	if textData.UIGradientString then
		UIMgr.AddGradientColor(textData.UIGradientString, textLabel, true)
		local gradient = textLabel:FindFirstChildOfClass("UIGradient")
		if gradient then
			gradient.Enabled = true
		end
	else
		local gradient = textLabel:FindFirstChildOfClass("UIGradient")
		if gradient then
			gradient.Enabled = false
		end
	end

	return textLabel
end

--[[
	根据内容区 TextLabel 宽度之和调整背景条横向尺寸
	@param bgFrame Frame - 含 Frame 子节点与 TextLabel 的背景条
	@return nil - 无内容区时直接 return
]]
local function _setBackgroundSize(bgFrame: Frame)
	local contentFrame = _getContentFrame(bgFrame)
	if not contentFrame then
		return
	end

	local pixelWidth = 0
	_forEachTextLabel(contentFrame, function(child)
		pixelWidth += child.Size.X.Offset
	end)

	local originalSize = bgFrame.Size
	bgFrame.Size = UDim2.new(TipsConfig.BG_WIDTH_SCALE, pixelWidth, originalSize.Y.Scale, originalSize.Y.Offset)
end

--[[
	将内容区回收旧标签后写入单段展示文案（合并 xN 时用）
	@param bgFrame Frame - 背景条
	@param styleData { [string]: any } - 样式源（通常为首段配置）
	@param displayText string - 最终展示文案
	@return boolean - 成功写入为 true
]]
local function _setSingleSegmentContent(bgFrame: Frame, styleData: { [string]: any }, displayText: string): boolean
	local contentFrame = _getContentFrame(bgFrame)
	if not contentFrame then
		return false
	end

	local segment = {}
	for key, value in pairs(styleData) do
		segment[key] = value
	end
	segment.Text = displayText

	-- 先创建成功再回收旧标签，避免创建失败导致内容区被清空
	local textLabel = _createText(segment)
	if not textLabel then
		return false
	end

	_forEachTextLabel(contentFrame, function(child)
		ObjectPoolUtil.backToPool(child)
	end)

	_setTextSize(textLabel)
	textLabel.Parent = contentFrame
	textLabel.LayoutOrder = 1
	_setBackgroundSize(bgFrame)
	return true
end

--[[
	刷新该条的自动收起计时（重复到达时重置 DISPLAY_DURATION）
	@param entry ActiveTipEntry - 活跃合并条目
	@return nil - 无返回值
]]
local function _scheduleHide(entry: ActiveTipEntry)
	entry.hideToken += 1
	local token = entry.hideToken
	local bgFrame = entry.bgFrame

	task.delay(TipsConfig.DISPLAY_DURATION, function()
		if entry.hideToken ~= token then
			return
		end
		if bgFrame.Parent then
			_hideTween(bgFrame)
		end
	end)
end

--[[
	若存在仍在展示的同指纹 Tip，则累加次数、更新文案并刷新显示时长
	@param fingerprint string - 合并指纹
	@param baseText string - 原文案
	@param styleData { [string]: any } - 合并展示样式
	@return boolean - 已合并到已有条为 true；需新建为 false
]]
local function _tryStackExisting(fingerprint: string, baseText: string, styleData: { [string]: any }): boolean
	local entry = _activeTips[fingerprint]
	if not entry then
		return false
	end

	local bgFrame = entry.bgFrame
	if not bgFrame.Parent or _hidingFrames[bgFrame] then
		_activeTips[fingerprint] = nil
		_frameToFingerprint[bgFrame] = nil
		return false
	end

	entry.count += 1
	entry.baseText = baseText
	entry.styleData = styleData

	local displayText = _formatStackedText(entry.baseText, entry.count)
	if not _setSingleSegmentContent(bgFrame, styleData, displayText) then
		entry.count -= 1
		return false
	end

	_scheduleHide(entry)
	return true
end

--[[
	注册新建提示条到合并表并启动收起计时
	@param fingerprint string - 合并指纹
	@param baseText string - 原文案
	@param styleData { [string]: any } - 首段样式
	@param bgFrame Frame - 新建背景条
	@return nil - 无返回值
]]
local function _registerActiveTip(
	fingerprint: string,
	baseText: string,
	styleData: { [string]: any },
	bgFrame: Frame
)
	local entry: ActiveTipEntry = {
		fingerprint = fingerprint,
		baseText = baseText,
		count = 1,
		bgFrame = bgFrame,
		hideToken = 0,
		styleData = styleData,
	}
	_activeTips[fingerprint] = entry
	_frameToFingerprint[bgFrame] = fingerprint
	_scheduleHide(entry)
end

-- ========================================
-- Public API
-- ========================================

--[[
	创建并展示多段文本提示条；同内容仍在展示中则合并为「文案 xN」并刷新时长
	@param tipData {any} - 有序文本段配置数组，每项同 _createText 的 textData
	@return nil - PlayerGui 或池模板不可用时静默 return
]]
function TipsRenderer.createTip(tipData: { any })
	local tipsFrame = _getTipsFrame()
	if not tipsFrame then
		return
	end

	local fingerprint, baseText, styleData = _buildTipIdentity(tipData)
	if baseText ~= "" and _tryStackExisting(fingerprint, baseText, styleData) then
		return
	end

	local bgFrame = _createBgFrame()
	if not bgFrame then
		return
	end

	local contentFrame = _getContentFrame(bgFrame)
	if not contentFrame then
		ObjectPoolUtil.backToPool(bgFrame)
		return
	end

	_layoutIndex += 1
	bgFrame.LayoutOrder = _layoutIndex
	bgFrame.Parent = tipsFrame

	for index, textData in ipairs(tipData) do
		local textLabel = _createText(textData)
		if textLabel then
			_setTextSize(textLabel)
			textLabel.Parent = contentFrame
			textLabel.LayoutOrder = index
		end
	end

	_setBackgroundSize(bgFrame)
	_showTween(bgFrame)
	_hideIfFull()
	_registerActiveTip(fingerprint, baseText, styleData, bgFrame)
end

--[[
	套用 TipsConfig 模板创建单句提示
	@param text string - 展示文案（通常已翻译）
	@param templateName string - TipsConfig 模板名，如 TEMPLATE_NORMAL、TEMPLATE_ERROR
	@return nil - 模板名不存在时静默 return
]]
function TipsRenderer.templateTip(text: string, templateName: string)
	local templateCopy = TipsConfig.copyTemplate(templateName)
	if not templateCopy then
		return
	end

	templateCopy.Text = text
	TipsRenderer.createTip({ templateCopy })
end

--[[
	根据服务端下发的模板类型表构建并展示提示
	@param data { [string]: any } - 须含 Type；载具合成 / 获得奖励均须 ID，其余字段见 TipsTemplateBuilder
	@return nil - Type 未知或字段缺失时静默 return
]]
function TipsRenderer.showFromServerTemplate(data: { [string]: any })
	local tipData = TipsTemplateBuilder.buildFromServerData(data)
	if tipData then
		TipsRenderer.createTip(tipData)
	end
end

--[[
	释放客户端运行时状态：取消收起计时、清空合并表，并将仍挂载的条归还对象池
	@return nil - 可重复调用
]]
function TipsRenderer.destroy()
	for _, entry in pairs(_activeTips) do
		entry.hideToken += 1
	end

	local frames: { Frame } = {}
	for frame in pairs(_frameToFingerprint) do
		table.insert(frames, frame)
	end
	for frame in pairs(_hidingFrames) do
		table.insert(frames, frame)
	end

	table.clear(_activeTips)
	table.clear(_frameToFingerprint)
	table.clear(_hidingFrames)

	for _, frame in ipairs(frames) do
		local innerFrame = _getContentFrame(frame)
		if innerFrame then
			_forEachTextLabel(innerFrame, function(child)
				ObjectPoolUtil.backToPool(child)
			end)
		end
		ObjectPoolUtil.backToPool(frame)
	end

	_cachedTipsFrame = nil
	_isClientReady = false
	_localPlayer = nil
	_layoutIndex = 0
end

return TipsRenderer