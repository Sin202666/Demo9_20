--[[
	Module: CharacterManager
	Description: 角色 3C 薄编排入口：HeadLock + CharacterControl 生命周期
	Author: 林奥宇
	Created: 2026-02-03
	Last Modified: 2026-08-31

	功能：
	- HeadLock 初始化与 RenderStepped 驱动
	- CharacterControl.Create（Intent/Lock/Sprint/Jump）；task.defer 避开 CMS setHandler 竞态
	- 角色销毁时断开连接并 destroy HeadLock / CharacterControl

	说明：
	- CharacterMoveSpeed / Bind 仍由同级独立脚本启动（CMS 唯一写 WalkSpeed）
	- CameraMode 为全局 CameraModule 能力，由 CameraManager 启动，不经本 Manager
	- 本脚本是 StarterCharacterScripts 本地脚本（Rojo：目录 + init.client.luau），不是 Utils 模块

	加载方式：
	角色生成时由引擎启动；子模块 HeadLock 用 require(script.HeadLock)

	使用示例：
	无需业务侧 require。角色销毁走 AncestryChanged：Disconnect 后 destroy HeadLock / CharacterControl。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService
local CharacterControl = Utils.CharacterControl
local LocalPlayer = Utils.LocalPlayer

local HeadLock = require(script.HeadLock)
local CharacterMoveSpeedBind = require(script.Parent:WaitForChild("CharacterMoveSpeedBind"))

local Character: Model = script.Parent.Parent

local _headLock = HeadLock.new()
_headLock:initCharacter(Character)

-- CharacterControl.Create 返回控制器实例；类型由 CharacterControl 导出
local _ctrl: any = nil
local _renderConn: RBXScriptConnection? = nil
local _ancestryConn: RBXScriptConnection? = nil

_renderConn = RunService.RenderStepped:Connect(function(dt: number)
	_headLock:renderStepped(dt)
end)

--[[
	延后创建 CharacterControl，确保 CMS Bind.setHandler 已完成
]]
local function _startControl()
	if _ctrl then
		return
	end
	_ctrl = CharacterControl.Create(Character, {
		moveSpeedBind = CharacterMoveSpeedBind,
		localPlayer = LocalPlayer,
	})
end

--[[
	角色离树时断开连接并销毁 HeadLock / CharacterControl
]]
local function _cleanup()
	if _renderConn then
		_renderConn:Disconnect()
		_renderConn = nil
	end
	if _ancestryConn then
		_ancestryConn:Disconnect()
		_ancestryConn = nil
	end
	_headLock:destroy()
	if _ctrl then
		_ctrl:destroy()
		_ctrl = nil
	end
end

task.defer(_startControl)

_ancestryConn = Character.AncestryChanged:Connect(function(_child: Instance, parent: Instance?)
	if parent ~= nil then
		return
	end
	_cleanup()
end)
