--[[
	Module: InitMain
	Description: Main 界面左右侧窗口按钮点击绑定，默认经 SHOW_LOCAL_UI 打开对应弹窗
	Author: 林奥宇
	Created: 2026-01-16
	Last Modified: 2026-08-31

	功能：
	- 在 Main.Left.Window / Main.Right.Window 下查找按钮 Frame
	- 绑定 ImageButton 点击，打开 ScreenGui 同名弹窗（UIManager 路由）

	约定：
	- 本文件为 StarterPlayerScripts LocalScript，启动即绑定；无 Init() / 模块表
	- 按钮 Frame 须含子级 Button（ImageButton）与 Frame（点击背景）
	- 项目接入时在底部取消注释并填写 buttonName / windowName
	- 不写存档、不结算奖励、不绑定业务 Remote

	加载方式：
		本脚本由 StarterPlayer 自动运行，无需 require

	示例：
	_bindWindow("商店", "RuboxShop", nil)
	_bindWindow("设置", "Setting", function()
		-- 自定义逻辑
	end)
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local AddListen = Utils.AddListen
local LocalPlayer = Utils.LocalPlayer
local Log = Utils.Log
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork

-- ========================================
-- 私有变量
-- ========================================
local _playerGui: PlayerGui = LocalPlayer:WaitForChild("PlayerGui", math.huge) :: PlayerGui
local _screenGui: ScreenGui = _playerGui:WaitForChild("ScreenGui", math.huge) :: ScreenGui
local _main: Frame = _screenGui:WaitForChild("Main", math.huge) :: Frame
local _leftWindow: Frame = _main.Left.Window
local _rightWindow: Frame = _main.Right.Window

-- ========================================
-- 私有函数
-- ========================================

--[[
	绑定左右窗口区按钮点击打开 UI
	@param buttonName string - 按钮 Frame.Name，在 Left/Right.Window 下查找
	@param windowName string - ScreenGui 弹窗 Frame.Name，对应 GuiScripts ModuleScript
	@param callback (() -> ())? - 自定义点击逻辑；nil 时 FireBindable SHOW_LOCAL_UI
	@return nil - 按钮结构不完整时 Log.warn 并 return
]]
local function _bindWindow(buttonName: string, windowName: string, callback: (() -> ())?)
	local buttonFrame: Frame? = _leftWindow:FindFirstChild(buttonName) :: Frame?
	if not buttonFrame or not buttonFrame:IsA("Frame") then
		buttonFrame = _rightWindow:FindFirstChild(buttonName) :: Frame?
	end
	if not buttonFrame or not buttonFrame:IsA("Frame") then
		Log.warn("[InitMain] 窗口按钮不存在", buttonName)
		return
	end

	local button = buttonFrame:FindFirstChild("Button")
	local background = buttonFrame:FindFirstChild("Frame")
	if not button or not button:IsA("ImageButton") then
		Log.warn("[InitMain] 窗口 Button 不存在", buttonName)
		return
	end
	if not background or not background:IsA("Frame") then
		Log.warn("[InitMain] 窗口 Frame 不存在", buttonName)
		return
	end

	local onClick = function()
		if callback then
			callback()
		else
			NetWork.FireBindable(NetMsg.SHOW_LOCAL_UI, windowName, nil, true, true)
		end
	end

	AddListen.AddMouseClick(button, onClick, background)
end

-- ========================================
-- 初始化（按项目取消注释）
-- ========================================
-- _bindWindow("商店", "RuboxShop", nil)
-- _bindWindow("设置", "Setting", nil)
