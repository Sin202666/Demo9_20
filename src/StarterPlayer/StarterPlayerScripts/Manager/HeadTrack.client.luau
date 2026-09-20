--[[
	Module: HeadTrack
	Description: 客户端 NPC 头部跟踪管理器，使带 HeadTrack 标签的 NPC 平滑转向本地玩家
	Author: 林奥宇
	Created: 2026-07-03
	Last Modified: 2026-09-01

	功能：
	- 监听 CollectionService 标签 HeadTrack，为 NPC 绑定颈部平滑转向
	- 玩家在跟踪半径内且处于 NPC 水平视野内时转向；否则回弹至注册时的 Neck.C0
	- NPC 模型 Attribute DisableHeadTrack 为真时暂停跟踪（可运行时切换）
	- 仅改本机看到的 Neck.C0（表现层）；不写 HRP/Store.cframe，不参与伤害/掉落结算

	加载方式：
	- 本文件是 StarterPlayerScripts LocalScript，客户端自动运行
	- 不是 Utils 模块，禁止 require；不要写 Utils.HeadTrack

	配置（GameConfig.HeadTrack）：
	- 启用：false 时本 Manager 不运行
	- 跟踪半径 / 视野点积阈值 / 转向平滑频率 / 骨架等待秒 / 骨架轮询秒
	- 上述字段类型无效或越界时回退到本文件 FALLBACK_*（与 GameConfig.HeadTrack 默认值对齐）

	场景约定：
	- 为 NPC Model 添加 CollectionService 标签 HeadTrack
	- 需含 HumanoidRootPart、Torso（R6）或 UpperTorso（R15）、Neck Motor6D
	- 禁用单实例：Attribute DisableHeadTrack = true

	写口：
	- 本模块是带标签 NPC 的 Neck.C0 在本机上的唯一写者
	- Animator 写 Transform，与 C0 合成；不要再让其它脚本写同一 Neck.C0

	依赖：
	- CollectionService / RunService / LocalPlayer / Log / SystemGameConfig：经 UtilsSystem 获取

	示例：
	- 给 NPC Model 打标签 HeadTrack，进半径且进入水平视野后颈部转向本地玩家
]]

-- ============================================================================
-- 模块引用
-- ============================================================================

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local SystemGameConfig = Utils.SystemGameConfig

if SystemGameConfig.GetValue({ "HeadTrack", "启用" }) == false then
	return
end

local Log = Utils.Log
local CollectionService = Utils.CollectionService
local RunService = Utils.RunService
local LocalPlayer = Utils.LocalPlayer

-- ============================================================================
-- 类型
-- ============================================================================

type TrackedData = {
	torso: BasePart,
	neck: Motor6D,
	npcRoot: BasePart,
	defaultC0: CFrame,
	disabled: boolean,
	connections: { RBXScriptConnection },
}

-- ============================================================================
-- 常量
-- ============================================================================

local TRACK_TAG = "HeadTrack"
local ATTR_DISABLE = "DisableHeadTrack"
local NAME_UPPER_TORSO = "UpperTorso"
local NAME_TORSO = "Torso"
local NAME_ROOT = "HumanoidRootPart"
local NAME_NECK = "Neck"

-- R6 Neck Motor6D 的 C0 默认带 -90° pitch 与 180° roll，look-at 目标需叠回该基座
local NECK_BASE_PITCH = -math.pi / 2
local NECK_BASE_ROLL = -math.pi
local DISTANCE_EPSILON = 0.001
local LOOK_VECTOR_ALIGN_MIN = 0.999

local FALLBACK_TRACK_RADIUS = 15
local FALLBACK_FOV_THRESHOLD = 0.55
local FALLBACK_LOOK_SMOOTH_HZ = 2
local FALLBACK_RIG_WAIT_TIMEOUT = 10
local FALLBACK_RIG_POLL_INTERVAL = 0.1

