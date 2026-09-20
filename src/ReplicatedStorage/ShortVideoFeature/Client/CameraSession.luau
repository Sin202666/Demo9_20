--[[
	Module: CameraSession
	Description: Scriptable 摄像机接管、还原与偏离检测
	Author: 林奥宇
	Created: 2026-08-13
	Last Modified: 2026-08-13
]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local CameraSession = {}

local _backup: {
	cameraType: Enum.CameraType,
	cframe: CFrame,
	cameraSubject: Instance?,
}? = nil

local _lockedCFrame: CFrame? = nil
local _conn: RBXScriptConnection? = nil
local _onDisturb: (() -> ())? = nil

--[[
	对准底板并接管相机
	@param boardPart BasePart - 视频底板
]]
function CameraSession.Acquire(boardPart: BasePart)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	_backup = {
		cameraType = camera.CameraType,
		cframe = camera.CFrame,
		cameraSubject = camera.CameraSubject,
	}
	CameraSession.Relock(boardPart)
end

--[[
	按当前底板位姿刷新锁定 CFrame（跟随板移动时调用）
	仰视头顶底板：沿板法线（朝向玩家一侧）后退一段再看向板心
	@param boardPart BasePart - 视频底板
]]
function CameraSession.Relock(boardPart: BasePart)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local lookAt = boardPart.Position
	-- LookVector 指向玩家；相机放在板与玩家之间偏板一侧，便于仰视点击
	local camPos = boardPart.Position + boardPart.CFrame.LookVector * 12
	local locked = CFrame.lookAt(camPos, lookAt)
	_lockedCFrame = locked
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = locked
end

--[[
	开始偏离检测
	@param onDisturb () -> () - 回调
]]
function CameraSession.StartDisturbWatch(onDisturb: () -> ())
	_onDisturb = onDisturb
	if _conn then
		_conn:Disconnect()
		_conn = nil
	end
	_conn = RunService.RenderStepped:Connect(function()
		local camera = Workspace.CurrentCamera
		local locked = _lockedCFrame
		local cb = _onDisturb
		if not camera or not locked or not cb then
			return
		end
		if camera.CameraType ~= Enum.CameraType.Scriptable then
			cb()
			return
		end
		local dist = (camera.CFrame.Position - locked.Position).Magnitude
		if dist > 1.5 then
			cb()
		end
	end)
end

--[[
	停止偏离检测
]]
function CameraSession.StopDisturbWatch()
	if _conn then
		_conn:Disconnect()
		_conn = nil
	end
	_onDisturb = nil
end

--[[
	还原摄像机
]]
function CameraSession.Restore()
	CameraSession.StopDisturbWatch()
	local camera = Workspace.CurrentCamera
	local backup = _backup
	_backup = nil
	_lockedCFrame = nil
	if not camera or not backup then
		return
	end
	camera.CameraType = backup.cameraType
	camera.CameraSubject = backup.cameraSubject
	camera.CFrame = backup.cframe
end

return CameraSession
