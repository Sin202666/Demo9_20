--!strict
--[[
	Module: AddListen
	Description: 客户端 UI / Value 事件绑定工具（点击、悬停、数值监听、通行证显隐）
	Author: 林奥宇
	Created: 2026-01-19
	Last Modified: 2026-09-04

	功能：
	- NumValueAdd：监听 ValueBase（NumberValue / StringValue 等）变化，注册时立即回调当前值
	- AddMouseClick：绑定 GuiButton 点击（按下缩放动画 + 点击音效）；抬起还原走 InputEnded，指针离开后再松开也会恢复；AddMouseCLick 为历史拼写别名
	- AddMouseHover：按当前是否有鼠标选择 Enter/Leave 或触屏 Down/Up
	- EnableByGamePass：按玩家 GamePass 文件夹下 NumberValue 切换 GuiObject.Visible
	- DisconnectAll / RemoveMouseClick：断开连接数组

	模块关系：
	- 由 GuiScripts / UIMgr / Manager 在客户端调用；不含服务端权威逻辑
	- 点击缩放委托 UIanima.ButtonDown / ButtonUp；点击音效委托 SoundModule.PlaySoundLocal
	- 不替代 SystemInput（玩家角色输入）；本模块只绑 UI 与 Value 实例

	端侧 / 调用约束：
	- 面向客户端 UI；EnableByGamePass 会 WaitForChild，最长 30 秒，禁止在 Heartbeat 热路径调用
	- 调用方负责在界面销毁时 Disconnect 返回的连接（或交给 DisconnectAll）
	- 按钮 Attribute ClickSound（string）可覆盖默认点击音；非 string 时走默认音

	加载方式：
		local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
		local AddListen = Utils.AddListen

	使用示例：
		-- 数值变化（注册时立即以当前值回调一次）
		local conn = AddListen.NumValueAdd(someNumberValue, function(value)
			label.Text = tostring(value)
		end)

		-- 点击；第三参为按下缩放目标（省略则只播音+回调）
		local clickConns = AddListen.AddMouseClick(btn, function()
			-- 打开面板
		end, btn)

		-- 悬停详情
		local hoverConns = AddListen.AddMouseHover(btn, onEnter, onLeave)

		-- 销毁时
		AddListen.DisconnectAll(clickConns)
		if conn then
			conn:Disconnect()
		end
]]

-- ============================================================================
-- 模块引用
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local UserInputService = Utils.UserInputService
local SoundModule = Utils.SoundModule
local UIanima = Utils.UIanima
local Log = Utils.Log

-- ============================================================================
-- 模块定义
-- ============================================================================

local AddListen = {}

-- ============================================================================
-- 常量
-- ============================================================================

local ATTR_CLICK_SOUND = "ClickSound"
local ATTR_MOUSE_DOWN = "MouseDown"
local MOUSE_DOWN_PRESSED = 1
local DEFAULT_UI_CLICK_SOUND = "音效-UI-通用中度点击"
local GAME_PASS_FOLDER_NAME = "GamePass"
local PLAYER_CHILD_WAIT_TIMEOUT = 30
local INPUT_MOUSE_LEFT = Enum.UserInputType.MouseButton1
local INPUT_TOUCH = Enum.UserInputType.Touch

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	根据通行证 Tag 数值更新 GuiObject 显示状态
	@param frame GuiObject - 待控制的 UI 节点
	@param tagValue NumberValue - 通行证标记数值，>= 1 表示已拥有
	@param showWhenOwned boolean - true 时拥有则显示，false 时拥有则隐藏
	@return nil - 无返回值
]]
local function _updateFrameVisibleByPass(frame: GuiObject, tagValue: NumberValue, showWhenOwned: boolean)
	if tagValue.Value >= 1 then
		frame.Visible = showWhenOwned
	else
		frame.Visible = not showWhenOwned
	end
end

--[[
	播放按钮点击音效：Attribute ClickSound 为非空 string 时用该名，否则用默认 UI 点击音
	@param btn GuiButton - 被点击的按钮
	@return nil - 无返回值
]]
local function _playClickSound(btn: GuiButton)
	local clickSound = btn:GetAttribute(ATTR_CLICK_SOUND)
	local soundName = DEFAULT_UI_CLICK_SOUND
	if typeof(clickSound) == "string" and clickSound ~= "" then
		soundName = clickSound
	end
	SoundModule:PlaySoundLocal({ SoundName = soundName })
end

