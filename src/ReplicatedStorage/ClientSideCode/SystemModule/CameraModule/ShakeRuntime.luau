--[[
	Module: ShakeRuntime
	Description: CameraModule 多层 Trauma / Kick / Sustain 运行时与每帧偏移合成
	Author: 林奥宇
	Created: 2026-08-03
	Last Modified: 2026-08-31

	功能：
	- Once/At/Impulse 瞬时层、命名源 Sustain、弹簧 Kick、强制淡出
	- 层满时仅驱逐非 Sustain；全为 Sustain 时拒绝新瞬时层（返回 nil + warn）
	- Setting 震动强度由 CameraModule 缓存后注入 SetSettingShakeScale

	使用：
	local ShakeRuntime = require(script.Parent.ShakeRuntime)
	ShakeRuntime.SetCamera(camera)
	local offset = ShakeRuntime.ComputeOffset(dt)
]]

local TraumaNoise = require(script.Parent.TraumaNoise)
local ShakePresets = require(script.Parent.ShakePresets)
local CameraConfig = require(script.Parent.CameraConfig)
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players
local Log = Utils.Log

type ShakeTypeConfig = ShakePresets.ShakeTypeConfig

local ShakeRuntime = {}

local KICK_REST_EPS = 1e-5
local KICK_DIR_EPS = 1e-5
local TRAUMA_DEAD_EPS = 1e-4
local SUSTAIN_TRAUMA_FLOOR = 0.35
local SUSTAIN_ATTACK_SEC = 0.15
local MAX_SHAKE_LAYERS = 12
local DEFAULT_STOP_FADE = 0.1
local NOISE_SEED_STRIDE = 37.1
local HUMANOID_ROOT_PART_NAME = "HumanoidRootPart"

type ShakeLayer = {
	id: number,
	trauma: number,
	traumaPeak: number,
	roughness: number,
	posInfluence: Vector3,
	rotInfluence: Vector3,
	decayPerSec: number,
	attackSec: number,
	attackElapsed: number,
	noiseTick: number,
	seed: number,
	isSustain: boolean,
	sourceId: string?,
}

type KickEntry = {
	id: number,
	pos: Vector3,
	rot: Vector3,
	velPos: Vector3,
	velRot: Vector3,
}

type SustainSource = {
	count: number,
	layerId: number,
}

local _camera: Camera? = nil
local _shakeScale = 1
local _settingShakeScale = 1
local _shakeIdCounter = 0
local _noiseSeedCounter = 0
local _sustainSources: { [string]: SustainSource } = {}
local _layers: { ShakeLayer } = {}
local _kicks: { KickEntry } = {}
local _fadeOutRemaining: number? = nil
local _fadeOutDuration: number? = nil

--[[
	smoothstep 插值（Hermite）
	@param t number - 0~1，超出范围会 clamp
	@return number - 平滑后的 0~1
]]
local function _smoothstep(t: number): number
	local x = math.clamp(t, 0, 1)
	return x * x * (3 - 2 * x)
end

--[[
	解析类型 Attack 秒数
	@param cfg ShakeTypeConfig - 类型配置
	@param isSustain boolean - Sustain 层用更长默认上升
	@return number - Attack 上升秒数，>=0
]]
local function _resolveAttackSec(cfg: ShakeTypeConfig, isSustain: boolean): number
	if type(cfg.attackSec) == "number" then
		return math.max(0, cfg.attackSec)
	end
	if isSustain then
		return SUSTAIN_ATTACK_SEC
	end
	return math.max(0, CameraConfig.TRAUMA_ATTACK_SEC)
end

--[[
	分配层噪声相位
	@return number - 与其它层错开的噪声种子
]]
local function _nextNoiseSeed(): number
	_noiseSeedCounter += 1
	return _noiseSeedCounter * NOISE_SEED_STRIDE
end

--[[
	分配震动句柄
	@return number - 单调递增的层/Kick 共用句柄
]]
local function _nextShakeId(): number
	_shakeIdCounter += 1
	return _shakeIdCounter
end

--[[
	按 id 查找层下标
	@param id number - 震动句柄
	@return number? - 1-based 下标；找不到为 nil
]]
local function _findLayerIndexById(id: number): number?
	for i, layer in ipairs(_layers) do
		if layer.id == id then
			return i
		end
	end
	return nil
