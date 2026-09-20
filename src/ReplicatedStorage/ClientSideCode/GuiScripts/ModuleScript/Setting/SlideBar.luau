--[[
	Module: SlideBar
	Description: 设置页横向滑动条：全局同时仅一条拖拽会话，松手后经回调上送 SystemSet
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31

	功能：
	- Bind：把 NumberValue 映射到填充条 / 箭头 / NowValue 数字
	- 开始新拖拽会先清理上一段 Input 连接；结束后断开，避免串行
	- 处于 ScrollingFrame 内时拖拽期间暂时关闭列表滚动（减少与竖向手势冲突）
	- CancelActive：设置页关闭时强制结束拖拽并恢复滚动

	与 SettingRowBind：
	- 行绑定写入 SliderMin/Max/Step/LabelMode 后调用 Bind
	- 松手才 pushSetting；拖拽中忽略 NumberValue 回写，避免抖动

	加载：
	local SlideBar = require(script.SlideBar)
	SlideBar.Bind(barFolder, row, nv, pushSettingChange, showName)
	SlideBar.CancelActive()
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local UserInputService = Utils.UserInputService
local GuiService = Utils.GuiService
local AddListen = Utils.AddListen
local TranslationHelper = Utils.TranslationHelper

local SlideBar = {}

-- ========================================
-- 常量
-- ========================================
local DEFAULT_SLIDER_MIN = 0
local DEFAULT_SLIDER_MAX = 100
local DEFAULT_SLIDER_STEP = 1
local ALPHA_EPS = 1e-9
local SIZE_EPS = 1e-3

-- ========================================
-- 私有变量
-- ========================================
--- 当前全局拖拽清理（InputChanged + InputEnded）；仅存一段
local _activeCleanup: (() -> ())? = nil
--- 当前拖拽对应的「滑动条」容器，用于 Instance 销毁时只取消本会话
local _activeBarFolder: Frame? = nil

-- ========================================
-- 私有函数
-- ========================================

--[[
	结束当前拖拽会话（若有）
	@return nil - 无返回值
]]
local function _runActiveCleanup()
	local cleanup = _activeCleanup
	_activeCleanup = nil
	_activeBarFolder = nil
	if cleanup then
		cleanup()
	end
end

--[[
	读取实例数值 Attribute，缺省或类型不对时用 default
	@param inst Instance - 带 Attribute 的滑动条容器或行
	@param name string - Attribute 名
	@param default number - 非 number 时的回退值
	@return number - Attribute 或 default
]]
local function _readAttrNum(inst: Instance, name: string, default: number): number
	local attr = inst:GetAttribute(name)
	if type(attr) == "number" then
		return attr
	end
	return default
end

--[[
	把值钳制到 [minV, maxV] 并按 step 四舍五入
	@param v number - 原始值
	@param minV number - 下限
	@param maxV number - 上限
	@param stepV number - 步长；<=0 时只钳制不吸附
	@return number - 吸附后的值
]]
local function _snapToStep(v: number, minV: number, maxV: number, stepV: number): number
	v = math.clamp(v, minV, maxV)
	if stepV <= 0 then
		return v
	end
	local n = math.floor((v - minV) / stepV + 0.5)
	return math.clamp(minV + n * stepV, minV, maxV)
end

--[[
	读取滑动条 min/max/step（max<min 时对调）
	@param barFolder Frame - 「滑动条」容器
	@return number - 下限
	@return number - 上限
	@return number - 步长
]]
local function _getRange(barFolder: Frame): (number, number, number)
	local minV = _readAttrNum(barFolder, "SliderMin", DEFAULT_SLIDER_MIN)
	local maxV = _readAttrNum(barFolder, "SliderMax", DEFAULT_SLIDER_MAX)
	if maxV < minV then
		minV, maxV = maxV, minV
	end
	return minV, maxV, _readAttrNum(barFolder, "SliderStep", DEFAULT_SLIDER_STEP)
end

--[[
	把存盘值映射为 0~1 填充比例
	@param val number - 当前值
	@param minV number - 下限
	@param maxV number - 上限
	@return number - 0~1；跨度过小时返回 0
]]
local function _valueToAlpha(val: number, minV: number, maxV: number): number
	local span = maxV - minV
	if span <= ALPHA_EPS then
		return 0
	end
	return math.clamp((val - minV) / span, 0, 1)
end

--[[
	把 0~1 比例映射回吸附后的存盘值
	@param barFolder Frame - 「滑动条」容器
	@param alpha number - 0~1
	@return number - 吸附后的值
]]
local function _alphaToValue(barFolder: Frame, alpha: number): number
	local minV, maxV, stepV = _getRange(barFolder)
	return _snapToStep(minV + alpha * (maxV - minV), minV, maxV, stepV)
end

--[[
	NowValue 展示串（百分比加 %，其余取整）
	@param barFolder Frame - 可读 SliderLabelMode
	@param row Frame - 可读 SliderIsPercent
	@param v number - 当前值
	@return string - 纯数字或带 % 的展示串
]]
local function _formatLabel(barFolder: Frame, row: Frame, v: number): string
	local rounded = tostring(math.floor(v + 0.5))
	if row:GetAttribute("SliderIsPercent") == true then
		return rounded .. "%"
	end
	return rounded
end

--[[
	按当前值刷新填充条、箭头和数字标签
	@param barFolder Frame - 「滑动条」容器
	@param thumb GuiObject - 箭头
	@param barFill Frame? - 填充条；nil 时不改 Size
	@param nowLbl TextLabel? - 数字标签；nil 时不写
	@param row Frame - 行（百分比 Attribute）
	@param val number - 当前值
	@return nil - 无返回值
]]
local function _applyVisual(
	barFolder: Frame,
	thumb: GuiObject,
	barFill: Frame?,
	nowLbl: TextLabel?,
	row: Frame,
	val: number
)
	local minV, maxV, _step = _getRange(barFolder)
	local alpha = _valueToAlpha(val, minV, maxV)
	if barFill then
		local sy = barFill.Size.Y
		barFill.Size = UDim2.new(alpha, 0, sy.Scale, sy.Offset)
	end
	local px = thumb.Position
	thumb.Position = UDim2.new(alpha, px.X.Offset, px.Y.Scale, px.Y.Offset)
	if nowLbl then
		TranslationHelper.SetRawText(nowLbl, _formatLabel(barFolder, row, val))
	end
end

--[[
	屏幕 X 映射为条上 0~1
	@param barFolder Frame - 「滑动条」容器
	@param screenX number - GUI 坐标系 X
	@return number - 0~1；宽度过小时返回 0
]]
local function _alphaFromScreenX(barFolder: Frame, screenX: number): number
	local pos = barFolder.AbsolutePosition
	local size = barFolder.AbsoluteSize
	if size.X <= SIZE_EPS then
		return 0
	end
	return math.clamp((screenX - pos.X) / size.X, 0, 1)
end

--[[
	从 InputObject 取 GUI 坐标系 X（Touch 的 Position 为 Vector3，不能直接减 Inset）
	@param input InputObject - 当前触点或鼠标
	@return number - GUI 坐标系 X
]]
local function _guiScreenXFromInputObject(input: InputObject): number
	local inset = GuiService:GetGuiInset()
	if input.UserInputType == Enum.UserInputType.Touch then
		return input.Position.X - inset.X
	end
	return (UserInputService:GetMouseLocation() - inset).X
end

--[[
	拖拽中取屏幕 X；无 activeInput 时用鼠标
	@param activeInput InputObject? - 当前触点；nil 用鼠标位置
	@return number - GUI 坐标系 X
]]
local function _pickScreenXForDrag(activeInput: InputObject?): number
	if not activeInput then
		return (UserInputService:GetMouseLocation() - GuiService:GetGuiInset()).X
	end
	return _guiScreenXFromInputObject(activeInput)
end

--[[
	是否处理本次 InputChanged（Touch 只跟发起触点；鼠标跟 MouseMovement）
	@param originInput InputObject? - 开始拖拽的输入；nil 时认鼠标移动或任意 Touch
	@param input InputObject - Changed 事件输入
	@return boolean - 是否更新视觉
]]
local function _shouldHandleMove(originInput: InputObject?, input: InputObject): boolean
	if not originInput then
		return input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch
	end
	if originInput.UserInputType == Enum.UserInputType.Touch then
		return input.UserInputType == Enum.UserInputType.Touch and input == originInput
	end
	if originInput.UserInputType == Enum.UserInputType.MouseButton1 then
		return input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Gamepad1
	end
	return false
end

--[[
	本次 InputEnded 是否对应当前拖拽（鼠标左键 / 同触点 / 手柄 A）
	@param originInput InputObject? - 开始拖拽的输入
	@param input InputObject - Ended 事件输入
	@return boolean - 是否结束会话并上送
]]
local function _isDragEndInput(originInput: InputObject?, input: InputObject): boolean
	if input.UserInputType == Enum.UserInputType.Gamepad1 then
		return input.KeyCode == Enum.KeyCode.ButtonA
	end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
		return false
	end
	if originInput and input.UserInputType == Enum.UserInputType.Touch then
		return input == originInput
	end
	return true
end

--[[
	开始一条全局拖拽会话（先清上一段）；松手后 apply + pushSetting
	@param barFolder Frame - 「滑动条」容器
	@param originInput InputObject? - 发起拖拽的输入
	@param showName string - settingConf.ShowName
	@param pushSetting (string, number) -> () - 松手上送
	@param apply (number) -> () - 刷新视觉
	@param dragState { dragging: boolean } - 与 NumValue 回写互斥
	@return nil - 无返回值
]]
local function _beginDragSession(
	barFolder: Frame,
	originInput: InputObject?,
	showName: string,
	pushSetting: (string, number) -> (),
	apply: (number) -> (),
	dragState: { dragging: boolean }
)
	_runActiveCleanup()
	dragState.dragging = true
	_activeBarFolder = barFolder

	local moveConn: RBXScriptConnection?
	local endConn: RBXScriptConnection?
	local ended = false

	local scrollHost = barFolder:FindFirstAncestorWhichIsA("ScrollingFrame")
	local scrollWasEnabled = false
	if scrollHost and scrollHost.ScrollingEnabled then
		scrollWasEnabled = true
		scrollHost.ScrollingEnabled = false
	end

	local function restoreScrollIfNeeded()
		if scrollHost and scrollWasEnabled then
			scrollHost.ScrollingEnabled = true
			scrollWasEnabled = false
		end
	end

	local function disconnectOnly()
		if ended then
			return
		end
		ended = true
		dragState.dragging = false
		restoreScrollIfNeeded()
		if moveConn and moveConn.Connected then
			moveConn:Disconnect()
		end
		if endConn and endConn.Connected then
			endConn:Disconnect()
		end
		_activeCleanup = nil
		_activeBarFolder = nil
	end

	if originInput then
		apply(_alphaToValue(barFolder, _alphaFromScreenX(barFolder, _pickScreenXForDrag(originInput))))
	end

	moveConn = UserInputService.InputChanged:Connect(function(input: InputObject, _processed: boolean)
		if not _shouldHandleMove(originInput, input) then
			return
		end
		apply(_alphaToValue(barFolder, _alphaFromScreenX(barFolder, _pickScreenXForDrag(input))))
	end)

	endConn = UserInputService.InputEnded:Connect(function(input: InputObject, _gameProcessed: boolean)
		if ended or not _isDragEndInput(originInput, input) then
			return
		end
		local ax = _guiScreenXFromInputObject(input)
		local val = _alphaToValue(barFolder, _alphaFromScreenX(barFolder, ax))
		apply(val)
		disconnectOnly()
		pushSetting(showName, val)
	end)

	_activeCleanup = disconnectOnly
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	强制结束当前拖拽（设置页关闭时调用，避免松手监听残留）
	@return nil - 无返回值
]]
function SlideBar.CancelActive()
	_runActiveCleanup()