--[[
	若处于按下缩放态则播放抬起动画并清除标记。
	MouseButton1Up 仅在指针仍停在按钮上时触发；松开时已离开则不会还原，故抬起还需走 InputEnded。
	@param scaleTarget GuiObject - 缩放目标
	@return nil - 无返回值
]]
local function _restoreButtonScaleIfPressed(scaleTarget: GuiObject)
	if not scaleTarget.Parent then
		return
	end
	if scaleTarget:GetAttribute(ATTR_MOUSE_DOWN) ~= MOUSE_DOWN_PRESSED then
		return
	end
	scaleTarget:SetAttribute(ATTR_MOUSE_DOWN, nil)
	UIanima.ButtonUp(scaleTarget)
end

-- ============================================================================
-- 公共函数
-- ============================================================================

--[[
	监听 ValueBase 的 Value 变化（NumberValue / StringValue / BoolValue 等）
	注册时立即以当前 Value 回调一次，随后在 Changed 时回调。
	函数名保留 NumValueAdd 以兼容既有调用。

	@param valueObject ValueBase - 任意带 Value/Changed 的值对象
	@param listen (value: any) -> () - 变化回调；参数类型随 ValueBase 子类变化（number / string / boolean 等）
	@return RBXScriptConnection? - 变化监听连接；参数无效时返回 nil
]]
function AddListen.NumValueAdd(valueObject: ValueBase, listen: (value: any) -> ()): RBXScriptConnection?
	if typeof(valueObject) ~= "Instance" or not valueObject:IsA("ValueBase") then
		Log.warn("NumValueAdd: valueObject 无效")
		return nil
	end
	if typeof(listen) ~= "function" then
		Log.warn("NumValueAdd: listen 不是函数")
		return nil
	end

	listen(valueObject.Value)
	return valueObject.Changed:Connect(listen)
end

--[[
	为 GuiButton 添加点击监听：Down 可选缩放动画，抬起（含指针已离开）还原，Click 播放音效并执行回调
	新代码请用本函数；AddMouseCLick 为历史拼写别名，行为相同。

	@param btn GuiButton - ImageButton 或 TextButton
	@param callback () -> () - 点击回调；在音效之后调用
	@param scaleBtn GuiObject? - 缩放目标；nil 时不播放按下/抬起动画，也不写 MouseDown Attribute
	@return {RBXScriptConnection} - Down/Up/Click 连接；传入 scaleBtn 时额外含 InputEnded；参数无效时返回空表
]]
function AddListen.AddMouseClick(btn: GuiButton, callback: () -> (), scaleBtn: GuiObject?): { RBXScriptConnection }
	if typeof(btn) ~= "Instance" or not btn:IsA("GuiButton") then
		Log.warn("AddMouseClick: btn 不是 GuiButton")
		return {}
	end
	if typeof(callback) ~= "function" then
		Log.warn("AddMouseClick: callback 不是函数")
		return {}
	end
	if scaleBtn ~= nil and (typeof(scaleBtn) ~= "Instance" or not scaleBtn:IsA("GuiObject")) then
		Log.warn("AddMouseClick: scaleBtn 不是 GuiObject，已忽略缩放")
		scaleBtn = nil
	end

	local eventVt: { RBXScriptConnection } = {}
	local scaleTarget = scaleBtn

	eventVt[#eventVt + 1] = btn.MouseButton1Down:Connect(function()
		if not scaleTarget then
			return
		end
		scaleTarget:SetAttribute(ATTR_MOUSE_DOWN, MOUSE_DOWN_PRESSED)
		UIanima.ButtonDown(scaleTarget)
	end)

	eventVt[#eventVt + 1] = btn.MouseButton1Up:Connect(function()
		if not scaleTarget then
			return
		end
		_restoreButtonScaleIfPressed(scaleTarget)
	end)

	-- MouseButton1Up 在松开时指针已离开按钮则不触发，用全局抬起补还原
	if scaleTarget then
		local pressedTarget = scaleTarget
		eventVt[#eventVt + 1] = UserInputService.InputEnded:Connect(function(input: InputObject)
			local inputType = input.UserInputType
			if inputType ~= INPUT_MOUSE_LEFT and inputType ~= INPUT_TOUCH then
				return
			end
			_restoreButtonScaleIfPressed(pressedTarget)
		end)
	end

	eventVt[#eventVt + 1] = btn.MouseButton1Click:Connect(function()
		_playClickSound(btn)
		callback()
	end)

	return eventVt
end

-- 历史拼写：大量 GuiScripts 仍调用 AddMouseCLick
AddListen.AddMouseCLick = AddListen.AddMouseClick