end

--[[
	按命名源查找 Sustain 层
	@param sourceId string - Sustain 源名
	@return ShakeLayer? - 该源的 Sustain 层；没有为 nil
]]
local function _findSustainLayerBySource(sourceId: string): ShakeLayer?
	for _, layer in ipairs(_layers) do
		if layer.isSustain and layer.sourceId == sourceId then
			return layer
		end
	end
	return nil
end

--[[
	移除指定 id 的 Kick
	@param id number - 震动句柄
	@return () - 无返回值
]]
local function _removeKickById(id: number)
	for i = #_kicks, 1, -1 do
		if _kicks[i].id == id then
			table.remove(_kicks, i)
			return
		end
	end
end

--[[
	移除指定 id 的层与 Kick
	@param id number - 震动句柄
	@return boolean - 是否找到并移除了层
]]
local function _removeLayerById(id: number): boolean
	local index = _findLayerIndexById(id)
	_removeKickById(id)
	if not index then
		return false
	end
	local layer = _layers[index]
	if layer.sourceId then
		_sustainSources[layer.sourceId] = nil
	end
	table.remove(_layers, index)
	return true
end

--[[
	层数满时移除 trauma 最低的非 Sustain 层；无可驱逐时返回 false（不误伤 Sustain）
	@return boolean - 是否腾出了槽位
]]
local function _evictWeakestTransientLayer(): boolean
	local weakestIndex: number? = nil
	local weakestTrauma = math.huge
	for i, layer in ipairs(_layers) do
		if not layer.isSustain and layer.trauma < weakestTrauma then
			weakestTrauma = layer.trauma
			weakestIndex = i
		end
	end
	if not weakestIndex then
		return false
	end
	local removed = _layers[weakestIndex]
	_removeKickById(removed.id)
	if removed.sourceId then
		_sustainSources[removed.sourceId] = nil
	end
	table.remove(_layers, weakestIndex)
	return true
end

--[[
	确保有空层槽；无法腾出时返回 false
	@return boolean - 是否已有空槽（或已驱逐瞬时层腾出）
]]
local function _ensureLayerSlot(): boolean
	while #_layers >= MAX_SHAKE_LAYERS do
		if not _evictWeakestTransientLayer() then
			return false
		end
	end
	return true
end

--[[
	取消强制淡出
	@return () - 无返回值
]]
local function _cancelFadeOut()
	_fadeOutRemaining = nil
	_fadeOutDuration = nil
end

--[[
	解析 intensityMul
	@param intensityMul number? - 缺省 1；非 number 视为 1
	@return number - clamp 到 0~2
]]
local function _resolveIntensityMul(intensityMul: number?): number
	if type(intensityMul) ~= "number" then
		return 1
	end
	return math.clamp(intensityMul, 0, 2)
end

--[[
	取消 Sustain 标记并可选加速衰减
	@param layer ShakeLayer - 层
	@param fadeOutTime number? - >0 加速衰减；nil 保持原 decay
	@return () - 无返回值
]]
local function _releaseSustainLayer(layer: ShakeLayer, fadeOutTime: number?)
	layer.isSustain = false
	layer.sourceId = nil
	layer.attackSec = 0
	if type(fadeOutTime) == "number" and fadeOutTime > 0 and layer.trauma > 0 then
		layer.decayPerSec = math.max(layer.decayPerSec, layer.trauma / fadeOutTime)
	end
end

--[[
	解除全部 Sustain 标记
	@return () - 无返回值
]]
local function _releaseAllSustainLayers()
	table.clear(_sustainSources)
	for _, layer in ipairs(_layers) do
		if layer.isSustain then
			_releaseSustainLayer(layer, nil)
		end
	end
end

--[[
	开始强制淡出
	@param duration number - 秒，必须 > 0
	@return () - 无返回值
]]
local function _beginFadeOut(duration: number)
	_fadeOutDuration = duration
	_fadeOutRemaining = duration
	_releaseAllSustainLayers()
end

--[[
	立即清空层与 Kick（保留全局 scale）
	@return () - 无返回值
]]
local function _clearAllShakeLayers()
	table.clear(_layers)
	table.clear(_sustainSources)
	table.clear(_kicks)
	_fadeOutRemaining = nil
	_fadeOutDuration = nil