-- ============================================================================
-- 私有变量
-- ============================================================================

local _trackedData: { [Model]: TrackedData } = {}
local _pending: { [Model]: boolean } = {}
local _playerRoot: BasePart? = nil
local _scriptConnections: { RBXScriptConnection } = {}
local _playerConnections: { RBXScriptConnection } = {}
local _destroyed = false

-- ============================================================================
-- 配置读取
-- ============================================================================

--[[
	读取 GameConfig 数字；类型不对或小于 minValue 时回退并告警

	@param path { string } - SystemGameConfig.GetValue 路径
	@param fallback number - 配置无效时的回退值
	@param minValue number - 合法下限（含）
	@return number - 有效配置或 fallback
]]
local function _getConfigNumber(path: { string }, fallback: number, minValue: number): number
	local value = SystemGameConfig.GetValue(path)
	if typeof(value) == "number" and value >= minValue then
		return value
	end
	Log.warn("HeadTrack: 配置无效，使用回退值", table.concat(path, "."), fallback)
	return fallback
end

local TRACK_RADIUS = _getConfigNumber({ "HeadTrack", "跟踪半径" }, FALLBACK_TRACK_RADIUS, 0)
local FOV_THRESHOLD = _getConfigNumber({ "HeadTrack", "视野点积阈值" }, FALLBACK_FOV_THRESHOLD, -1)
local LOOK_SMOOTH_HZ = _getConfigNumber({ "HeadTrack", "转向平滑频率" }, FALLBACK_LOOK_SMOOTH_HZ, 0.01)
local RIG_WAIT_TIMEOUT = _getConfigNumber({ "HeadTrack", "骨架等待秒" }, FALLBACK_RIG_WAIT_TIMEOUT, 0)
local RIG_POLL_INTERVAL = _getConfigNumber({ "HeadTrack", "骨架轮询秒" }, FALLBACK_RIG_POLL_INTERVAL, 0.01)

-- ============================================================================
-- 私有函数
-- ============================================================================

--[[
	记录脚本级连接，供 _destroy 统一断开

	@param connection RBXScriptConnection - 已 Connect 的连接
	@return nil - 无返回值
]]
local function _addScriptConnection(connection: RBXScriptConnection)
	table.insert(_scriptConnections, connection)
end

--[[
	断开一组连接并清空数组

	@param connections { RBXScriptConnection } - 待断开的连接表
	@return nil - 无返回值
]]
local function _disconnectAll(connections: { RBXScriptConnection })
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

--[[
	一阶指数平滑：将 current 靠近 goal（频率见 LOOK_SMOOTH_HZ）

	@param current CFrame - 当前 Neck.C0
	@param goal CFrame - 目标 C0
	@param dt number - 帧间隔秒
	@return CFrame - 本帧应写入的 C0
]]
local function _smoothTowards(current: CFrame, goal: CFrame, dt: number): CFrame
	local alpha = 1 - math.exp(-LOOK_SMOOTH_HZ * dt)
	if alpha >= 1 then
		return goal
	end
	return current:Lerp(goal, alpha)
end

--[[
	把颈部平滑推向目标；已对齐则跳过写入

	@param data TrackedData - 该 NPC 的跟踪数据
	@param goal CFrame - 目标 C0
	@param dt number - 帧间隔秒
	@return nil - 无返回值
]]
local function _applyNeckGoal(data: TrackedData, goal: CFrame, dt: number)
	local current = data.neck.C0
	if current.LookVector:Dot(goal.LookVector) >= LOOK_VECTOR_ALIGN_MIN then
		if (current.Position - goal.Position).Magnitude <= DISTANCE_EPSILON then
			return
		end
	end
	data.neck.C0 = _smoothTowards(current, goal, dt)
end

