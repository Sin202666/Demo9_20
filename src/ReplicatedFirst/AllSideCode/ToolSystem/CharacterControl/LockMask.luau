--[[
	Module: CharacterControl.LockMask
	Description: 输入锁来源栈；同 sourceId 覆盖，多源按通道 OR 聚合。
	Author: 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-09-01
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log

export type LockChannels = {
	Move: boolean,
	Jump: boolean,
	Sprint: boolean,
	Look: boolean,
	Interact: boolean,
}

export type MovePolicy = "SpeedOnly" | "DisableControls"

export type LockMaskSpec = {
	Move: boolean?,
	Jump: boolean?,
	Sprint: boolean?,
	Look: boolean?,
	Interact: boolean?,
	-- 仅 Move=true 时有意义；由 CharacterControl 旁路表消费，LockMask OR 不存此字段
	MovePolicy: MovePolicy?,
}

export type LockMaskController = {
	Push: (self: LockMaskController, sourceId: string, mask: LockMaskSpec) -> (),
	Pop: (self: LockMaskController, sourceId: string) -> boolean,
	Get: (self: LockMaskController) -> LockChannels,
	Clear: (self: LockMaskController) -> (),
	OnChanged: (self: LockMaskController, callback: (LockChannels) -> ()) -> () -> (),
}

local LockMask = {}

-- ========================================
-- 私有函数
-- ========================================

--[[
	空锁快照
	@return LockChannels - 五通道均为 false 的新表
]]
local function _emptyChannels(): LockChannels
	return {
		Move = false,
		Jump = false,
		Sprint = false,
		Look = false,
		Interact = false,
	}
end

--[[
	规范化写入条目
	@param mask LockMaskSpec - 调用方传入的可选通道开关
	@return LockChannels - 仅 true 记为锁定的完整五通道表
]]
local function _normalizeEntry(mask: LockMaskSpec): LockChannels
	return {
		Move = mask.Move == true,
		Jump = mask.Jump == true,
		Sprint = mask.Sprint == true,
		Look = mask.Look == true,
		Interact = mask.Interact == true,
	}
end

--[[
	两快照是否相等
	@param a LockChannels - 左侧聚合
	@param b LockChannels - 右侧聚合
	@return boolean - 五通道全相等时为 true
]]
local function _equal(a: LockChannels, b: LockChannels): boolean
	return a.Move == b.Move
		and a.Jump == b.Jump
		and a.Sprint == b.Sprint
		and a.Look == b.Look
		and a.Interact == b.Interact
end

-- ========================================
-- 公共工厂
-- ========================================

--[[
	创建 LockMask 控制器
	@return LockMaskController - Push/Pop/Get/Clear/OnChanged 实例
]]
function LockMask.create(): LockMaskController
	local sources: { [string]: LockChannels } = {}
	local aggregated = _emptyChannels()
	local callbacks: { (LockChannels) -> () } = {}

	local controller = {} :: LockMaskController

	--[[
		按当前 sources 重算 OR 聚合并通知
	]]
	local function _rebuildAndPublish()
		local nextAgg = _emptyChannels()
		for _, entry in pairs(sources) do
			nextAgg.Move = nextAgg.Move or entry.Move
			nextAgg.Jump = nextAgg.Jump or entry.Jump
			nextAgg.Sprint = nextAgg.Sprint or entry.Sprint
			nextAgg.Look = nextAgg.Look or entry.Look
			nextAgg.Interact = nextAgg.Interact or entry.Interact
		end
		if _equal(aggregated, nextAgg) then
			return
		end
		aggregated = nextAgg
		local snapshot = {
			Move = aggregated.Move,
			Jump = aggregated.Jump,
			Sprint = aggregated.Sprint,
			Look = aggregated.Look,
			Interact = aggregated.Interact,
		}
		for _, cb in ipairs(callbacks) do
			local ok, err = pcall(cb, snapshot)
			if not ok then
				Log.warn("[CharacterControl.LockMask] OnChanged error:", err)
			end
		end
	end

	--[[
		压入/覆盖一条锁
		@param sourceId string - 来源 ID（须稳定）
		@param mask LockMaskSpec - 通道开关
	]]
	function controller:Push(sourceId: string, mask: LockMaskSpec)
		if type(sourceId) ~= "string" or sourceId == "" then
			Log.warn("[CharacterControl.LockMask] Push: sourceId 必填")
			return
		end
		sources[sourceId] = _normalizeEntry(mask or {})
		_rebuildAndPublish()
	end

	--[[
		移除一条锁
		@param sourceId string - 来源 ID
		@return boolean - true 表示此前存在该来源
	]]
	function controller:Pop(sourceId: string): boolean
		if type(sourceId) ~= "string" or sourceId == "" then
			return false
		end
		if sources[sourceId] == nil then
			return false
		end
		sources[sourceId] = nil
		_rebuildAndPublish()
		return true
	end

	--[[
		当前聚合锁（浅拷贝）
		@return LockChannels - 各通道 OR 聚合后的新表
	]]
	function controller:Get(): LockChannels
		return {
			Move = aggregated.Move,
			Jump = aggregated.Jump,
			Sprint = aggregated.Sprint,
			Look = aggregated.Look,
			Interact = aggregated.Interact,
		}
	end

	--[[
		清空全部来源
	]]
	function controller:Clear()
		if next(sources) == nil then
			return
		end
		table.clear(sources)
		_rebuildAndPublish()
	end

	--[[
		订阅聚合变化
		@param callback (LockChannels) -> () - 聚合变化时回调（传入本帧浅拷贝，勿依赖改表回写）
		@return () -> () - 调用后取消本订阅
	]]
	function controller:OnChanged(callback: (LockChannels) -> ()): () -> ()
		table.insert(callbacks, callback)
		return function()
			for i, cb in ipairs(callbacks) do
				if cb == callback then
					table.remove(callbacks, i)
					break
				end
			end
		end
	end

	return controller
end

return LockMask
