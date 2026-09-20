--[[
	Module: CharacterControl.PlayerControlsBridge
	Description: 引用计数封装引擎 PlayerModule.ControlModule Enable/Disable；仅供 CharacterControl 内部使用，勿经 Utils 旁路。
	Author: 林奥宇
	Created: 2026-08-05
	Last Modified: 2026-09-01
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Players = Utils.Players
local Log = Utils.Log

export type PlayerControlsBridgeController = {
	Acquire: (self: PlayerControlsBridgeController, sourceId: string) -> (),
	Release: (self: PlayerControlsBridgeController, sourceId: string) -> (),
	ReleaseAll: (self: PlayerControlsBridgeController) -> (),
	IsDisabled: (self: PlayerControlsBridgeController) -> boolean,
	GetHolderCount: (self: PlayerControlsBridgeController) -> number,
}

local PlayerControlsBridge = {}

-- ========================================
-- 进程级共享
-- ========================================

-- ControlModule 全局唯一，多 CharacterControl 实例须共用持有者表
local _sharedHolders: { [string]: boolean } = {}
local _controlsDisabled = false
local _controlsCache: any = nil
local _resolveFailed = false

-- ========================================
-- 私有函数
-- ========================================

--[[
	懒加载 LocalPlayer PlayerModule:GetControls()
	@return any? - ControlModule 单例；未就绪或失败为 nil
]]
local function _resolveControls(): any?
	if _controlsCache then
		return _controlsCache
	end
	if _resolveFailed then
		return nil
	end
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return nil
	end
	-- PlayerScripts / PlayerModule 可能尚未复制；未找到时不永久失败，下次再试
	local playerScripts = localPlayer:FindFirstChild("PlayerScripts")
	if not playerScripts then
		return nil
	end
	local pmScript = playerScripts:FindFirstChild("PlayerModule")
	if not pmScript then
		return nil
	end
	local ok, playerModule = pcall(require, pmScript)
	if not ok or type(playerModule) ~= "table" or type(playerModule.GetControls) ~= "function" then
		_resolveFailed = true
		Log.warn("[PlayerControlsBridge] PlayerModule 加载失败")
		return nil
	end
	local controls = playerModule:GetControls()
	if type(controls) ~= "table" or type(controls.Disable) ~= "function" or type(controls.Enable) ~= "function" then
		_resolveFailed = true
		Log.warn("[PlayerControlsBridge] GetControls 无效")
		return nil
	end
	_controlsCache = controls
	return _controlsCache
end

--[[
	按共享持有者表同步 ControlModule Enable/Disable
]]
local function _syncControls()
	local wantDisable = next(_sharedHolders) ~= nil
	if wantDisable == _controlsDisabled then
		return
	end
	local controls = _resolveControls()
	if not controls then
		if wantDisable then
			Log.warn("[PlayerControlsBridge] Controls 未就绪，跳过 Disable（仍依赖 CMS 冻速）")
		end
		return
	end
	if wantDisable then
		controls:Disable()
		_controlsDisabled = true
	else
		controls:Enable(true)
		_controlsDisabled = false
	end
end

-- ========================================
-- 公共工厂
-- ========================================

--[[
	创建 Bridge 控制器（共享底层持有者表；ReleaseAll 仅清本实例登记的 sourceId）
	@return PlayerControlsBridgeController - Acquire/Release/ReleaseAll 实例
]]
function PlayerControlsBridge.create(): PlayerControlsBridgeController
	local mine: { [string]: boolean } = {}

	local controller = {} :: PlayerControlsBridgeController

	--[[
		登记 Disable 持有者；0→1 时 Disable Controls
		@param sourceId string - 稳定来源 ID
	]]
	function controller:Acquire(sourceId: string)
		if type(sourceId) ~= "string" or sourceId == "" then
			return
		end
		if mine[sourceId] then
			return
		end
		mine[sourceId] = true
		_sharedHolders[sourceId] = true
		_syncControls()
	end

	--[[
		移除本实例对该 sourceId 的持有；无人持有时 Enable Controls
		@param sourceId string - 稳定来源 ID
	]]
	function controller:Release(sourceId: string)
		if type(sourceId) ~= "string" or sourceId == "" then
			return
		end
		if not mine[sourceId] then
			return
		end
		mine[sourceId] = nil
		_sharedHolders[sourceId] = nil
		_syncControls()
	end

	--[[
		释放本实例全部持有者并同步 Controls
	]]
	function controller:ReleaseAll()
		if next(mine) == nil then
			return
		end
		for sourceId in pairs(mine) do
			_sharedHolders[sourceId] = nil
		end
		table.clear(mine)
		_syncControls()
	end

	--[[
		Controls 是否处于本 Bridge 驱动的 Disable 状态
		@return boolean - 共享层认为已 Disable
	]]
	function controller:IsDisabled(): boolean
		return _controlsDisabled
	end

	--[[
		本实例登记的持有者数量（非全局）
		@return number - 本实例 sourceId 数
	]]
	function controller:GetHolderCount(): number
		local n = 0
		for _ in pairs(mine) do
			n += 1
		end
		return n
	end

	return controller
end

return PlayerControlsBridge
