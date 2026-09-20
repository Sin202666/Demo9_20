--[[
	Module: PeerPool
	Description: SequenceManager Crossfade/CloneAll 轻量 ImageLabel 租还池（降低 Instantiation/GC）
	Author: 林奥宇
	Created: 2026-07-31
	Last Modified: 2026-09-01

	约定：Release 时 Parent=nil 并清空 Image；池满则 Destroy。
	Acquire 时若池内实例已 Destroy，自动丢弃并新建。
]]

local Utils = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local Log = Utils.Log

local Types = require(script.Parent.Types)

local PeerPool = {}

local pool: { ImageLabel } = {}

--[[
	尝试从池取出可用 ImageLabel
	@return ImageLabel? - 可复用实例；池空或皆失效时 nil
]]
local function _popUsable(): ImageLabel?
	while #pool > 0 do
		local peer = table.remove(pool)
		if not peer then
			continue
		end
		local ok = pcall(function()
			-- Destroyed 实例写属性会失败
			peer.Name = peer.Name
		end)
		if ok then
			return peer
		end
	end
	return nil
end

--[[
	租借同级 ImageLabel（挂到 source.Parent）
	@param source GuiObject - 布局与父级来源
	@param name string - 实例名
	@param applyLayout (GuiObject, ImageLabel) -> () - 布局拷贝
	@return ImageLabel? - 成功时非 nil
]]
function PeerPool.Acquire(
	source: GuiObject,
	name: string,
	applyLayout: (GuiObject, ImageLabel) -> ()
): ImageLabel?
	local parent = source.Parent
	if not parent then
		return nil
	end

	local peer = _popUsable()
	if not peer then
		peer = Instance.new("ImageLabel")
	end

	local ok, err = pcall(function()
		peer.Name = name
		applyLayout(source, peer)
		peer.Visible = false
		peer.ImageTransparency = 1
		peer.Image = ""
		peer.ImageRectOffset = Vector2.zero
		peer.ImageRectSize = Vector2.zero
		peer.Parent = parent
	end)
	if not ok then
		Log.warn("[SequenceManager] PeerPool.Acquire 失败:", err)
		return nil
	end
	return peer
end

--[[
	归还或销毁 peer
	@param peer ImageLabel? - 待释放实例
]]
function PeerPool.Release(peer: ImageLabel?): ()
	if not peer then
		return
	end

	local ok = pcall(function()
		peer.Visible = false
		peer.ImageTransparency = 1
		peer.Image = ""
		peer.ImageRectOffset = Vector2.zero
		peer.ImageRectSize = Vector2.zero
		peer.Parent = nil
	end)
	if not ok then
		return
	end

	if #pool >= Types.MAX_PEER_POOL then
		pcall(function()
			peer:Destroy()
		end)
		return
	end
	table.insert(pool, peer)
end

--[[
	清空对象池（测试或热重载时可选）
]]
function PeerPool.Clear(): ()
	for _, peer in ipairs(pool) do
		pcall(function()
			peer:Destroy()
		end)
	end
	table.clear(pool)
end

--[[
	当前池内闲置数量
	@return number - 数量
]]
function PeerPool.GetIdleCount(): number
	return #pool
end

return PeerPool
