--[[
	Module: LightingManager
	Description: 客户端大气管理器，薄编排天气 Bindable / FX 租约下降沿 / 视觉时钟
	Author: 林奥宇
	Created: 2026-01-23
	Last Modified: 2026-08-31

	功能：
	- 路由天气消息到 SystemLightingWeather（baseline / lease / custom overlay）
	- 监听 Lighting.FXUtilCcBusy 下降沿 + FXUtilCcBusyGen 代际，仅 reconcile ColorCorrection（经 Weather coalesce）
	- CLOCK_CHANGE：经 weather:setClockTime 写视觉钟（世界权威来自服端 ClockAuthority）
	- lease TTL / 无 TTL HardMax 由 Weather 按最近到期调度 sweep（本 Manager 不再轮询）
	- CharacterRemoving：FORCE_CLEAR priority<=Skill，避免技能中断后天气粘住（Dungeon lease 保留）

	写者优先级（通道）：FxLease(CC) > CustomOverlay > WeatherBase（生效层）
	lease priority：仅 Skill / Dungeon（Baseline 走 BASELINE_CHANGE，不可 ACQUIRE）

	调试 Attribute（Lighting，由 Weather 维护；非法消息经 weather:reportClientError）：
	- CurrentLightingName：意图名（lease 优胜或 baseline）
	- LightingAppliedName：最近一次天气 apply 成功落地名（失败不推进）
	- CurrentBaselineLightingName / LightingLeaseCount / LightingTopLeaseWriter
	- LightingLastError：缺配置 / schema / 通道硬错误 / 非法参数（不含 FxBusy / QualitySkip）
	- LightingOverlayTop / LightingSkipReason（含 FxBusy / QualitySkip / ChannelError）
	- LightingStaleLeaseWriters：无 TTL 且存活过久的 writerId
	- LightingApplyPending：Acquire/Baseline 返回 true 后若为 true，画面尚未 flush（勿当同步成功）
	- LightingBootReady：false 时上线健康检查须阻断（缺 Config 或 Weather 降级）

	业务约定：仅经本 Manager Bindable；Utils.SystemLighting / CustomState.new 恒返回 nil。
	Lighting / CustomState 仅由 Weather 经 createForOwner 创建。
	同名生效层 noop（对比 LightingAppliedName / _effectiveName）；强制重放用 ACQUIRE force 或 weather:reapplyEffective。
	同 writer 过密 force 由 Weather 降级为非 force（WeatherAcquireForceMinIntervalSec）。
	同时活跃 lease 上限 WeatherMaxActiveLeases；新 writer 超限 fail-closed。
	无 TTL lease：StaleWarn 告警；HardMax（WeatherLeaseHardMaxSec）到期容灾自动释放；副本退出仍须 FORCE_CLEAR。
	关闭 PostEffect 通道不做属性 Tween（先落地目标再 Enabled=false）。
	过渡缓动：GameConfig.LightingTween。

	时钟语义：
	- 服端 ClockAuthority 为权威；客户端 getClockTime 为目标缓存，Tween 中途可与 Lighting.ClockTime 不一致

	消息：
	- LIGHTING_BASELINE_CHANGE / LIGHTING_CHANGE（兼容）：只改 baseline
	- LIGHTING_ACQUIRE(writerId, lightingName, transitionTime?, priority?, force?, ttl?)
	  非法 priority（含 Baseline）/ 缺配置 fail-closed（不建 lease）
	  返回 true 仅表示 lease 已接受；落地看
	  Pending==false 且 LightingAppliedName==CurrentLightingName 且 LastError==nil
	- LIGHTING_RELEASE / LIGHTING_FORCE_CLEAR / LIGHT_CUSTOM_CHANGE
	- CLOCK_CHANGE(clockTime, transitionTime?, force?)：视觉钟；业务勿直写 Lighting.ClockTime
	  force=true 时目标钟点与缓存相同仍重放（如 Tween 中途重同步）；已到位且无过渡则仍为 no-op

	与 FXUtil：
	- 技能滤镜：FXUtil.PlayColorCorrectionCurve（占 FXUtilCcBusy / 递增 Gen）
	- 天气 / UI 模糊：Weather；租约释放后只回写 CC

	配置：
	- 天气：ReplicatedStorage.Assets.LightingConfig（缺失时 Weather BootReady=false）
	- 自定义状态：ReplicatedStorage.Assets.LightingStates

	使用案例：
	1. 世界天气（baseline，5 秒）
	   Utils.NetWork.FireBindable(Utils.NetMsg.LIGHTING_BASELINE_CHANGE, "Day", 5)
	2. 技能临时天气
	   Utils.NetWork.FireBindable(
	     Utils.NetMsg.LIGHTING_ACQUIRE,
	     "SpaceSkill1",
	     "空间技能",
	     0.25,
	     Utils.EnumMgr.WeatherWriterPriority.Skill,
	     false,
	     30
	   )
	   Utils.NetWork.FireBindable(Utils.NetMsg.LIGHTING_RELEASE, "SpaceSkill1", 0.5)
	3. 容灾清空 Skill 及以下 lease
	   Utils.NetWork.FireBindable(Utils.NetMsg.LIGHTING_FORCE_CLEAR, Utils.EnumMgr.WeatherWriterPriority.Skill, 0)
	4. 读取意图 / 落地 / 健康检查
	   local desired = game.Lighting:GetAttribute("CurrentLightingName")
	   local applied = game.Lighting:GetAttribute("LightingAppliedName")
	   local bootOk = game.Lighting:GetAttribute("LightingBootReady") == true
	   local landed = applied == desired
	     and game.Lighting:GetAttribute("LightingApplyPending") ~= true
	     and game.Lighting:GetAttribute("LightingLastError") == nil

	启动顺序兜底：
	- 若 ClockAuthority 已存在而 CLOCK_CHANGE 监听尚未就绪，主动跟写一次视觉钟
	- 若 LightingBaseline 已存在而 BASELINE 监听尚未就绪，主动 setBaseline（避免默认 Day 卡住）

	生命周期：本脚本为客户端长驻 Manager，FXUtilCcBusy / CharacterRemoving 连接为会话级不解绑（可接受）；
	TTL / HardMax 由 Weather 内部 delay 调度。
	过渡时间由 SystemLightingWeather / LightingTweenUtil 统一 normalize，本 Manager 不做二次规范化。
	全量天气 apply / 单通道 reconcile 由 Weather 同帧 coalesce；本 Manager 路由消息即可。
	Acquire / Baseline / Custom 返回 false 时本 Manager 打 Log.warn（画面异步落地；硬失败另见 LightingLastError）。
]]

