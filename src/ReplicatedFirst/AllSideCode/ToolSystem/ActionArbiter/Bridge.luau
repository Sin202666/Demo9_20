--[[
	Module: ActionArbiter.Bridge
	Description: 将遗留 Attribute（JetPacking / FacingOverride）映射为 ActionArbiter 占用。
	Author: 林奥宇
	Created: 2026-07-28
	Last Modified: 2026-09-01

	新业务请直接 Acquire，勿新增 Attribute 契约；本 Bridge 仅兼容存量。
	Skill 占闸已由 SkillActionLock 模块直调 Acquire（引用计数）；enableSkillActionLock 默认 false，Attribute 路径废弃。
]]

local Constants = require(script.Parent.Constants)

local Bridge = {}

export type BridgeAttachOptions = {
	localPlayer: Player?,
	enableJetPacking: boolean?,
	enableFacingOverride: boolean?,
	-- 已废弃：SkillActionLock 直调 Acquire；仅显式 true 时才监听 Attribute（兼容存量）
	enableSkillActionLock: boolean?,
}

--[[
	挂接 Attribute → Acquire/Release；返回 disconnect 清理函数
	@param arbiter any - ActionArbiter 实例（须含 Acquire/ReleaseByOwner）
	@param character Model - 角色
	@param options BridgeAttachOptions - 本地玩家与开关
	@return () -> () - 断开监听
]]
function Bridge.attach(arbiter: any, character: Model, options: BridgeAttachOptions?): () -> ()
	local opts = options or {}
	local localPlayer = opts.localPlayer
	local connections: { RBXScriptConnection } = {}
	local Priority = Constants.Priority
	local BridgeOwnerId = Constants.BridgeOwnerId
	local FacingOwner = Constants.FacingOwner
	local CameraOwner = Constants.CameraOwner

	--[[
		登记连接以便 disconnect 时一并断开
		@param conn RBXScriptConnection - 监听
	]]
	local function _track(conn: RBXScriptConnection)
		table.insert(connections, conn)
	end

	--[[
		按 JetPacking Attribute 占用或释放 Flight 闸
	]]
	local function _syncJetPacking()
		local ownerId = BridgeOwnerId.JetPacking
		if character:GetAttribute("JetPacking") ~= nil then
			arbiter:Acquire({
				ownerId = ownerId,
				priority = Priority.Flight,
				suppressLoco = true,
				pauseBaseTracks = true,
				facingOwner = FacingOwner.External,
				cameraOwner = CameraOwner.External,
				reason = "Bridge:JetPacking",
			})
		else
			arbiter:ReleaseByOwner(ownerId)
		end
	end

	--[[
		按 FacingOverride Attribute 占用或释放朝向闸
	]]
	local function _syncFacingOverride()
		local ownerId = BridgeOwnerId.FacingOverride
		if character:GetAttribute("FacingOverride") == true then
			arbiter:Acquire({
				ownerId = ownerId,
				priority = Priority.FacingBridge,
				suppressLoco = false,
				pauseBaseTracks = false,
				facingOwner = FacingOwner.External,
				cameraOwner = CameraOwner.Default,
				reason = "Bridge:FacingOverride",
			})
		else
			arbiter:ReleaseByOwner(ownerId)
		end
	end

	--[[
		兼容存量 SkillActionLock Attribute（新路径应直调 Acquire）
	]]
	local function _syncSkillActionLock()
		local ownerId = BridgeOwnerId.SkillActionLock
		if not localPlayer then
			return
		end
		if localPlayer:GetAttribute("SkillActionLock") then
			-- 兼容存量 Attribute；新路径见 SkillActionLock 直调
			arbiter:Acquire({
				ownerId = ownerId,
				priority = Priority.Skill,
				suppressLoco = true,
				pauseBaseTracks = true,
				facingOwner = FacingOwner.External,
				cameraOwner = CameraOwner.Default,
				reason = "Bridge:SkillActionLock",
			})
		else
			arbiter:ReleaseByOwner(ownerId)
		end
	end

	if opts.enableJetPacking ~= false then
		_syncJetPacking()
		_track(character:GetAttributeChangedSignal("JetPacking"):Connect(_syncJetPacking))
	end
	if opts.enableFacingOverride ~= false then
		_syncFacingOverride()
		_track(character:GetAttributeChangedSignal("FacingOverride"):Connect(_syncFacingOverride))
	end
	-- 默认关闭：SkillActionLock 已直调 Acquire；仅显式 true 启用 Attribute 兼容
	if opts.enableSkillActionLock == true and localPlayer then
		_syncSkillActionLock()
		_track(localPlayer:GetAttributeChangedSignal("SkillActionLock"):Connect(_syncSkillActionLock))
	end

	return function()
		for _, conn in ipairs(connections) do
			conn:Disconnect()
		end
		table.clear(connections)
		arbiter:ReleaseByOwner(BridgeOwnerId.JetPacking)
		arbiter:ReleaseByOwner(BridgeOwnerId.FacingOverride)
		arbiter:ReleaseByOwner(BridgeOwnerId.SkillActionLock)
	end
end

return Bridge
