--[[
	Module: HeadLock
	Description: 第一人称相机控制；监听 CameraSubject，通过 Humanoid.CameraOffset 对齐头部视角
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-08-31

	功能：
	- 将 CameraSubject 约束在本角色 Humanoid，避免被切到 Head 等部件
	- 开启时按头部相对 Root 的偏移平滑写 Humanoid.CameraOffset（仅表现，不写 WalkSpeed / 位姿权威）

	与相关模块：
	- 由 CharacterManager 创建并在 RenderStepped 驱动；角色销毁时 destroy
	- 不经 CharacterMoveSpeed；CameraMode 由 CameraManager / CameraModule 负责

	用法：
		local HeadLock = require(script.HeadLock)
		local controller = HeadLock.new()
		controller:initCharacter(character)
		RunService.RenderStepped:Connect(function(dt)
			controller:renderStepped(dt)
		end)
		controller:destroy()
]]

-- ========================================
-- 常量
-- ========================================
local HEAD_OFFSET_Y = 1.5
local CAMERA_OFFSET_LERP_SPEED = 2

-- ========================================
-- 模块定义
-- ========================================
local HeadLock = {}
HeadLock.__index = HeadLock

-- ========================================
-- 私有函数
-- ========================================

--[[
	取当前工作区相机（CurrentCamera 可能被替换，禁止模块级缓存）

	@return Camera? - 当前相机；尚未就绪时为 nil
]]
local function _getCamera(): Camera?
	return workspace.CurrentCamera
end

--[[
	绑定 CameraSubject 监听；内部改写须先置 _isInternalChange 再赋值

	@param self HeadLock - 控制器实例
]]
local function _bindCameraSubject(self)
	if self._cameraSubjectConn then
		self._cameraSubjectConn:Disconnect()
		self._cameraSubjectConn = nil
	end

	local camera = _getCamera()
	if not camera then
		return
	end

	self._cameraSubjectConn = camera:GetPropertyChangedSignal("CameraSubject"):Connect(function()
		if self._isInternalChange then
			self._isInternalChange = false
			return
		end

		local subject = camera.CameraSubject

		if subject and ((subject:IsA("BasePart") and subject.Name == "Head") or subject:IsA("Humanoid")) then
			if not self._humanoid then
				return
			end

			-- 须先置位再写 CameraSubject，否则同步信号会重入
			self._isInternalChange = true
			camera.CameraSubject = self._humanoid
			self:toggle(true)
		else
			self:toggle(false)
		end
	end)

	camera.CameraSubject = self._head
end

-- ========================================
-- 公共函数
-- ========================================

--[[
	创建 HeadLock 控制器实例

	@return HeadLock - 控制器实例
]]
function HeadLock.new()
	local self = setmetatable({}, HeadLock)

	self._rootPart = nil
	self._head = nil
	self._humanoid = nil
	self._enabled = false
	self._isInternalChange = false
	self._cameraSubjectConn = nil
	self._cameraChangedConn = nil

	return self
end

--[[
	初始化角色引用并绑定相机

	@param character Model - 玩家角色模型
]]
function HeadLock:initCharacter(character: Model)
	self._head = character:WaitForChild("Head")
	self._humanoid = character:WaitForChild("Humanoid")
	self._rootPart = character:WaitForChild("HumanoidRootPart")

	_bindCameraSubject(self)

	if self._cameraChangedConn then
		self._cameraChangedConn:Disconnect()
	end
	self._cameraChangedConn = workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		_bindCameraSubject(self)
	end)
end

--[[
	开关第一人称相机逻辑

	@param enabled boolean - true 开启，false 关闭
]]
function HeadLock:toggle(enabled: boolean)
	if self._enabled == enabled then
		return
	end

	self._enabled = enabled

	if self._humanoid then
		self._humanoid.CameraOffset = Vector3.new(0, 0, 0)
	end
end

--[[
	每帧平滑调整 CameraOffset

	@param deltaTime number - 帧间隔（秒）
	@return boolean - 更新成功为 true，未启用或字段缺失为 false
]]
function HeadLock:update(deltaTime: number): boolean
	if not self._enabled then
		return false
	end

	if not self._rootPart or not self._head or not self._humanoid then
		return false
	end

	local localHeadOffset =
		(self._rootPart.CFrame + Vector3.new(0, HEAD_OFFSET_Y, 0)):PointToObjectSpace(self._head.Position)

	self._humanoid.CameraOffset =
		self._humanoid.CameraOffset:Lerp(localHeadOffset, deltaTime * CAMERA_OFFSET_LERP_SPEED)

	return true
end

--[[
	RenderStepped 入口；更新失败时自动关闭

	@param deltaTime number - 帧间隔（秒）
]]
function HeadLock:renderStepped(deltaTime: number)
	if not self:update(deltaTime) then
		self:toggle(false)
	end
end

--[[
	销毁控制器并断开相机监听
]]
function HeadLock:destroy()
	if self._cameraSubjectConn then
		self._cameraSubjectConn:Disconnect()
		self._cameraSubjectConn = nil
	end
	if self._cameraChangedConn then
		self._cameraChangedConn:Disconnect()
		self._cameraChangedConn = nil
	end

	self:toggle(false)
	self._rootPart = nil
	self._head = nil
	self._humanoid = nil
end

return HeadLock