--[[
	获取角色躯干（兼容 R6 Torso / R15 UpperTorso）

	@param character Model - 角色或 NPC 模型
	@return BasePart? - 躯干部件，未找到时 nil
]]
local function _getTorso(character: Model): BasePart?
	local torso = character:FindFirstChild(NAME_UPPER_TORSO) or character:FindFirstChild(NAME_TORSO)
	if torso and torso:IsA("BasePart") then
		return torso
	end
	return nil
end

--[[
	等待角色躯干加载（兼容 R6 / R15）

	@param character Model - 角色或 NPC 模型
	@param timeout number - 最长等待秒数
	@return BasePart? - 躯干部件，超时或实例销毁时 nil
]]
local function _waitForTorso(character: Model, timeout: number): BasePart?
	local elapsed = 0
	while elapsed < timeout do
		local torso = _getTorso(character)
		if torso then
			return torso
		end
		if not character.Parent then
			return nil
		end
		task.wait(RIG_POLL_INTERVAL)
		elapsed += RIG_POLL_INTERVAL
	end
	return nil
end

--[[
	判断本地玩家是否在 NPC 跟踪半径内

	@param playerPos Vector3 - 本地玩家 HRP 世界坐标
	@param npcPos Vector3 - NPC HRP 世界坐标
	@return boolean - 在半径内为 true
]]
local function _isWithinRadius(playerPos: Vector3, npcPos: Vector3): boolean
	return (playerPos - npcPos).Magnitude <= TRACK_RADIUS
end

--[[
	判断本地玩家是否在 NPC 水平视野内

	@param playerPos Vector3 - 本地玩家 HRP 世界坐标
	@param torsoCFrame CFrame - NPC 躯干 CFrame
	@return boolean - 在视野内为 true
]]
local function _isWithinNPCFOV(playerPos: Vector3, torsoCFrame: CFrame): boolean
	local toPlayer = playerPos - torsoCFrame.Position
	local toPlayerXZ = Vector3.new(toPlayer.X, 0, toPlayer.Z)
	if toPlayerXZ.Magnitude == 0 then
		return true
	end
	local npcLookXZ = Vector3.new(torsoCFrame.LookVector.X, 0, torsoCFrame.LookVector.Z)
	if npcLookXZ.Magnitude == 0 then
		return false
	end
	return npcLookXZ.Unit:Dot(toPlayerXZ.Unit) >= FOV_THRESHOLD
end

--[[
	清理单个 NPC 的跟踪数据并停止写 Neck.C0

	@param npc Model - NPC 模型
	@return nil - 无返回值
]]
local function _cleanupNPC(npc: Model)
	local data = _trackedData[npc]
	_pending[npc] = nil
	if not data then
		return
	end
	_disconnectAll(data.connections)
	if data.neck.Parent then
		data.neck.C0 = data.defaultC0
	end
	_trackedData[npc] = nil
end

--[[
	解绑本地角色 HRP 缓存

	@return nil - 无返回值
]]
local function _unbindLocalPlayer()
	_disconnectAll(_playerConnections)
	_playerRoot = nil
end

--[[
	绑定本地角色 HRP，避免 Heartbeat 内 FindFirstChild

	@param character Model - 本地玩家角色
	@return nil - 无返回值
]]
local function _bindLocalPlayer(character: Model)
	_unbindLocalPlayer()
	local root = character:WaitForChild(NAME_ROOT, RIG_WAIT_TIMEOUT)
	if not root or not root:IsA("BasePart") then
		Log.warn("HeadTrack: 本地角色缺少 HumanoidRootPart", character:GetFullName())
		return
	end
	_playerRoot = root
	table.insert(
		_playerConnections,
		root.Destroying:Connect(function()
			if _playerRoot == root then
				_playerRoot = nil
			end
		end)
	)
end

--[[
	角色新增：延迟绑定 HRP（WaitForChild 不阻塞其它 CharacterAdded 监听）

	@param character Model - 新角色
	@return nil - 无返回值
]]
local function _onCharacterAdded(character: Model)
	task.defer(function()
		if _destroyed or LocalPlayer.Character ~= character then
			return
		end
		_bindLocalPlayer(character)
	end)
