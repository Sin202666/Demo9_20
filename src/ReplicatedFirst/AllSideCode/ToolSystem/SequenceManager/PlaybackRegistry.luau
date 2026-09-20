--[[
	Module: PlaybackRegistry
	Description: SequenceManager 播放状态表与世代 id（供 Playback / PlaybackQuery 共享，避免循环依赖）
	Author: 林奥宇
	Created: 2026-07-31
	Last Modified: 2026-09-01

	封装约定：
	- 内部表不对外暴露；遍历请用 ForEach / CollectTargets / CollectTargetsInto / Count
	- Heartbeat 热路径请用 CollectTargetsInto(复用缓冲)，避免每 tick 新表
	- 值类型为 Types.PlaybackState（运行时以引用相等做世代校验）
]]

local Types = require(script.Parent.Types)

type PlaybackState = Types.PlaybackState

local PlaybackRegistry = {}

local byLabel: { [GuiObject]: PlaybackState } = {}
local _nextId = 0
-- Heartbeat 默认复用缓冲（勿跨 yield 长期持有返回值）
local _sharedScratch: { GuiObject } = {}

--[[
	分配全局递增播放世代 id
	@return number - 唯一 id（进程内）
]]
function PlaybackRegistry.AllocId(): number
	_nextId += 1
	return _nextId
end

--[[
	读取目标当前播放状态
	@param imageTarget GuiObject - 目标
	@return Types.PlaybackState? - 状态或 nil
]]
function PlaybackRegistry.Get(imageTarget: GuiObject): PlaybackState?
	return byLabel[imageTarget]
end

--[[
	登记播放状态
	@param imageTarget GuiObject - 目标
	@param state Types.PlaybackState - 播放状态
]]
function PlaybackRegistry.Set(imageTarget: GuiObject, state: PlaybackState): ()
	byLabel[imageTarget] = state
end

--[[
	移除播放状态
	@param imageTarget GuiObject - 目标
]]
function PlaybackRegistry.Remove(imageTarget: GuiObject): ()
	byLabel[imageTarget] = nil
end

--[[
	状态是否仍是该目标的当前世代
	@param imageTarget GuiObject - 目标
	@param state Types.PlaybackState - 待校验状态
	@return boolean - true 表示仍活跃
]]
function PlaybackRegistry.IsActive(imageTarget: GuiObject, state: PlaybackState): boolean
	return byLabel[imageTarget] == state
end

--[[
	是否无任何活跃播放
	@return boolean - true 表示空闲
]]
function PlaybackRegistry.IsEmpty(): boolean
	return next(byLabel) == nil
end

--[[
	当前活跃实例数（含暂停）
	@return number - 数量
]]
function PlaybackRegistry.Count(): number
	local count = 0
	for _ in pairs(byLabel) do
		count += 1
	end
	return count
end

--[[
	将当前目标写入 out（先 clear）；用于热路径零分配快照
	@param out { GuiObject }? - 复用缓冲；nil 时用模块内共享缓冲（勿跨 yield 持有）
	@return { GuiObject } - 同一 out 表
]]
function PlaybackRegistry.CollectTargetsInto(out: { GuiObject }?): { GuiObject }
	local labels = out or _sharedScratch
	table.clear(labels)
	for label in pairs(byLabel) do
		table.insert(labels, label)
	end
	return labels
end

--[[
	快照当前全部目标（新建表；StopAll 等低频路径用，可安全长期持有）
	@return { GuiObject } - 目标列表
]]
function PlaybackRegistry.CollectTargets(): { GuiObject }
	return PlaybackRegistry.CollectTargetsInto({})
end

--[[
	遍历全部活跃播放（勿在回调内 Remove 时依赖 pairs 稳定性；停播请先 CollectTargets）
	@param fn (GuiObject, Types.PlaybackState) -> () - 回调
]]
function PlaybackRegistry.ForEach(fn: (GuiObject, PlaybackState) -> ()): ()
	for label, state in pairs(byLabel) do
		fn(label, state)
	end
end

return PlaybackRegistry
