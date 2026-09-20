--[[
	Module: FXUtil/PartIcles
	Description: PartIcles 引擎门面 — 幂等 Activate、完整 API 转发、Stop 软/硬停约定
	Author: 林奥宇
	Created: 2026-07-24
	Last Modified: 2026-09-01

	与原生 PE 路径（FXUtil.Emit_Particles_* / Start_All_Emit 等）并存：
	- 原生 ParticleEmitter/Beam/Trail 模型 → 继续用 Emit_* / SetEmittersTrailsBeamsEnabled
	- PartIcles 作者化（Transformed）资源 → 本门面 AbsoluteEmit / EnableEmit / …
	对象池短期各走各的：勿把 FXUtil 池实例交给本引擎 Disable 后再当原生还池。

	加载：
	  local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
	  local PartIcles = Utils.PartIcles
	  -- 或 local PartIcles = Utils.FXUtil.PartIcles  （同一门面引用）

	常用：
	  PartIcles:AbsoluteEmit(root)
	  PartIcles:AbsoluteEmitAt(root, originCF, options?)
	  PartIcles:Stop(root)           -- 默认软停 SoftDisable
	  PartIcles:Stop(root, true)     -- 硬停 Disable（立刻回收）
	  PartIcles.EnsureActivated()    -- 一般可省略；方法转发会自动调用（仅客户端）
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local RunService = Utils.RunService

-- 引擎本体：ToolSystem/PartIcles（与 FXUtil 同级；禁止经 Utils.FXUtil 回绕造成循环）
local Engine = require(script.Parent.Parent.PartIcles)

local PartIcles = {}

local _activated = false

local STATIC_KEYS: { [string]: boolean } = {
	await = true,
	parseDuration = true,
}

--[[
	客户端幂等激活 Heartbeat 引擎；服务端 no-op。
	公开引擎方法经门面调用时会自动触发，一般无需手写。
]]
function PartIcles.EnsureActivated()
	if _activated then
		return
	end
	if not RunService:IsClient() then
		return
	end
	-- 其它路径已 Activate 时只同步标记，避免重复连接
	if (Engine :: any)._connection then
		_activated = true
		return
	end
	if type(Engine.Activate) ~= "function" then
		return
	end
	Engine:Activate()
	_activated = true
end

--[[
	停播约定：默认软停（停止新发射，在途粒子寿终）；hard=true 立刻回收克隆。
	支持 PartIcles.Stop(item, hard?) 与 PartIcles:Stop(item, hard?)。

	@param a any - 门面 self（冒号调用）或目标 Instance
	@param b any - 目标 Instance（冒号）或 hard（点调用）
	@param c boolean? - hard（冒号调用时）
]]
function PartIcles.Stop(a: any, b: any, c: boolean?)
	local item: Instance?
	local hard: boolean?
	if a == PartIcles then
		item = b
		hard = c
	else
		item = a
		hard = b
	end
	if not item then
		return
	end
	PartIcles.EnsureActivated()
	if hard then
		Engine:Disable(item)
	else
		Engine:SoftDisable(item)
	end
end

setmetatable(PartIcles, {
	__index = function(_t, key: string)
		-- 引擎私有态（_activeEmits / _connection 等）不经门面透出
		if type(key) == "string" and string.sub(key, 1, 1) == "_" then
			return nil
		end
		local value = (Engine :: any)[key]
		if type(value) ~= "function" then
			return value
		end
		if STATIC_KEYS[key] then
			return value
		end
		-- Activate / Deactivate 不经 EnsureActivated，避免双重 Activate
		if key == "Activate" then
			return function(_self: any, ...)
				if not RunService:IsClient() then
					return
				end
				local result = value(Engine, ...)
				_activated = true
				return result
			end
		end
		if key == "Deactivate" then
			return function(_self: any, ...)
				_activated = false
				return value(Engine, ...)
			end
		end
		return function(_self: any, ...)
			PartIcles.EnsureActivated()
			return value(Engine, ...)
		end
	end,
})

return PartIcles