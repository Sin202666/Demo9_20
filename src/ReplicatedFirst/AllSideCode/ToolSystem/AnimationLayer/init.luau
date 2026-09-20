--[[
	Module: AnimationLayer
	Description: 角色动作层 Slot 播轨（Upper/FullBody/React）：fade/weight、世代防误停、经 BlendPolicy 占闸。
	Author: 林奥宇
	Created: 2026-07-31
	Last Modified: 2026-08-28

	================================================================================
	使用说明
	================================================================================

	【与 AnimationModule / ActionArbiter / Animate】
	- AnimationModule：底层 Load/Play/Stop/缓存/Marker
	- ActionArbiter：Acquire(blendPolicy)；Overlay 不停腿，Override 冻 loco+基轨
	- Animate loco / StrafeBlend：本模块不拥有 Loco Slot；禁止外部写入基轨
	- Upper 叠层：经典 Animator 无关节 Mask；资源须只键上半身（R6 勿键 Left/Right Hip）
	  假上半身（腿被键在站姿）会钉死跑腿 —— 属资源问题

	【Slot】
	- Upper：Action2 + Overlay（移动中上身）
	- FullBody：Action + Override（翻滚/全身）
	- React：Action4 + React（短受击，可与 Upper 并存）

	【获取】
	local AnimationLayer = Utils.AnimationLayer

	【示例 — 移动中上身施法】
	local handle = AnimationLayer.Play(character, {
	  slot = AnimationLayer.Slot.Upper,
	  animationName = "Cast_Upper", -- 须为未键腿资源
	  ownerId = "Skill:FireSlash",
	  fadeIn = 0.12,
	})
	-- ...
	AnimationLayer.Stop(handle)

	【示例 — 全身演出】
	AnimationLayer.Play(character, {
	  slot = "FullBody",
	  animationName = "RollForward",
	  blendPolicy = "Override",
	})

	【技能】
	SkillAction.Animation 可走本模块；闸可由 SkillActionLock 聚合（acquireGate=false），
	或由本模块自行 Acquire（acquireGate 默认 true）。

	【子模块】
	- Slots.luau  Slot 默认表
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local AnimationModule = Utils.AnimationModule
local ActionArbiter = Utils.ActionArbiter

local Slots = require(script.Slots)

export type PlayOptions = {
	slot: string,
	animationName: string,
	ownerId: string?,
	speed: number?,
	fadeIn: number?,
	fadeOut: number?,
	weight: number?,
	blendPolicy: string?,
	priority: Enum.AnimationPriority?,
	arbiterPriority: number?,
	looped: boolean?,
	keyframeNames: { string }?,
	keyframeFunctions: { () -> () }?,
	acquireGate: boolean?,
	releaseOnStopped: boolean?,
	ttlSeconds: number?,
	facingOwner: string?,
	cameraOwner: string?,
}

export type LayerHandle = {
	id: number,
	character: Model,
	slot: string,
	animationName: string,
	animator: Animator,
	generation: number,
	fadeOut: number,
	claimToken: string?,
	acquireGate: boolean,
}

local AnimationLayer = {}
AnimationLayer.Slot = Slots.Name
AnimationLayer.BlendPolicy = ActionArbiter.BlendPolicy

-- 弱键角色状态
local _charState: { [Model]: any } = setmetatable({}, { __mode = "k" }) :: any
local _handleSeq = 0

--[[
	取或建角色层状态
	@param character Model - 目标角色
	@return table - { slots: { [string]: LayerHandle }, generation: { [string]: number } }
]]
local function _getState(character: Model): any
	local state = _charState[character]
	if state then
		return state
	end
	state = {
		slots = {} :: { [string]: LayerHandle },
		generation = {} :: { [string]: number },
	}
	_charState[character] = state
	return state
end

--[[
	解析 Humanoid.Animator
	@param character Model - 目标角色
	@return Animator? - Humanoid 下 Animator；缺失为 nil
]]
local function _findAnimator(character: Model): Animator?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	return animator
end

--[[
	解析 Slot 默认；非法名返回 nil
	@param slotName string - Slot 名（Upper/FullBody/React）
	@return table? - Slots.Defaults 行；非法名为 nil
]]
local function _slotDefaults(slotName: string): any?
	return Slots.Defaults[slotName]
end

--[[
	Release 占闸（若有）
	@param handle LayerHandle - Play 返回的层句柄
]]
local function _releaseClaim(handle: LayerHandle)
	if not handle.acquireGate or type(handle.claimToken) ~= "string" or handle.claimToken == "" then
		handle.claimToken = nil
		return
	end
	local token = handle.claimToken
	handle.claimToken = nil
	local arbiter = ActionArbiter.GetForCharacter(handle.character)
	if arbiter then
		arbiter:Release(token)
	end
end

--[[
	停轨并清 Slot（世代校验）
	@param handle LayerHandle - Play 返回的层句柄
	@param fadeOut number? - 淡出秒；nil 时用 handle.fadeOut
	@param force boolean? - 忽略世代（内部替换 Slot 时 true）
]]
local function _stopHandle(handle: LayerHandle, fadeOut: number?, force: boolean?)
	local state = _charState[handle.character]
	if not state then
		_releaseClaim(handle)
		return
	end
	local current = state.slots[handle.slot]
	local gen = state.generation[handle.slot] or 0
	if not force and (current ~= handle or handle.generation ~= gen) then
		return
	end
	if state.slots[handle.slot] == handle then
		state.slots[handle.slot] = nil
	end
	local fade = if type(fadeOut) == "number" then fadeOut else handle.fadeOut
	if handle.animator and handle.animator.Parent and handle.animationName then
		AnimationModule.StopAnim(handle.animator, handle.animationName, fade)
	end
	_releaseClaim(handle)
end

--[[
	在指定 Slot 播放动画
	@param character Model - 角色
	@param options PlayOptions - slot/animationName 必填
	@return LayerHandle? - 失败返回 nil
]]
function AnimationLayer.Play(character: Model, options: PlayOptions): LayerHandle?
	if typeof(character) ~= "Instance" or not character:IsA("Model") then
		warn("AnimationLayer.Play: character 须为 Model")
		return nil
	end
	if type(options) ~= "table" then
		warn("AnimationLayer.Play: options 必填")
		return nil
	end
	local slotName = options.slot
	local defaults = _slotDefaults(slotName)
	if not defaults then
		warn("AnimationLayer.Play: 未知 slot", slotName)
		return nil
	end
	local animationName = options.animationName
	if type(animationName) ~= "string" or animationName == "" then
		warn("AnimationLayer.Play: animationName 必填")
		return nil
	end

	local animator = _findAnimator(character)
	if not animator then
		warn("AnimationLayer.Play: 未找到 Animator")
		return nil
	end

	local state = _getState(character)
	local prev = state.slots[slotName]
	if prev then
		_stopHandle(prev, options.fadeOut or defaults.fadeOut, true)
	end

	state.generation[slotName] = (state.generation[slotName] or 0) + 1
	local generation = state.generation[slotName]

	local fadeIn = if type(options.fadeIn) == "number" then options.fadeIn else defaults.fadeIn
	local fadeOut = if type(options.fadeOut) == "number" then options.fadeOut else defaults.fadeOut
	local speed = if type(options.speed) == "number" then options.speed else 1
	local priority = options.priority or defaults.priority
	local blendPolicy = options.blendPolicy or defaults.blendPolicy
	local acquireGate = options.acquireGate ~= false
	local ownerId = options.ownerId
	if type(ownerId) ~= "string" or ownerId == "" then
		ownerId = string.format("AnimationLayer:%s:%s", slotName, animationName)
	end

	_handleSeq += 1
	local handle: LayerHandle = {
		id = _handleSeq,
		character = character,
		slot = slotName,
		animationName = animationName,
		animator = animator,
		generation = generation,
		fadeOut = fadeOut,
		claimToken = nil,
		acquireGate = acquireGate,
	}

	if acquireGate then
		local arbiter = ActionArbiter.GetForCharacter(character)
		if arbiter then
			local arbPri = options.arbiterPriority
			if type(arbPri) ~= "number" then
				arbPri = defaults.arbiterPriority
			end
			handle.claimToken = arbiter:Acquire({
				ownerId = ownerId,
				priority = arbPri,
				blendPolicy = blendPolicy,
				facingOwner = options.facingOwner :: any,
				cameraOwner = options.cameraOwner :: any,
				ttlSeconds = options.ttlSeconds,
				reason = "AnimationLayer:" .. slotName,
			})
		else
			warn("AnimationLayer.Play: 角色尚未 Create ActionArbiter，已跳过占闸")
		end
	end

	-- 同名轨重播：先硬停再 Play，避免 IsPlaying 跳过
	AnimationModule.StopAnim(animator, animationName, 0)
	local length = AnimationModule.PlayAnim(
		animator,
		animationName,
		speed,
		options.keyframeNames,
		options.keyframeFunctions,
		priority,
		fadeIn,
		nil
	)
	if not length then
		_releaseClaim(handle)
		return nil
	end

	local track = AnimationModule.GetCachedTrack(animator, animationName)
	if track then
		if options.looped == true then
			track.Looped = true
		elseif options.looped == false then
			track.Looped = false
		end
		local weight = options.weight
		if type(weight) == "number" then
			track:AdjustWeight(weight, fadeIn)
		end
		if acquireGate and options.releaseOnStopped ~= false and handle.claimToken then
			local token = handle.claimToken
			local conn: RBXScriptConnection? = nil
			conn = track.Stopped:Connect(function()
				if conn then
					conn:Disconnect()
					conn = nil
				end
				local st = _charState[character]
				if st and st.slots[slotName] == handle and handle.generation == (st.generation[slotName] or 0) then
					st.slots[slotName] = nil
				end
				if handle.claimToken == token then
					_releaseClaim(handle)
				end
			end)
		end
	end

	state.slots[slotName] = handle
	return handle
end

--[[
	停止 handle 对应播放（世代不匹配则忽略）
	@param handle LayerHandle? - Play 返回值
	@param fadeOut number? - 覆盖默认淡出
	@return boolean - 是否执行了停止
]]
function AnimationLayer.Stop(handle: LayerHandle?, fadeOut: number?): boolean
	if type(handle) ~= "table" or not handle.character then
		return false
	end
	local state = _charState[handle.character]
	if not state or state.slots[handle.slot] ~= handle then
		return false
	end
	if handle.generation ~= (state.generation[handle.slot] or 0) then
		return false
	end
	_stopHandle(handle, fadeOut, false)
	return true
end

--[[
	停止角色某 Slot 当前播放
	@param character Model - 角色
	@param slot string - Upper/FullBody/React
	@param fadeOut number? - 淡出秒数
	@return boolean - 是否有轨被停
]]
function AnimationLayer.StopSlot(character: Model, slot: string, fadeOut: number?): boolean
	if typeof(character) ~= "Instance" or not character:IsA("Model") then
		return false
	end
	local state = _charState[character]
	if not state then
		return false
	end
	local handle = state.slots[slot]
	if not handle then
		return false
	end
	_stopHandle(handle, fadeOut, true)
	return true
end

--[[
	调整当前 handle 权重
	@param handle LayerHandle - Play 返回值
	@param weight number - 目标权重
	@param fade number? - 过渡秒数
	@return boolean - 是否成功
]]
function AnimationLayer.AdjustWeight(handle: LayerHandle, weight: number, fade: number?): boolean
	if type(handle) ~= "table" or type(weight) ~= "number" then
		return false
	end
	local state = _charState[handle.character]
	if not state or state.slots[handle.slot] ~= handle then
		return false
	end
	local track = AnimationModule.GetCachedTrack(handle.animator, handle.animationName)
	if not track then
		return false
	end
	track:AdjustWeight(weight, fade or 0.1)
	return true
end

--[[
	Slot 是否有活跃 handle
	@param character Model - 角色
	@param slot string - Slot 名
	@return boolean - true 表示该 Slot 仍有活跃轨
]]
function AnimationLayer.IsSlotPlaying(character: Model, slot: string): boolean
	if typeof(character) ~= "Instance" or not character:IsA("Model") then
		return false
	end
	local state = _charState[character]
	if not state then
		return false
	end
	local handle = state.slots[slot]
	if not handle then
		return false
	end
	return AnimationModule.IsAnimPlaying(handle.animator, handle.animationName) == true
end

--[[
	跳转 handle 对应轨时间（技能预测软合并）
	@param handle LayerHandle - Play 返回值
	@param timePosition number - 秒
	@return boolean - true 表示已跳转时间
]]
function AnimationLayer.SetTimePosition(handle: LayerHandle, timePosition: number): boolean
	if type(handle) ~= "table" or type(timePosition) ~= "number" then
		return false
	end
	local state = _charState[handle.character]
	if not state or state.slots[handle.slot] ~= handle then
		return false
	end
	return AnimationModule.SetAnimationTimePosition(handle.animator, handle.animationName, timePosition)
end

--[[
	取 handle 的缓存轨
	@param handle LayerHandle - Play 返回的层句柄
	@return AnimationTrack? - 缓存轨；无效 handle 为 nil
]]
function AnimationLayer.GetTrack(handle: LayerHandle): AnimationTrack?
	if type(handle) ~= "table" then
		return nil
	end
	return AnimationModule.GetCachedTrack(handle.animator, handle.animationName)
end

return AnimationLayer