-- ========================================
-- 模块引用
-- ========================================
local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log
local NetMsg = Utils.NetMsg
local NetWork = Utils.NetWork
local Lighting = Utils.Lighting
local Players = Utils.Players
local EnumMgr = Utils.EnumMgr
local SystemLightingWeather = Utils.SystemLightingWeather

local FXUTIL_CC_BUSY_ATTR = "FXUtilCcBusy"
local FXUTIL_CC_BUSY_GEN_ATTR = "FXUtilCcBusyGen"
local CLOCK_TIME_MIN = 0
local CLOCK_TIME_MAX = 24
local WeatherWriterPriority = EnumMgr.WeatherWriterPriority

local weather = SystemLightingWeather.Init()

-- ========================================
-- 私有函数
-- ========================================
--[[
	处理 baseline 变更（LIGHTING_BASELINE_CHANGE / 兼容 LIGHTING_CHANGE）

	@param lightingName string - 天气配置名
	@param transitionTime number - 过渡时间（由 Weather 内部 normalize）
	@return nil - 无返回值
]]
local function _onBaselineChange(lightingName: string, transitionTime: number)
	if typeof(lightingName) ~= "string" or lightingName == "" then
		Log.warn("LightingManager: baseline 无效名称", lightingName)
		weather:reportClientError("baseline 无效名称")
		return
	end
	if not weather:setBaseline(lightingName, transitionTime) then
		Log.warn("LightingManager: BASELINE 被拒绝", lightingName)
	end
end

-- ========================================
-- 启动兜底 / 事件绑定
-- ========================================
-- 启动顺序兜底：ClockAuthority 视觉钟 + LightingBaseline 天气基线
do
	local auth = Lighting:FindFirstChild("ClockAuthority")
	if auth and auth:IsA("NumberValue") then
		local clockTime = (auth :: NumberValue).Value
		if typeof(clockTime) == "number" then
			weather:setClockTime(math.clamp(clockTime, CLOCK_TIME_MIN, CLOCK_TIME_MAX), 0)
		end
	end

	local baseline = Lighting:FindFirstChild("LightingBaseline")
	if baseline and baseline:IsA("StringValue") then
		local baselineName = (baseline :: StringValue).Value
		if typeof(baselineName) == "string" and baselineName ~= "" then
			_onBaselineChange(baselineName, 0)
		end
	end
end

