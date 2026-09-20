--[[
	Module: Feedback
	Description: 反馈弹窗——文本校验、CD 提示与 Remote 提交
	Author: 林奥宇
	Created: 2026-01-29
	Last Modified: 2026-09-01

	功能：
	- updateUi：预留接口，UIManager 打开前可调用
	- openUi / closeUi：主 UI 显隐与输入框占位初始化
	- 提交：NetWork.InvokeServer(NetMsg.SUBMIT_FEEDBACK, comment)，只认返回值 == true

	模块关系：
	- 展示、字数/CD 预检与发 Remote；结算权威在 SystemFeedback（校验 → Webhook → 写 reportTime）
	- 由 UIManager 按 Frame.Name 动态 require，调用 updateUi / openUi / closeUi
	- 顶栏入口 TopBarManager；CD 读 SystemGameConfig.Feedback「反馈CD分钟」
	- Player 下 reportTime NumberValue 由 SystemSave 同步，本模块只读

	约定：
	- ScreenGui 下须存在 Feedback Frame
	- 字数上下限与服务端 SystemFeedback 一致（UTF-8 字符，提交前去首尾空白）
	- Tips / 占位 Key 必须是调用处字面量（反馈文本不得少于多少 / 不得多余多少 / 反馈CD中 / 感谢你的反馈 / 反馈提交失败 / 请在这输入反馈）

	加载（UIManager 动态 require）：
		local Feedback = require(...ModuleScript.Feedback)
		Feedback:updateUi()
		Feedback:openUi()
]]

-- ========================================
-- 服务引用
-- ========================================
local Workspace = game:GetService("Workspace")

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local MathMgr = Utils.MathMgr
local AddListen = Utils.AddListen
local TipsModule = Utils.TipsModule
local TranslationHelper = Utils.TranslationHelper
local UIanima = Utils.UIanima
local UIMgr = Utils.UIMgr
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local LocalPlayer = Utils.LocalPlayer
local SystemGameConfig = Utils.SystemGameConfig
local Log = Utils.Log

-- ========================================
-- 模块定义
-- ========================================
local Feedback = {}

-- ========================================
-- 常量定义
-- ========================================
local MIN_TEXT_LENGTH = 20
local MAX_TEXT_LENGTH = 256
local SECONDS_PER_MINUTE = 60
local WAIT_CHILD_TIMEOUT = math.huge
local STAT_KEY_REPORT_TIME = "reportTime"
local CONFIG_CD_MINUTES_PATH = { "Feedback", "反馈CD分钟" }
local COLOR_COUNT_INVALID = Color3.new(1, 0, 0)
local COLOR_COUNT_VALID = Color3.new(0, 1, 0)

-- ========================================
-- 私有变量
-- ========================================
local _playerGui = LocalPlayer:WaitForChild("PlayerGui", WAIT_CHILD_TIMEOUT)
local _screenGui = _playerGui:WaitForChild("ScreenGui", WAIT_CHILD_TIMEOUT)
local _feedbackUI: Frame = _screenGui:WaitForChild("Feedback", WAIT_CHILD_TIMEOUT) :: Frame
local _frame: Frame = _feedbackUI:WaitForChild("Frame") :: Frame
local _inputBox: TextBox = _frame.Code.Input.Box
local _btnSubmit: GuiButton = _frame.Code.Button
local _waiting: GuiObject = _frame.Code.Waiting
local _btnClose: ImageButton = _feedbackUI.BG.Exit.Button
local _charCountText: TextLabel = _frame.Code.Input["字数"]

local _reportCdMinutes: number = SystemGameConfig.GetValue(CONFIG_CD_MINUTES_PATH) or 0
local _reportCdSeconds: number = _reportCdMinutes * SECONDS_PER_MINUTE
local _isSubmitting = false

-- ========================================
-- 私有函数
-- ========================================

--[[
	去掉字符串首尾空白
	@param text string - 原始字符串
	@return string - 去空白后的字符串
]]
local function _trimText(text: string): string
	return (string.gsub(text, "^%s*(.-)%s*$", "%1"))
end

--[[
	从 Player 下 reportTime NumberValue 读取上次反馈 Unix 时间戳
	@return number - 上次反馈时间戳；无实例时为 0
]]
local function _getReportTime(): number
	local reportTimeValue: NumberValue? = LocalPlayer:FindFirstChild(STAT_KEY_REPORT_TIME) :: NumberValue?
	if reportTimeValue then
		return reportTimeValue.Value
	end
	return 0
