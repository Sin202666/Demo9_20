--[[
	技能同步路由层
	职责：将「全员广播」改为「相关玩家同步」，按半径筛选目标，减少无关流量
	支持：位置路由 + 订阅者集合，确保曾收到开始/派生/命中的玩家必定收到 StopSkill

	调用方：SkillSyncDispatcher.dispatch 统一入口（BaseSkillServer、GroupSkillInstanceRuntime、HitResolver 等）

	三层保险：TTL 定期 sweep、PlayerRemoving 离线清理、broadcastStopTrackedAndClear 自带 finally clear

	画质（玩家主体施法）：低画质客户端仍收本人技能表现与 Stop；不向他人投递、也不接收其他玩家施法的 SynSkillEffect / Stop / Presentation。
	炼药流程（进入炼药游戏≠0 或 材料选择中）：不向该客户端投递其他玩家的上述表现；本人施法不受影响。
	NPC 等非 Player 主体技能不因画质过滤（半径策略不变）。伤害飘字不按画质过滤。全局阴影等仍由客户端 GraphicsQualitySet 控制。
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local GetData = Utils.GetData
local SkillNet = Utils.SkillNet
local SynSkillEffect = SkillNet.SynSkillEffect
local StopSkill = SkillNet.StopSkill
local DamageTipEvent = SkillNet.DamageTip
local RemoteEventToClient = nil -- 一期通用 RemoteEvent 飘字走 SkillNet / 跳过

local SkillSyncRouter = {}

local GRAPHICS_QUALITY_LOW = 0

local function getGraphicsQualitySetting(plr: Player): number?
	if not plr then
		return nil
	end
	if type(GetData.GetSetting) ~= "function" then
		return nil
	end
	local ok, v = pcall(function()
		return GetData.GetSetting(plr, "GraphicsQuality")
	end)
	if not ok then
		return nil
	end
	return v
end

local function isLowGraphics(plr: Player): boolean
	return getGraphicsQualitySetting(plr) == GRAPHICS_QUALITY_LOW
end

--[[
	玩家施放的技能相关表现：低画质仅本人可见自已施法；旁观者需双方均为高画质。
	casterPlr 为 nil（NPC 等）时不收窄。
]]
local function shouldDeliverPlayerCasterFx(casterPlr: Player?, recipientPlr: Player): boolean
	if not casterPlr then
		return true
	end
	if recipientPlr == casterPlr then
		return true
	end
	if GetData.IsPlrInPotionFlow(recipientPlr) then
		return false
	end
	if isLowGraphics(recipientPlr) then
		return false
	end
	if isLowGraphics(casterPlr) then
		return false
	end
	return true
end

local function inferCasterPlayerFromPayload(payload: any): Player?
	if type(payload) ~= "table" then
		return nil
	end
	if payload.characterType == "Player" and type(payload.characterId) == "number" then
		return Players:GetPlayerByUserId(payload.characterId)
	end
	return nil
end

local DEFAULT_RADIUS = 120
local AUDIENCE_TTL_SEC = 120
local SWEEP_INTERVAL_SEC = 30

-- 订阅者集合：skillCastId -> { [Player] = true }
local _audienceByCastId = {}
-- 元数据：skillCastId -> { lastTouched = number }
local _audienceMetaByCastId = {}

-- 集成测试用：注入 player 列表与事件捕获，仅测试时设置
local _testPlayerProvider = nil
local _testEventCapture = nil

function SkillSyncRouter._testSetPlayerProvider(fn)
	_testPlayerProvider = fn
end

function SkillSyncRouter._testSetEventCapture(capture)
	_testEventCapture = capture
end

function SkillSyncRouter._testSetAudienceLastTouched(skillCastId, lastTouched)
	if _audienceMetaByCastId[skillCastId] then
		_audienceMetaByCastId[skillCastId].lastTouched = lastTouched
	else
		_audienceMetaByCastId[skillCastId] = { lastTouched = lastTouched }
	end
end

function SkillSyncRouter._testReset()
	_testPlayerProvider = nil
	_testEventCapture = nil
end

local function touchAudience(skillCastId)
	if not skillCastId then return end
	local meta = _audienceMetaByCastId[skillCastId]
	if not meta then
		meta = {}
		_audienceMetaByCastId[skillCastId] = meta
	end
	meta.lastTouched = os.clock()
end

--[[
	从所有 audience 集合中移除指定玩家（PlayerRemoving 时调用）
]]
local function removePlayerFromAllAudiences(player)
	if not player then return end
	for castId, set in pairs(_audienceByCastId) do
		if set[player] then
			set[player] = nil
			if next(set) == nil then
				_audienceByCastId[castId] = nil
				_audienceMetaByCastId[castId] = nil
			end
		end
	end
end

--[[
	测试用：模拟玩家离开，触发与 PlayerRemoving 相同的清理逻辑
]]
function SkillSyncRouter._testSimulatePlayerRemoving(player)
	removePlayerFromAllAudiences(player)
end

-- PlayerRemoving：离线时从所有 audience 中移除
local _playerRemovingConn = Players.PlayerRemoving:Connect(removePlayerFromAllAudiences)

-- 定期 sweep 超时 cast
local _lastSweepTime = 0
local function sweepExpiredAudience()
	local now = os.clock()
	if now - _lastSweepTime < SWEEP_INTERVAL_SEC then return end
	_lastSweepTime = now
	for castId, meta in pairs(_audienceMetaByCastId) do
		if (now - (meta.lastTouched or 0)) > AUDIENCE_TTL_SEC then
			_audienceByCastId[castId] = nil
			_audienceMetaByCastId[castId] = nil
		end
	end
end

local _sweepConn = RunService.Heartbeat:Connect(function()
	sweepExpiredAudience()
end)

local function getCharacterRoot(character)
	if not character then return nil end
	return character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
end

--[[
	登记单个玩家为订阅者
]]
function SkillSyncRouter.registerAudience(skillCastId, player)
	if not skillCastId or not player then return end
	touchAudience(skillCastId)
	local set = _audienceByCastId[skillCastId]
	if not set then
		set = {}
		_audienceByCastId[skillCastId] = set
	end
	set[player] = true
end

--[[
	登记多个玩家为订阅者
]]
function SkillSyncRouter.registerAudiences(skillCastId, players)
	if not skillCastId or not players then return end
	for _, p in ipairs(players) do
		SkillSyncRouter.registerAudience(skillCastId, p)
	end
end

--[[
	获取某 skillCastId 的订阅者集合（副本）
	@return Player[]
]]
function SkillSyncRouter.getAudience(skillCastId)
	local set = _audienceByCastId[skillCastId]
	if not set then return {} end
	local result = {}
	for player, _ in pairs(set) do
		if player and player.Parent then
			table.insert(result, player)
		end
	end
	return result
end

--[[
	获取某 skillCastId 的订阅者数量（诊断用）
]]
function SkillSyncRouter.getAudienceCount(skillCastId)
	local set = _audienceByCastId[skillCastId]
	if not set then return 0 end
	local n = 0
	for player, _ in pairs(set) do
		if player and player.Parent then n = n + 1 end
	end
	return n
end

--[[
	获取当前追踪的 cast 数量（诊断用）
]]
function SkillSyncRouter.getTrackedCastCount()
	local n = 0
	for _ in pairs(_audienceByCastId) do n = n + 1 end
	return n
end

--[[
	手动 sweep 超时 audience（诊断/运维用）
	@return number 被清理的 cast 数量
]]
function SkillSyncRouter.debugSweepInvalidAudience()
	local now = os.clock()
	local removed = 0
	for castId, meta in pairs(_audienceMetaByCastId) do
		if (now - (meta.lastTouched or 0)) > AUDIENCE_TTL_SEC then
			_audienceByCastId[castId] = nil
			_audienceMetaByCastId[castId] = nil
			removed = removed + 1
		end
	end
	_lastSweepTime = now
	return removed
end

--[[
	清除某 skillCastId 的订阅者集合（broadcastStopTrackedAndClear 已自动调用，手动 clear 仍支持）
]]
function SkillSyncRouter.clearAudience(skillCastId)
	if skillCastId then
		_audienceByCastId[skillCastId] = nil
		_audienceMetaByCastId[skillCastId] = nil
	end
end

--[[
	获取半径内的相关玩家
	@param originPos Vector3 中心位置
	@param radius number 半径（studs）
	@param casterPlayer Player? 施法者（NPC 时为 nil），root 丢失时保底加入
	@return Player[]
	施法者本人始终加入：否则弹道落在 hitConfirmRadius 外时收不到 ProjectileHitConfirmed，客户端进不了 Exploding、不播爆炸。
]]
function SkillSyncRouter.getRelevantPlayers(originPos, radius, casterPlayer)
	local result = {}
	local playerList = _testPlayerProvider and _testPlayerProvider() or Players:GetPlayers()
	for _, player in ipairs(playerList) do
		local character = player.Character
		local root = getCharacterRoot(character)
		if root then
			local dist = (root.Position - originPos).Magnitude
			if dist <= radius then
				table.insert(result, player)
			end
		elseif casterPlayer and player == casterPlayer then
			table.insert(result, player)
		end
	end
	if casterPlayer and casterPlayer.Parent then
		local already = false
		for _, p in ipairs(result) do
			if p == casterPlayer then
				already = true
				break
			end
		end
		if not already then
			table.insert(result, casterPlayer)
		end
	end
	return result
end

--[[
	向相关玩家发送 SynSkillEffect
]]
function SkillSyncRouter.broadcastRelevant(originPos, radius, payload, casterPlayer)
	local targets = SkillSyncRouter.getRelevantPlayers(originPos, radius or DEFAULT_RADIUS, casterPlayer)
	for _, p in ipairs(targets) do
		if shouldDeliverPlayerCasterFx(casterPlayer, p) then
			if _testEventCapture then
				_testEventCapture.record("SynSkillEffect", p, payload)
			else
				SynSkillEffect:FireClient(p, payload)
			end
		end
	end
end

--[[
	向相关玩家发送 SynSkillEffect，并登记为订阅者
	originPos 为 nil 时发送给全员并登记全员
]]
function SkillSyncRouter.broadcastRelevantAndTrack(skillCastId, originPos, radius, payload, casterPlayer)
	local targets
	if originPos then
		targets = SkillSyncRouter.getRelevantPlayers(originPos, radius or DEFAULT_RADIUS, casterPlayer)
	else
		targets = _testPlayerProvider and _testPlayerProvider() or Players:GetPlayers()
	end
	for _, p in ipairs(targets) do
		if shouldDeliverPlayerCasterFx(casterPlayer, p) then
			if _testEventCapture then
				_testEventCapture.record("SynSkillEffect", p, payload)
			else
				SynSkillEffect:FireClient(p, payload)
			end
			SkillSyncRouter.registerAudience(skillCastId, p)
		end
	end
end

--[[
	向相关玩家发送 StopSkill
]]
function SkillSyncRouter.broadcastStopRelevant(originPos, radius, payload, casterPlayer)
	local targets = SkillSyncRouter.getRelevantPlayers(originPos, radius or DEFAULT_RADIUS, casterPlayer)
	for _, p in ipairs(targets) do
		if shouldDeliverPlayerCasterFx(casterPlayer, p) then
			if _testEventCapture then
				_testEventCapture.record("StopSkill", p, payload)
			else
				StopSkill:FireClient(p, payload)
			end
		end
	end
end

--[[
	StopSkill：先发给已登记订阅者，再按当前位置补发未覆盖者
	发完后自动 clearAudience（三层保险：不再依赖调用方手动 clear）
]]
function SkillSyncRouter.broadcastStopTracked(skillCastId, payload, fallbackOriginPos, radius, casterPlayer)
	local sent = {}
	local audience = SkillSyncRouter.getAudience(skillCastId)
	for _, p in ipairs(audience) do
		if shouldDeliverPlayerCasterFx(casterPlayer, p) then
			if _testEventCapture then
				_testEventCapture.record("StopSkill", p, payload)
			else
				StopSkill:FireClient(p, payload)
			end
			sent[p] = true
		end
	end
	if fallbackOriginPos then
		local fallbackTargets = SkillSyncRouter.getRelevantPlayers(fallbackOriginPos, radius or DEFAULT_RADIUS, casterPlayer)
		for _, p in ipairs(fallbackTargets) do
			if not sent[p] and shouldDeliverPlayerCasterFx(casterPlayer, p) then
				if _testEventCapture then
					_testEventCapture.record("StopSkill", p, payload)
				else
					StopSkill:FireClient(p, payload)
				end
			end
		end
	end
	SkillSyncRouter.clearAudience(skillCastId)
end

--[[
	安全版本：内部自带 finally clear，broadcast 抛错时仍保证 audience 被清理
	上层应优先调用此 API，避免遗漏 clear 导致幽灵 audience
]]
function SkillSyncRouter.broadcastStopTrackedAndClear(skillCastId, payload, fallbackOriginPos, radius, casterPlayer)
	local ok, err = pcall(function()
		SkillSyncRouter.broadcastStopTracked(skillCastId, payload, fallbackOriginPos, radius, casterPlayer)
	end)
	SkillSyncRouter.clearAudience(skillCastId)
	if not ok then
		error(err)
	end
end

--[[
	向相关玩家发送伤害飘字（按命中点半径筛选，减少无关客户端流量）
	@param originPos Vector3 命中点位置（用于半径筛选）
	@param radius number? 半径（studs），默认 120
	@param hitPos Vector3 飘字显示位置
	@param damageText string 伤害数值文本
	@param isCrit boolean 是否暴击
	@param dmgType number 伤害类型（EnumMgr.DmgTp）
	@param casterPlayer Player? 施法者（NPC 时为 nil）
]]
function SkillSyncRouter.broadcastDamageTipRelevant(originPos, radius, hitPos, damageText, isCrit, dmgType, casterPlayer)
	local targets = SkillSyncRouter.getRelevantPlayers(originPos, radius or DEFAULT_RADIUS, casterPlayer)
	for _, p in ipairs(targets) do
		if _testEventCapture then
			_testEventCapture.record("DamageTip", p, hitPos, damageText, isCrit, dmgType)
		else
			DamageTipEvent:FireClient(p, hitPos, damageText, isCrit, dmgType)
		end
	end
end

--[[
	向相关玩家发送元素附着跳字（RemoteEvent.ElementAttachTip；客户端 ClietnListen/ElementAttachTip.local 消费）。
]]
function SkillSyncRouter.broadcastElementAttachTipRelevant(originPos, radius, payload, casterPlayer)
	if type(payload) ~= "table" then
		return
	end
	local tipEvent = SkillNet.ElementAttachTip
	if not tipEvent or not tipEvent:IsA("RemoteEvent") then
		warn("[SkillSyncRouter] 缺少 RemoteEvent.ElementAttachTip，跳字未下发")
		return
	end
	-- 低画质 / 炼药流不投递；施法者本人始终可见（同技能表现策略）
	local targets = SkillSyncRouter.getRelevantPlayers(originPos, radius or DEFAULT_RADIUS, casterPlayer)
	for _, p in ipairs(targets) do
		if shouldDeliverPlayerCasterFx(casterPlayer, p) then
			if _testEventCapture then
				_testEventCapture.record("ElementAttachTip", p, payload)
			else
				tipEvent:FireClient(p, payload)
			end
		end
	end
end

--[[
	向半径内玩家发送通用 RemoteEvent（msgName + data），与 getRelevantPlayers 策略一致。
	用于 Buff DoT 受击表现等非 SynSkillEffect 通道；casterPlayer 保证施法者仍在圈外时也能收到（同技能同步）。
]]
function SkillSyncRouter.broadcastPresentationRelevant(originPos, radius, msgName, data, casterPlayer)
	if type(msgName) ~= "string" or msgName == "" then
		return
	end
	if not RemoteEventToClient then
		return
	end
	local targets = SkillSyncRouter.getRelevantPlayers(originPos, radius or DEFAULT_RADIUS, casterPlayer)
	for _, p in ipairs(targets) do
		if shouldDeliverPlayerCasterFx(casterPlayer, p) then
			if _testEventCapture then
				_testEventCapture.record("RemotePresentation", p, msgName, data)
			else
				if RemoteEventToClient then RemoteEventToClient:FireClient(p, msgName, data) end
			end
		end
	end
end

--[[
	全服广播 SynSkillEffect（大招、全屏、观战等特殊场景）
]]
function SkillSyncRouter.sendToAll(payload)
	local casterPlr = inferCasterPlayerFromPayload(payload)
	for _, p in Players:GetPlayers() do
		if shouldDeliverPlayerCasterFx(casterPlr, p) then
			SynSkillEffect:FireClient(p, payload)
		end
	end
end

--[[
	全服广播 StopSkill
]]
function SkillSyncRouter.sendStopToAll(payload)
	local casterPlr = inferCasterPlayerFromPayload(payload)
	for _, p in Players:GetPlayers() do
		if shouldDeliverPlayerCasterFx(casterPlr, p) then
			StopSkill:FireClient(p, payload)
		end
	end
end

return SkillSyncRouter