end

--[[
	获取听点世界坐标
	@return Vector3 - 听点世界坐标；无角色时退回相机位置或 origin
]]
local function _getListenerPosition(): Vector3
	local localPlayer = Players.LocalPlayer
	if localPlayer then
		local character = localPlayer.Character
		if character then
			local root = character:FindFirstChild(HUMANOID_ROOT_PART_NAME)
			if root and root:IsA("BasePart") then
				return root.Position
			end
			local primary = character.PrimaryPart
			if primary then
				return primary.Position
			end
		end
	end
	if _camera then
		return _camera.CFrame.Position
	end
	return Vector3.zero
end

--[[
	硬限幅并组装震动 CFrame
	@param pos Vector3 - 位移
	@param rotDeg Vector3 - 转角（度）
	@return CFrame - 限幅后的震动偏移
]]
local function _clampShakeOffset(pos: Vector3, rotDeg: Vector3): CFrame
	local posMag = pos.Magnitude
	if posMag > CameraConfig.MAX_SHAKE_POS and posMag > 0 then
		pos = pos.Unit * CameraConfig.MAX_SHAKE_POS
	end
	local rx = math.clamp(rotDeg.X, -CameraConfig.MAX_SHAKE_ROT_DEG, CameraConfig.MAX_SHAKE_ROT_DEG)
	local ry = math.clamp(rotDeg.Y, -CameraConfig.MAX_SHAKE_ROT_DEG, CameraConfig.MAX_SHAKE_ROT_DEG)
	local rz = math.clamp(rotDeg.Z, -CameraConfig.MAX_SHAKE_ROT_DEG, CameraConfig.MAX_SHAKE_ROT_DEG)
	return CFrame.new(pos) * CFrame.fromOrientation(math.rad(rx), math.rad(ry), math.rad(rz))
end

--------------------------------------------------------------------------------
-- 公开 API
--------------------------------------------------------------------------------

--[[
	绑定当前相机（Kick 局部空间依赖）
	@param camera Camera? - CurrentCamera；nil 时 Kick 退回世界方向
	@return () - 无返回值
]]
function ShakeRuntime.SetCamera(camera: Camera?)
	_camera = camera
end

--[[
	注入设置项震动强度（由 CameraModule 缓存后调用）
	@param scale number - 0~1，内部 clamp
	@return () - 无返回值
]]
function ShakeRuntime.SetSettingShakeScale(scale: number)
	_settingShakeScale = math.clamp(scale, 0, 1)
end

--[[
	设置全局震动强度
	@param scale number - 0~1，内部 clamp
	@return () - 无返回值
]]
function ShakeRuntime.SetShakeScale(scale: number)
	_shakeScale = math.clamp(scale, 0, 1)
end

--[[
	获取全局震动强度
	@return number - 0~1
]]
function ShakeRuntime.GetShakeScale(): number
	return _shakeScale
end

--[[
	PlayAt 默认最大距离
	@return number - GameConfig PlayAt默认最大距离（加载快照）
]]
function ShakeRuntime.GetPlayAtDefaultMaxDistance(): number
	return CameraConfig.PLAYAT_DEFAULT_MAX_DIST
end

--[[
	PlayAt 方向 Kick 系数
	@return number - GameConfig PlayAt方向Kick系数（加载快照）
]]
function ShakeRuntime.GetPlayAtKickScale(): number
	return CameraConfig.PLAYAT_KICK_SCALE
end

--[[
	获取听点
	@return Vector3 - 听点世界坐标；无角色时退回相机位置或 origin
]]
function ShakeRuntime.GetListenerPosition(): Vector3
	return _getListenerPosition()
end

--[[
	按世界距离计算衰减系数
	@param worldPos Vector3 - 事件坐标
	@param maxDistance number - 衰减到 0 的距离
	@return number - 0~1
]]
function ShakeRuntime.GetDistanceFactor(worldPos: Vector3, maxDistance: number): number
	local listenerPos = _getListenerPosition()
	local distance = (worldPos - listenerPos).Magnitude
	local minD = CameraConfig.PLAYAT_MIN_FULL_DIST
	local maxD = math.max(maxDistance, minD + 0.001)
	if distance <= minD then
		return 1
	end
	if distance >= maxD then
		return 0
	end
	local t = (distance - minD) / (maxD - minD)
	return 1 - _smoothstep(t)