--[[
	断开连接数组中的全部监听并清空表项
	@param connections {RBXScriptConnection}? - 连接对象数组；nil 或非表时直接返回
	@return nil - 无返回值
]]
function AddListen.DisconnectAll(connections: { RBXScriptConnection }?)
	if typeof(connections) ~= "table" then
		return
	end

	for key, conn in pairs(connections) do
		if conn and conn.Connected then
			conn:Disconnect()
		end
		connections[key] = nil
	end
end

--[[
	移除鼠标点击监听（DisconnectAll 的语义别名，兼容旧调用）
	@param connections {RBXScriptConnection}? - AddMouseClick 返回的连接数组
	@return nil - 无返回值
]]
function AddListen.RemoveMouseClick(connections: { RBXScriptConnection }?)
	AddListen.DisconnectAll(connections)
end

--[[
	按玩家 GamePass 文件夹下的 NumberValue 切换 UI 可见性
	本函数会 WaitForChild，最长 PLAYER_CHILD_WAIT_TIMEOUT 秒，禁止在热路径调用。

	@param plr Player - 玩家对象（通常为 LocalPlayer）
	@param frame GuiObject - 待切换 Visible 的节点
	@param tag string - GamePass 文件夹下 NumberValue 子节点名称
	@param isFade boolean - true：拥有（Value>=1）则显示；false：拥有则隐藏
	@return RBXScriptConnection? - 数值监听连接；参数无效、等待超时或节点类型不符时返回 nil
]]
function AddListen.EnableByGamePass(plr: Player, frame: GuiObject, tag: string, isFade: boolean): RBXScriptConnection?
	if typeof(plr) ~= "Instance" or not plr:IsA("Player") then
		Log.warn("EnableByGamePass: plr 不是 Player")
		return nil
	end
	if typeof(frame) ~= "Instance" or not frame:IsA("GuiObject") then
		Log.warn("EnableByGamePass: frame 不是 GuiObject")
		return nil
	end
	if typeof(tag) ~= "string" or tag == "" then
		Log.warn("EnableByGamePass: tag 无效")
		return nil
	end

	local gamePass = plr:WaitForChild(GAME_PASS_FOLDER_NAME, PLAYER_CHILD_WAIT_TIMEOUT)
	if not gamePass or not gamePass:IsA("Folder") then
		Log.warn("EnableByGamePass: GamePass 文件夹等待超时或无效", plr.Name)
		return nil
	end

	local tagValue = gamePass:WaitForChild(tag, PLAYER_CHILD_WAIT_TIMEOUT)
	if not tagValue or not tagValue:IsA("NumberValue") then
		Log.warn("EnableByGamePass: 通行证 Tag 等待超时或无效", plr.Name, tag)
		return nil
	end

	return AddListen.NumValueAdd(tagValue, function()
		_updateFrameVisibleByPass(frame, tagValue, isFade == true)
	end)
end

--[[
	添加鼠标悬停监听
	绑定时读取 UserInputService.MouseEnabled：有鼠标用 Enter/Leave；
	触屏用 Down 进入、Up 与 Leave 离开（离开回调去重，避免 Up+Leave 连打两次）。

	@param btn GuiButton - ImageButton 或 TextButton
	@param onEnter () -> () - 进入（或触屏按下）回调
	@param onLeave () -> () - 离开（或触屏抬起）回调
	@return {RBXScriptConnection} - 连接数组（鼠标 2 条，触屏 3 条）；参数无效时返回空表
]]
function AddListen.AddMouseHover(btn: GuiButton, onEnter: () -> (), onLeave: () -> ()): { RBXScriptConnection }
	if typeof(btn) ~= "Instance" or not btn:IsA("GuiButton") then
		Log.warn("AddMouseHover: btn 不是 GuiButton")
		return {}
	end
	if typeof(onEnter) ~= "function" or typeof(onLeave) ~= "function" then
		Log.warn("AddMouseHover: onEnter/onLeave 不是函数")
		return {}
	end

	local eventVt: { RBXScriptConnection } = {}

	if UserInputService.MouseEnabled then
		table.insert(eventVt, btn.MouseEnter:Connect(onEnter))
		table.insert(eventVt, btn.MouseLeave:Connect(onLeave))
		return eventVt
	end

	local isInside = false
	local function enter()
		if isInside then
			return
		end
		isInside = true
		onEnter()
	end
	local function leave()
		if not isInside then
			return
		end
		isInside = false
		onLeave()
	end

	table.insert(eventVt, btn.MouseButton1Down:Connect(enter))
	table.insert(eventVt, btn.MouseButton1Up:Connect(leave))
	table.insert(eventVt, btn.MouseLeave:Connect(leave))

	return eventVt
end

return AddListen
