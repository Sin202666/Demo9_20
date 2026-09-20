--[[
	Module: SystemMount
	Description: 坐骑/载具客户端 Session 镜像与 Locomotion Driver 编排
	Author: 林奥宇
	Created: 2026-08-27
	Last Modified: 2026-09-01

	功能：
	- 收 SyncState / ForceExit，按 locomotionType + DriveMode 装配 Driver
	- GroundMount：HumanoidHost→GroundMountDriver（A）；MountRoot→MountRootDriver（B）
	- RequestEnter / RequestExit 发 Remote
	- BindToRenderStep（Character+2）调用 Driver.update
	- FireSessionChanged 通知 UI / Manager
	- destroy()：Disconnect Character 连接 + Unbind RenderStep + 销毁 Driver

	加载：
		local SystemMount = Utils.SystemMount
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)

local CfgFind = Utils.CfgFind
local CharacterMotion = Utils.CharacterMotion
local EnumMgr = Utils.EnumMgr
local HttpService = Utils.HttpService
local MountNet = Utils.MountNet
local RunService = Utils.RunService

local GroundMountDriver = require(script.MountLocomotion.GroundMountDriver)
local MountRootDriver = require(script.MountLocomotion.MountRootDriver)

local SystemMount = {}

local LocalPlayer = Utils.LocalPlayer
local RENDER_STEP_NAME = "MountGroundLocomotion"
local RENDER_STEP_PRIORITY = Enum.RenderPriority.Character.Value + 2

local _localSession: { [string]: any } = {
	state = EnumMgr.MountSessionState.Idle,
	mountId = nil,
	locomotionType = nil,
	speedMul = nil,
	serverTime = 0,
	cdUntil = 0,
}
local _driver: any = nil
local _inited = false
local _renderBound = false
local _lifecycleConns: { RBXScriptConnection } = {}

--[[
	从 cfg / ExtJson 解析 DriveMode（仅 GroundMount 有意义）
	@param cfg table? - MountCfg 深拷贝
	@return string - MountDriveMode
]]
local function _resolveDriveMode(cfg: { [string]: any }?): string
	local defaultMode = EnumMgr.MountDriveMode.HumanoidHost
	if type(cfg) ~= "table" then
		return defaultMode
	end
	local raw = cfg.DriveMode
	if type(raw) ~= "string" or raw == "" then
		local extRaw = cfg.ExtJson
		if type(extRaw) == "string" and extRaw ~= "" then
			local ok, decoded = pcall(function()
				return HttpService:JSONDecode(extRaw)
			end)
			if ok and type(decoded) == "table" and type(decoded.DriveMode) == "string" then
				raw = decoded.DriveMode
			end
		end
	end
	if raw == EnumMgr.MountDriveMode.MountRoot then
		return EnumMgr.MountDriveMode.MountRoot
	end
	if raw == EnumMgr.MountDriveMode.HumanoidHost then
		return EnumMgr.MountDriveMode.HumanoidHost
	end
	return defaultMode
end

--[[
	销毁当前 Driver
	@param reason string - ForceExit 原因
]]
local function _destroyDriver(reason: string)
	if _driver then
		if _driver.exit then
			_driver:exit(reason)
		elseif _driver.destroy then
			_driver:destroy()
		end
		_driver = nil
	end
end

--[[
	按 locomotionType + DriveMode 创建 Driver
	@param mountId number - mountConf 主键
	@param locomotionType string - MountLocomotionType
	@param cfg table? - MountCfg（解析 DriveMode）
	@return any? - Driver 实例
]]
local function _createDriver(mountId: number, locomotionType: string, cfg: { [string]: any }?): any?
	if locomotionType == EnumMgr.MountLocomotionType.GroundMount then
		local driveMode = _resolveDriveMode(cfg)
		if driveMode == EnumMgr.MountDriveMode.MountRoot then
			return MountRootDriver.new(mountId)
		end
		return GroundMountDriver.new(mountId)
	end
	return nil
end

--[[
	尝试根据 Session 装配 Driver
	@param session table - MountSessionSnapshot
]]
local function _applySession(session: { [string]: any })
	local prevState = _localSession.state
	_localSession = {
		state = session.state or EnumMgr.MountSessionState.Idle,
		mountId = session.mountId,
		locomotionType = session.locomotionType,
		speedMul = session.speedMul,
		serverTime = session.serverTime or os.time(),
		cdUntil = session.cdUntil or 0,
	}

	local character = LocalPlayer and LocalPlayer.Character
	local isActive = _localSession.state == EnumMgr.MountSessionState.Active

	if not isActive then
		if _driver then
			_destroyDriver(EnumMgr.MountForceExitReason.PlayerRequest)
		end
		MountNet.FireSessionChanged(_localSession, prevState)
		return
	end

	local mountId = _localSession.mountId
	local locomotionType = _localSession.locomotionType
	if not mountId or not locomotionType or not character then
		return
	end

	if _driver and _driver.mountId == mountId and _driver.isActive and _driver:isActive() then
		MountNet.FireSessionChanged(_localSession, prevState)
		return
	end

	_destroyDriver(EnumMgr.MountForceExitReason.InvalidState)

	local cfg = CfgFind.GetMountCfg(mountId)
	if not cfg then
		return
	end

	local driver = _createDriver(mountId, locomotionType, cfg)
	if not driver then
		return
	end

	local ok = driver:enter({
		mountId = mountId,
		locomotionType = locomotionType,
		driveMode = _resolveDriveMode(cfg),
		cfg = cfg,
		character = character,
		reason = nil,
	})
	if not ok then
		driver:destroy()
		return
	end

	_driver = driver
	MountNet.FireSessionChanged(_localSession, prevState)
end

--[[
	处理服务端 Sync
	@param payload table - MountSyncPayload
]]
function SystemMount.OnSyncState(payload: { [string]: any })
	if type(payload) ~= "table" or type(payload.session) ~= "table" then
		return
	end
	_applySession(payload.session)
end

--[[
	处理服务端 ForceExit（Session 应已通过 Sync 更新；此处补 Driver 收尾）
	@param payload table - MountForceExitPayload
]]
function SystemMount.OnForceExit(payload: { [string]: any })
	local reason = if type(payload) == "table" and type(payload.reason) == "string"
		then payload.reason
		else EnumMgr.MountForceExitReason.InvalidState
	_destroyDriver(reason)
end

--[[
	请求进入（本地预检 CharacterMotion Drive；mountId 缺省则由服使用当前装备）
	@param mountId number? - mountConf 主键；nil 时服务端用 GetEquippedMountId
]]
function SystemMount.RequestEnter(mountId: number?)
	local character = LocalPlayer and LocalPlayer.Character
	if character and CharacterMotion and CharacterMotion.GetActive then
		local active = CharacterMotion.GetActive(character)
		if active and (active.driveActive or (active.impulseCount and active.impulseCount > 0)) then
			return
		end
	end
	MountNet.ReqEnter:FireServer(mountId)
end

--[[
	请求离开当前骑乘（发 Remote；由服 TryExit 权威结算 Session）
	@return () - 无返回值；失败由服静默处理
]]
function SystemMount.RequestExit()
	MountNet.ReqExit:FireServer()
end

--[[
	本地 Session 快照
	@return table - MountSessionSnapshot 浅拷贝
]]
function SystemMount.GetLocalSession(): { [string]: any }
	return {
		state = _localSession.state,
		mountId = _localSession.mountId,
		locomotionType = _localSession.locomotionType,
		speedMul = _localSession.speedMul,
		serverTime = _localSession.serverTime,
		cdUntil = _localSession.cdUntil,
	}
end

--[[
	本地是否 Active
	@return boolean - 是否骑乘中
]]
function SystemMount.IsLocalActive(): boolean
	return _localSession.state == EnumMgr.MountSessionState.Active
end

--[[
	换角时清理 / 重挂 Driver
	@param character Model? - 新角色；nil 表示移除
]]
local function _onCharacterChanged(character: Model?)
	if not character then
		_destroyDriver(EnumMgr.MountForceExitReason.Respawn)
		_localSession = {
			state = EnumMgr.MountSessionState.Idle,
			mountId = nil,
			locomotionType = nil,
			speedMul = nil,
			serverTime = os.time(),
			cdUntil = 0,
		}
		return
	end

	if _localSession.state == EnumMgr.MountSessionState.Active and _localSession.mountId then
		local cfg = CfgFind.GetMountCfg(_localSession.mountId)
		if cfg then
			_destroyDriver(EnumMgr.MountForceExitReason.Respawn)
			local driver = _createDriver(_localSession.mountId, _localSession.locomotionType :: string, cfg)
			if driver then
				local ok = driver:enter({
					mountId = _localSession.mountId,
					locomotionType = _localSession.locomotionType,
					driveMode = _resolveDriveMode(cfg),
					cfg = cfg,
					character = character,
				})
				if ok then
					_driver = driver
				else
					driver:destroy()
				end
			end
		end
	end
end

--[[
	Manager-only：绑定 CharacterAdded / RenderStep（单例；连接持有至 destroy）
]]
function SystemMount.InitLocal()
	if _inited then
		return
	end
	_inited = true

	if LocalPlayer then
		table.insert(_lifecycleConns, LocalPlayer.CharacterAdded:Connect(_onCharacterChanged))
		table.insert(
			_lifecycleConns,
			LocalPlayer.CharacterRemoving:Connect(function()
				_onCharacterChanged(nil)
			end)
		)
	end

	if not _renderBound then
		RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_STEP_PRIORITY, function(dt: number)
			if _driver and _driver.isActive and _driver:isActive() and _driver.update then
				_driver:update(dt)
			end
		end)
		_renderBound = true
	end
end

--[[
	会话结束：断开 Character 连接、Unbind RenderStep、销毁 Driver。幂等。
]]
function SystemMount.destroy()
	for _, conn in _lifecycleConns do
		conn:Disconnect()
	end
	table.clear(_lifecycleConns)
	if _renderBound then
		pcall(function()
			RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
		end)
		_renderBound = false
	end
	_destroyDriver(EnumMgr.MountForceExitReason.LeaveGame)
	_inited = false
end

return SystemMount