end

--[[
	按 UTF-8 计算文本字符数
	@param text string - 待计数字符串
	@return number - 字符数
]]
local function _utf8CharCount(text: string): number
	return utf8.len(text) or 0
end

--[[
	读取输入框去空白后的正文
	@return string - 去首尾空白后的输入
]]
local function _getTrimmedInput(): string
	return _trimText(_inputBox.Text)
end

--[[
	刷新输入框字数显示与颜色
	@return nil - 无返回值
]]
local function _refreshCharCount()
	local inputLength = _utf8CharCount(_getTrimmedInput())
	TranslationHelper.SetRawText(_charCountText, "(" .. inputLength .. "/" .. MAX_TEXT_LENGTH .. ")")
	if inputLength < MIN_TEXT_LENGTH or inputLength > MAX_TEXT_LENGTH then
		_charCountText.TextColor3 = COLOR_COUNT_INVALID
	else
		_charCountText.TextColor3 = COLOR_COUNT_VALID
	end
end

--[[
	检查是否在 CD 中
	@return boolean - 是否在 CD 中
	@return number? - 在 CD 时为剩余秒数；否则为 nil
]]
local function _checkCooldown(): (boolean, number?)
	local currentTime = Workspace:GetServerTimeNow()
	local timeSinceLastReport = currentTime - _getReportTime()
	local remainingCD = _reportCdSeconds - timeSinceLastReport
	if remainingCD > 0 then
		return true, remainingCD
	end
	return false, nil
end

--[[
	提交反馈到服务器
	@return nil - 无返回值
]]
local function _submitFeedback()
	local inCooldown, remainingCD = _checkCooldown()
	if inCooldown then
		local remainingMinutes = MathMgr.getNumStr0(math.abs((remainingCD or 0) / SECONDS_PER_MINUTE))
		TipsModule.showTips(LocalPlayer, "反馈CD中", { remainingMinutes })
		return
	end

	local comment = _getTrimmedInput()
	local inputLength = _utf8CharCount(comment)
	if inputLength < MIN_TEXT_LENGTH then
		TipsModule.showTips(LocalPlayer, "反馈文本不得少于多少", { MathMgr.getNumStr(MIN_TEXT_LENGTH) })
		return
	end
	if inputLength > MAX_TEXT_LENGTH then
		TipsModule.showTips(LocalPlayer, "反馈文本不得多余多少", { MathMgr.getNumStr(MAX_TEXT_LENGTH) })
		return
	end

	if _isSubmitting then
		return
	end

	_waiting.Visible = true
	_btnSubmit.Visible = false
	_isSubmitting = true

	local success = NetWork.InvokeServer(NetMsg.SUBMIT_FEEDBACK, comment) == true

	if success then
		TipsModule.showTips(LocalPlayer, "感谢你的反馈")
		TranslationHelper.SetRawText(_inputBox, "")
		_refreshCharCount()
	else
		Log.warn("Feedback: 提交失败")
		TipsModule.showTips(LocalPlayer, "反馈提交失败")
	end

	_isSubmitting = false
	_btnSubmit.Visible = true
	_waiting.Visible = false
end

-- ========================================
-- 事件绑定
-- ========================================
AddListen.AddMouseCLick(_btnClose, function()
	Feedback:closeUi()
end, _btnClose)

_inputBox:GetPropertyChangedSignal("Text"):Connect(_refreshCharCount)

AddListen.AddMouseCLick(_btnSubmit, function()
	_submitFeedback()
end, _btnSubmit)

_btnSubmit.Visible = true
_waiting.Visible = false

-- ========================================
-- 公共 API
-- ========================================

--[[
	更新 UI（预留接口，UIManager 打开前可调用）
	@return nil - 无返回值
]]
function Feedback:updateUi()
end

--[[
	打开反馈窗口
	@return nil - 无返回值
]]
function Feedback:openUi()
	UIMgr.SetMainUIVisible(false)
	TranslationHelper.SetText(_inputBox, "请在这输入反馈")
	_refreshCharCount()
end

--[[
	关闭反馈窗口
	@return nil - 无返回值
]]
function Feedback:closeUi()
	UIMgr.SetMainUIVisible(true)
	UIanima.PopBack(_feedbackUI)
end

return Feedback