-- FX 租约释放后仅对齐 ColorCorrection（避免全通道闪）；defer + Gen 防抖
local wasFxCcBusy = Lighting:GetAttribute(FXUTIL_CC_BUSY_ATTR) == true
local _fxCcBusyConn = Lighting:GetAttributeChangedSignal(FXUTIL_CC_BUSY_ATTR):Connect(function()
	local isBusy = Lighting:GetAttribute(FXUTIL_CC_BUSY_ATTR) == true
	if wasFxCcBusy and not isBusy then
		local releasedGen = Lighting:GetAttribute(FXUTIL_CC_BUSY_GEN_ATTR)
		task.defer(function()
			if Lighting:GetAttribute(FXUTIL_CC_BUSY_ATTR) == true then
				return
			end
			if Lighting:GetAttribute(FXUTIL_CC_BUSY_GEN_ATTR) ~= releasedGen then
				return
			end
			weather:onFxCcBusyReleased()
		end)
	end
	wasFxCcBusy = isBusy
end)

-- 角色销毁：清 Skill 及以下 lease，防止技能中断后天气粘住；Dungeon 保留至业务 FORCE_CLEAR
local localPlayer = Players.LocalPlayer
if localPlayer then
	localPlayer.CharacterRemoving:Connect(function()
		weather:forceClearLeases(WeatherWriterPriority.Skill, 0)
	end)
end

NetWork.RegisterBindableEvent(NetMsg.LIGHTING_BASELINE_CHANGE, _onBaselineChange)
NetWork.RegisterBindableEvent(NetMsg.LIGHTING_CHANGE, _onBaselineChange)

NetWork.RegisterBindableEvent(
	NetMsg.LIGHTING_ACQUIRE,
	function(
		writerId: string,
		lightingName: string,
		transitionTime: number?,
		priority: number?,
		force: boolean?,
		ttl: number?
	)
		local ttlArg: number? = nil
		if typeof(ttl) == "number" then
			ttlArg = ttl
		end
		-- transitionTime 原样下传；Weather.acquireLease 内 normalize
		-- true=lease 已接受（画面经 coalesce 异步落地）；false=拒绝（见 LastError）
		local ok = weather:acquireLease(
			writerId,
			lightingName,
			if typeof(transitionTime) == "number" then transitionTime else 0,
			priority,
			force == true,
			ttlArg
		)
		if not ok then
			Log.warn("LightingManager: ACQUIRE 被拒绝", writerId, lightingName, priority)
		end
	end
)

NetWork.RegisterBindableEvent(NetMsg.LIGHTING_RELEASE, function(writerId: string, transitionTime: number)
	if typeof(writerId) ~= "string" or writerId == "" then
		Log.warn("LightingManager: LIGHTING_RELEASE 无效 writerId", writerId)
		weather:reportClientError("RELEASE 无效 writerId")
		return
	end
	weather:releaseLease(writerId, if typeof(transitionTime) == "number" then transitionTime else 0)
end)

NetWork.RegisterBindableEvent(NetMsg.LIGHTING_FORCE_CLEAR, function(maxPriority: number?, transitionTime: number?)
	local maxP: number? = nil
	if typeof(maxPriority) == "number" then
		maxP = maxPriority
	end
	weather:forceClearLeases(maxP, if typeof(transitionTime) == "number" then transitionTime else 0)
end)

NetWork.RegisterBindableEvent(
	NetMsg.CLOCK_CHANGE,
	function(clockTime: number, transitionTime: number?, force: boolean?)
		if typeof(clockTime) ~= "number" then
			Log.warn("LightingManager: CLOCK_CHANGE 无效 clockTime", clockTime)
			weather:reportClientError("CLOCK_CHANGE 无效 clockTime")
			return
		end

		local clamped = math.clamp(clockTime, CLOCK_TIME_MIN, CLOCK_TIME_MAX)
		if force ~= true and weather:getClockTime() == clamped then
			return
		end

		weather:setClockTime(clamped, if typeof(transitionTime) == "number" then transitionTime else 0)
	end
)

NetWork.RegisterBindableEvent(NetMsg.LIGHT_CUSTOM_CHANGE, function(customName: string, nowState: boolean, transitionTime: number)
	if typeof(customName) ~= "string" or customName == "" or typeof(nowState) ~= "boolean" then
		Log.warn("LightingManager: LIGHT_CUSTOM_CHANGE 参数无效", customName, nowState)
		weather:reportClientError("LIGHT_CUSTOM_CHANGE 参数无效")
		return
	end
	local ok = weather:setCustomStateAndReconcile(
		customName,
		nowState,
		if typeof(transitionTime) == "number" then transitionTime else 0
	)
	if not ok then
		Log.warn("LightingManager: LIGHT_CUSTOM_CHANGE 被拒绝", customName, nowState)
	end
end)