end

--[[
	把一行滑动条绑到 NumberValue；松手时调用 pushSetting
	@param barFolder Frame - 「滑动条」容器（含 Bar / 箭头）
	@param row Frame - 设置行（NowValue、SliderIsPercent）
	@param nv NumberValue - player.Setting 下对应项
	@param pushSetting (string, number) -> () - 上送 showName 与新值
	@param showName string - settingConf.ShowName
	@return nil - 无箭头时静默 return；不写存档本身
]]
function SlideBar.Bind(
	barFolder: Frame,
	row: Frame,
	nv: NumberValue,
	pushSetting: (string, number) -> (),
	showName: string
)
	local barFill = barFolder:FindFirstChild("Bar") :: Frame?
	local thumb = barFolder:FindFirstChild("箭头") :: GuiObject?
	local nowLbl = row:FindFirstChild("NowValue") :: TextLabel?
	if not thumb then
		return
	end

	local dragState = { dragging = false }

	local function apply(val: number)
		_applyVisual(barFolder, thumb, barFill, nowLbl, row, val)
	end

	AddListen.NumValueAdd(nv, function(n: number)
		if dragState.dragging then
			return
		end
		apply(n)
	end)

	thumb.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			_beginDragSession(barFolder, input, showName, pushSetting, apply, dragState)
		end
	end)

	if barFill and barFill:IsA("GuiObject") then
		barFill.InputBegan:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				_beginDragSession(barFolder, input, showName, pushSetting, apply, dragState)
			end
		end)
	end

	barFolder.Destroying:Connect(function()
		if _activeBarFolder == barFolder then
			_runActiveCleanup()
		end
	end)
end

return SlideBar