end

--[[
	按 look-at 计算目标 Neck.C0（含 R6 颈部基座旋转）

	@param playerPos Vector3 - 本地玩家 HRP 世界坐标
	@param npcRoot CFrame - NPC HumanoidRootPart CFrame
	@param neckPos Vector3 - 当前 Neck.C0 的位置分量（保持关节原点）
	@return CFrame - 目标 C0
]]
local function _computeLookC0(playerPos: Vector3, npcRoot: CFrame, neckPos: Vector3): CFrame?
	local offset = playerPos - npcRoot.Position
	local distance = offset.Magnitude
	if distance < DISTANCE_EPSILON then
		return nil
	end

	local toPlayer = offset.Unit
	local dirXZ = Vector2.new(toPlayer.X, toPlayer.Z)
	local lookXZ = Vector2.new(npcRoot.LookVector.X, npcRoot.LookVector.Z)
	local yaw = math.atan2(dirXZ:Cross(lookXZ), dirXZ:Dot(lookXZ))
	local pitch = math.atan((playerPos.Y - npcRoot.Position.Y) / distance)

	return CFrame.new(neckPos)
		* CFrame.Angles(pitch, yaw, 0)
		* CFrame.Angles(NECK_BASE_PITCH, 0, NECK_BASE_ROLL)
end

--[[
	每帧更新已注册 NPC 的颈部转向

	@param data TrackedData - 跟踪数据，含 torso、neck、npcRoot、defaultC0、disabled
	@param playerRoot BasePart - 已缓存的本地玩家 HRP
	@param dt number - 帧间隔秒
	@return nil - 无返回值
]]
local function _updateHeadTrack(data: TrackedData, playerRoot: BasePart, dt: number)
	if data.disabled then
		_applyNeckGoal(data, data.defaultC0, dt)
		return
	end

	local playerPos = playerRoot.Position
	local npcRootCFrame = data.npcRoot.CFrame
	if
		_isWithinRadius(playerPos, npcRootCFrame.Position)
		and _isWithinNPCFOV(playerPos, data.torso.CFrame)
	then
		local targetC0 = _computeLookC0(playerPos, npcRootCFrame, data.neck.C0.Position)
		if not targetC0 then
			return
		end
		_applyNeckGoal(data, targetC0, dt)
	else
		_applyNeckGoal(data, data.defaultC0, dt)
	end
end

--[[
	注册 NPC 部件 Destroying / 禁用 Attribute，使 Heartbeat 不再 FindFirstChild

	@param npc Model - 已确认带标签的 NPC
	@param data TrackedData - 刚写入 _trackedData 的跟踪数据
	@return nil - 无返回值
]]
local function _bindTrackedConnections(npc: Model, data: TrackedData)
	table.insert(
		data.connections,
		data.torso.Destroying:Connect(function()
			_cleanupNPC(npc)
		end)
	)
	table.insert(
		data.connections,
		data.neck.Destroying:Connect(function()
			_cleanupNPC(npc)
		end)
	)
	table.insert(
		data.connections,
		data.npcRoot.Destroying:Connect(function()
			_cleanupNPC(npc)
		end)
	)
	table.insert(
		data.connections,
		npc:GetAttributeChangedSignal(ATTR_DISABLE):Connect(function()
			local tracked = _trackedData[npc]
			if tracked then
				tracked.disabled = npc:GetAttribute(ATTR_DISABLE) and true or false
			end
		end)
	)
end