end

--[[
	解析 intensityMul
	@param intensityMul number? - 缺省 1；非 number 视为 1
	@return number - clamp 到 0~2
]]
function ShakeRuntime.ResolveIntensityMul(intensityMul: number?): number
	return _resolveIntensityMul(intensityMul)
end

--[[
	推入瞬时 Trauma 层；层满且无可驱逐瞬时层时返回 nil
	@param cfg ShakeTypeConfig - 类型配置
	@param distanceFactor number? - 0~1
	@param intensityMul number? - 强度乘子
	@return number? - 句柄
]]
function ShakeRuntime.PushLayer(cfg: ShakeTypeConfig, distanceFactor: number?, intensityMul: number?): number?
	local factor = if type(distanceFactor) == "number" then math.clamp(distanceFactor, 0, 1) else 1
	local mul = _resolveIntensityMul(intensityMul)
	if factor <= 0 or mul <= 0 then
		return nil
	end
	_cancelFadeOut()
	if not _ensureLayerSlot() then
		Log.warn("ShakeRuntime.PushLayer: 层已满且均为 Sustain，拒绝新瞬时震动")
		return nil
	end
	local peak = math.clamp(cfg.trauma * factor * mul, 0, 1)
	local attackSec = _resolveAttackSec(cfg, false)
	local id = _nextShakeId()
	table.insert(_layers, {
		id = id,
		trauma = if attackSec > 0 then 0 else peak,
		traumaPeak = peak,
		roughness = if cfg.roughness > 0 then cfg.roughness else CameraConfig.NOISE_FREQUENCY,
		posInfluence = cfg.posInfluence,
		rotInfluence = cfg.rotInfluence,
		decayPerSec = if cfg.decayPerSec > 0 then cfg.decayPerSec else CameraConfig.TRAUMA_DECAY_PER_SEC,
		attackSec = attackSec,
		attackElapsed = 0,
		noiseTick = 0,
		seed = _nextNoiseSeed(),
		isSustain = false,
		sourceId = nil,
	})
	return id
end

--[[
	写入相机局部 Kick（速度冲量）
	@param shakeId number - 与层共用句柄
	@param worldDir Vector3 - 世界方向
	@param kickStrength number - >=0；<=0 时忽略
	@return () - 无返回值
]]
function ShakeRuntime.AddCameraLocalKick(shakeId: number, worldDir: Vector3, kickStrength: number)
	if kickStrength <= 0 or worldDir.Magnitude < KICK_DIR_EPS then
		return
	end
	local worldUnit = worldDir.Unit
	local localDir = if _camera then _camera.CFrame:VectorToObjectSpace(worldUnit) else worldUnit
	if localDir.Magnitude < KICK_DIR_EPS then
		localDir = worldUnit
	else
		localDir = localDir.Unit
	end
	local impulseScale = CameraConfig.IMPULSE_SPRING_IMPULSE
	local velPosDelta = localDir * (CameraConfig.IMPULSE_POS_SCALE * kickStrength * impulseScale)
	local velRotDelta = Vector3.new(-localDir.Y, localDir.X, -localDir.Z)
		* math.rad(CameraConfig.IMPULSE_ROT_SCALE * kickStrength * impulseScale)
	for _, kick in ipairs(_kicks) do
		if kick.id == shakeId then
			kick.velPos = kick.velPos + velPosDelta
			kick.velRot = kick.velRot + velRotDelta
			return
		end
	end
	table.insert(_kicks, {
		id = shakeId,
		pos = Vector3.zero,
		rot = Vector3.zero,
		velPos = velPosDelta,
		velRot = velRotDelta,
	})
end

