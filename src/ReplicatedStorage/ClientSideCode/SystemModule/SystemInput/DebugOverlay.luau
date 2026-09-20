--[[
	Module: SystemInput.DebugOverlay
	Description: Studio 专用输入调试覆盖层（Context / Scheme / 最近 Action）
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-08-28
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players
local RunService = Utils.RunService

local DebugOverlay = {}

local DISPLAY_ORDER = 10000
local LABEL_OFFSET = UDim2.new(0, 8, 1, -8)
local LABEL_SIZE = UDim2.new(0, 420, 0, 120)
local LABEL_BG = Color3.fromRGB(0, 0, 0)
local LABEL_BG_TRANSPARENCY = 0.45
local LABEL_TEXT = Color3.fromRGB(220, 240, 220)
local LABEL_TEXT_SIZE = 14

local _gui: ScreenGui? = nil
local _label: TextLabel? = nil
local _conn: RBXScriptConnection? = nil
local _enabled = true
local _getSnapshot: (() -> string)? = nil

--[[
	创建并启动 Overlay（非 Studio 直接 return）
	@param getSnapshot () -> string - 刷新文案
]]
function DebugOverlay.Start(getSnapshot: () -> string)
	if not RunService:IsStudio() then
		return
	end
	_getSnapshot = getSnapshot
	_enabled = true

	local player = Players.LocalPlayer
	if not player then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

	if _gui then
		_gui:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "SystemInputDebugOverlay"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = DISPLAY_ORDER
	gui.IgnoreGuiInset = true
	gui.Parent = playerGui

	local label = Instance.new("TextLabel")
	label.Name = "Info"
	label.AnchorPoint = Vector2.new(0, 1)
	label.Position = LABEL_OFFSET
	label.Size = LABEL_SIZE
	label.BackgroundColor3 = LABEL_BG
	label.BackgroundTransparency = LABEL_BG_TRANSPARENCY
	label.TextColor3 = LABEL_TEXT
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Font = Enum.Font.Code
	label.TextSize = LABEL_TEXT_SIZE
	label.TextWrapped = true
	label.Text = ""
	label.Parent = gui

	_gui = gui
	_label = label

	if _conn then
		_conn:Disconnect()
	end
	_conn = RunService.Heartbeat:Connect(function()
		if not _enabled or not _label or not _getSnapshot then
			return
		end
		_label.Text = _getSnapshot()
	end)
end

--[[
	开关显示
	@param enabled boolean - 是否显示
]]
function DebugOverlay.SetEnabled(enabled: boolean)
	_enabled = enabled == true
	if _gui then
		_gui.Enabled = _enabled
	end
end

--[[
	是否启用
	@return boolean - Overlay 当前是否显示
]]
function DebugOverlay.IsEnabled(): boolean
	return _enabled
end

--[[
	销毁
]]
function DebugOverlay.Stop()
	if _conn then
		_conn:Disconnect()
		_conn = nil
	end
	if _gui then
		_gui:Destroy()
		_gui = nil
	end
	_label = nil
	_getSnapshot = nil
end

return DebugOverlay