--[[
	CollectionService 标签添加回调：异步等待躯干与 Neck 后注册跟踪

	@param npc Instance - 带 HeadTrack 标签的实例
	@return nil - 无返回值
]]
local function _onInstanceAdded(npc: Instance)
	if _destroyed or not npc:IsA("Model") then
		return
	end
	if _trackedData[npc] or _pending[npc] then
		return
	end

	_pending[npc] = true
	task.spawn(function()
		if _destroyed or not npc.Parent then
			_pending[npc] = nil
			return
		end

		local torso = _waitForTorso(npc, RIG_WAIT_TIMEOUT)
		if not torso then
			_pending[npc] = nil
			if npc.Parent then
				Log.warn("HeadTrack: 等待躯干超时", npc:GetFullName())
			end
			return
		end

		local neckInst = torso:WaitForChild(NAME_NECK, RIG_WAIT_TIMEOUT)
		if not neckInst or not neckInst:IsA("Motor6D") then
			_pending[npc] = nil
			if npc.Parent then
				Log.warn("HeadTrack: 缺少 Neck Motor6D", npc:GetFullName())
			end
			return
		end

		local npcRoot = npc:FindFirstChild(NAME_ROOT)
		if not npcRoot or not npcRoot:IsA("BasePart") then
			_pending[npc] = nil
			Log.warn("HeadTrack: 缺少 HumanoidRootPart", npc:GetFullName())
			return
		end

		if _destroyed or not npc.Parent or not CollectionService:HasTag(npc, TRACK_TAG) then
			_pending[npc] = nil
			return
		end
		if _trackedData[npc] then
			_pending[npc] = nil
			return
		end

		local data: TrackedData = {
			torso = torso,
			neck = neckInst,
			npcRoot = npcRoot,
			defaultC0 = neckInst.C0,
			disabled = npc:GetAttribute(ATTR_DISABLE) and true or false,
			connections = {},
		}
		_trackedData[npc] = data
		_pending[npc] = nil
		_bindTrackedConnections(npc, data)
	end)
end

--[[
	CollectionService 标签移除回调

	@param npc Instance - 被移除标签的实例
	@return nil - 无返回值
]]
local function _onInstanceRemoved(npc: Instance)
	if not npc:IsA("Model") then
		return
	end
	_cleanupNPC(npc)
end

--[[
	Heartbeat 驱动：遍历已注册 NPC，更新转向或清理失效实例

	@param dt number - 帧间隔秒
	@return nil - 无返回值
]]
local function _onHeartbeat(dt: number)
	if dt <= 0 then
		return
	end

	local playerRoot = _playerRoot
	if playerRoot and not playerRoot.Parent then
		playerRoot = nil
		_playerRoot = nil
	end

	for npc, data in _trackedData do
		if not npc.Parent or not data.neck.Parent or not data.npcRoot.Parent then
			_cleanupNPC(npc)
		elseif not playerRoot then
			_applyNeckGoal(data, data.defaultC0, dt)
		else
			_updateHeadTrack(data, playerRoot, dt)
		end
	end
end

--[[
	脚本销毁时断开全部连接并还原 Neck.C0

	@return nil - 无返回值
]]
local function _destroy()
	if _destroyed then
		return
	end
	_destroyed = true
	_disconnectAll(_scriptConnections)
	_unbindLocalPlayer()
	for npc in _trackedData do
		_cleanupNPC(npc)
	end
end

-- ============================================================================
-- 初始化
-- ============================================================================

for _, npc in CollectionService:GetTagged(TRACK_TAG) do
	task.defer(_onInstanceAdded, npc)
end

_addScriptConnection(CollectionService:GetInstanceAddedSignal(TRACK_TAG):Connect(_onInstanceAdded))
_addScriptConnection(CollectionService:GetInstanceRemovedSignal(TRACK_TAG):Connect(_onInstanceRemoved))
_addScriptConnection(RunService.Heartbeat:Connect(_onHeartbeat))
_addScriptConnection(LocalPlayer.CharacterAdded:Connect(_onCharacterAdded))
_addScriptConnection(script.Destroying:Connect(_destroy))

if LocalPlayer.Character then
	_onCharacterAdded(LocalPlayer.Character)
end