--[[
	开始或刷新命名源 Sustain
	@param sourceId string - 源名
	@param cfg ShakeTypeConfig - 类型配置
	@return number? - 句柄；层满且无法驱逐瞬时层时为 nil
]]
function ShakeRuntime.EnsureSustainLayer(sourceId: string, cfg: ShakeTypeConfig): number?
	_cancelFadeOut()
	local peak = math.max(SUSTAIN_TRAUMA_FLOOR, math.clamp(cfg.trauma, 0, 1))
	local existing = _findSustainLayerBySource(sourceId)
	if existing then
		existing.traumaPeak = math.max(existing.traumaPeak, peak)
		existing.trauma = math.max(existing.trauma, peak)
		existing.roughness = if cfg.roughness > 0 then cfg.roughness else CameraConfig.NOISE_FREQUENCY
		existing.posInfluence = cfg.posInfluence
		existing.rotInfluence = cfg.rotInfluence
		existing.decayPerSec = if cfg.decayPerSec > 0 then cfg.decayPerSec else CameraConfig.TRAUMA_DECAY_PER_SEC
		existing.attackSec = 0
		existing.attackElapsed = 0
		return existing.id
	end
	if not _ensureLayerSlot() then
		Log.warn("ShakeRuntime.EnsureSustainLayer: 层已满且均为 Sustain，拒绝新源", sourceId)
		return nil
	end
	local attackSec = _resolveAttackSec(cfg, true)
	local id = _nextShakeId()
	table.insert(_layers, {
		id = id,
		trauma = if attackSec > 0 then 0 else peak,
		traumaPeak = peak,
		roughness = if cfg.roughness > 0 then cfg.roughness else CameraConfig.NOISE_FREQUENCY,
		posInfluence = cfg.posInfluence,
		rotInfluence = cfg.rotInfluence,
		decayPerSec = if cfg.decayPerSec > 0 then cfg.decayPerSec else CameraConfig.TRAUMA_DECAY_PER_SEC,
		attackSec = attackSec,
		attackElapsed = 0,
		noiseTick = 0,
		seed = _nextNoiseSeed(),
		isSustain = true,
		sourceId = sourceId,
	})
	return id
end

--[[
	引用计数 +1 的 Sustain 开始
	@param sourceId string - 源名
	@param cfg ShakeTypeConfig - 配置
	@return number? - 句柄
]]
function ShakeRuntime.Sustain(sourceId: string, cfg: ShakeTypeConfig): number?
	local handle = ShakeRuntime.EnsureSustainLayer(sourceId, cfg)
	if not handle then
		return nil
	end
	local source = _sustainSources[sourceId]
	if source then
		source.count += 1
		source.layerId = handle
	else
		_sustainSources[sourceId] = {
			count = 1,
			layerId = handle,
		}
	end
	return handle
end

--[[
	引用计数 -1 停止 Sustain
	@param sourceId string - 源名
	@param fadeOutTime number? - <=0 立即移除；>0 加速衰减；nil 自然衰减
	@return boolean - 是否处理成功（源不存在也视为成功）
]]
function ShakeRuntime.StopSustain(sourceId: string, fadeOutTime: number?): boolean
	local source = _sustainSources[sourceId]
	if not source then
		return true
	end
	source.count = math.max(0, source.count - 1)
	if source.count > 0 then
		return true
	end
	_sustainSources[sourceId] = nil
	local index = _findLayerIndexById(source.layerId)
	if not index then
		return true
	end
	if type(fadeOutTime) == "number" and fadeOutTime <= 0 then
		_removeLayerById(source.layerId)
	else
		_releaseSustainLayer(_layers[index], fadeOutTime)
	end
	return true
end

--[[
	取消指定句柄
	@param handle number - 句柄
	@param fadeOutTime number? - <=0 立即移除层
	@return boolean - 是否找到
]]
function ShakeRuntime.Cancel(handle: number, fadeOutTime: number?): boolean
	local index = _findLayerIndexById(handle)
	local hadKick = false
	for _, kick in ipairs(_kicks) do
		if kick.id == handle then
			hadKick = true
			break
		end
	end
	if not index and not hadKick then
		return false
	end
	_removeKickById(handle)
	if not index then
		return true
	end
	if type(fadeOutTime) == "number" and fadeOutTime <= 0 then
		_removeLayerById(handle)
	else
		local layer = _layers[index]
		if layer.sourceId then
			_sustainSources[layer.sourceId] = nil
		end
		_releaseSustainLayer(layer, fadeOutTime)
	end
	return true
end

--[[
	停止全部震动
	@param fadeOutTime number? - 缺省 0.1；<=0 立即清空
	@return () - 无返回值
]]
function ShakeRuntime.StopAll(fadeOutTime: number?)
	local duration = if type(fadeOutTime) == "number" then fadeOutTime else DEFAULT_STOP_FADE
	if duration <= 0 then
		_clearAllShakeLayers()
	else
		_beginFadeOut(duration)
	end
end

--[[
	重置全部震动运行时（含全局 scale）
	@return () - 无返回值
]]
function ShakeRuntime.Reset()
	_shakeScale = 1
	_settingShakeScale = 1
	_noiseSeedCounter = 0
	_shakeIdCounter = 0
	_clearAllShakeLayers()
end

--[[
	更新并计算本帧震动偏移
	@param dt number - 帧间隔
	@return CFrame - 合成后的震动偏移；无层时为单位 CFrame
]]
function ShakeRuntime.ComputeOffset(dt: number): CFrame
	local fadeMul = 1
	if _fadeOutRemaining ~= nil and _fadeOutDuration ~= nil then
		_fadeOutRemaining -= dt
		if _fadeOutRemaining <= 0 then
			_clearAllShakeLayers()
			return CFrame.new()
		end
		fadeMul = math.clamp(_fadeOutRemaining / _fadeOutDuration, 0, 1)
	end

	local userScale = _shakeScale * _settingShakeScale * fadeMul
	local noisePos = Vector3.zero
	local noiseRotDeg = Vector3.zero
	local roughnessFloor = math.clamp(CameraConfig.ROUGHNESS_FLOOR, 0, 1)

	for i = #_layers, 1, -1 do
		local layer = _layers[i]
		if layer.attackSec > 0 and layer.attackElapsed < layer.attackSec then
			layer.attackElapsed += dt
			local t = math.clamp(layer.attackElapsed / layer.attackSec, 0, 1)
			layer.trauma = layer.traumaPeak * _smoothstep(t)
		elseif layer.isSustain then
			layer.trauma = math.max(layer.trauma - layer.decayPerSec * dt, SUSTAIN_TRAUMA_FLOOR)
		else
			layer.trauma = math.max(0, layer.trauma - layer.decayPerSec * dt)
		end

		if layer.trauma <= TRAUMA_DEAD_EPS then
			_removeKickById(layer.id)
			if layer.sourceId then
				_sustainSources[layer.sourceId] = nil
			end
			table.remove(_layers, i)
		else
			local intensity = userScale * (layer.trauma * layer.trauma)
			if intensity > 0 then
				local freqScale = math.clamp(layer.trauma, roughnessFloor, 1)
				layer.noiseTick += dt * layer.roughness * freqScale
				local posSample, rotSample = TraumaNoise.Sample(layer.noiseTick, layer.seed)
				noisePos += posSample * layer.posInfluence * CameraConfig.POS_INFLUENCE * intensity
				noiseRotDeg += rotSample * layer.rotInfluence * CameraConfig.ROT_INFLUENCE * intensity
			end
		end
	end

	local kickPos = Vector3.zero
	local kickRot = Vector3.zero
	local stiffness = math.max(0, CameraConfig.IMPULSE_SPRING_STIFFNESS)
	local damping = math.max(0, CameraConfig.IMPULSE_SPRING_DAMPING)
	for i = #_kicks, 1, -1 do
		local kick = _kicks[i]
		local accelPos = kick.pos * (-stiffness) - kick.velPos * damping
		local accelRot = kick.rot * (-stiffness) - kick.velRot * damping
		kick.velPos = kick.velPos + accelPos * dt
		kick.velRot = kick.velRot + accelRot * dt
		kick.pos = kick.pos + kick.velPos * dt
		kick.rot = kick.rot + kick.velRot * dt
		if
			kick.pos.Magnitude < KICK_REST_EPS
			and kick.rot.Magnitude < KICK_REST_EPS
			and kick.velPos.Magnitude < KICK_REST_EPS
			and kick.velRot.Magnitude < KICK_REST_EPS
		then
			table.remove(_kicks, i)
		else
			kickPos += kick.pos
			kickRot += kick.rot
		end
	end

	local kickRotDeg = Vector3.new(
		math.deg(kickRot.X),
		math.deg(kickRot.Y),
		math.deg(kickRot.Z)
	) * userScale

	return _clampShakeOffset(noisePos + kickPos * userScale, noiseRotDeg + kickRotDeg)
end

return ShakeRuntime
